import Foundation

/// One Task Space lifecycle signal extracted from the text of an observed
/// `ego-browser` invocation.
struct GrokBrowserSpaceSignal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case opened
        case closed(keepFrame: Bool)
    }

    let name: String
    let kind: Kind
}

/// A `run_terminal_command` tool-call event whose command drove `ego-browser`,
/// carrying every Task Space signal found in its (possibly multi-line
/// heredoc) command text, in the order they appear in the text.
///
/// Detection is entirely passive: it reads the same generic ACP tool-call
/// notification Coinor already observes for the terminal-control nonce
/// (`GrokTerminalToolInvocation`), so it requires no cooperation from the
/// agent beyond calling the already-public `ego-browser` skill the way its
/// own documentation already mandates.
struct GrokBrowserToolInvocation: Equatable, Sendable {
    let sessionID: String
    let signals: [GrokBrowserSpaceSignal]

    static func parseNotification(
        method: String,
        params: GrokJSONValue
    ) -> GrokBrowserToolInvocation? {
        guard method == GrokMethod.sessionUpdate
                || method == GrokMethod.sessionNotification
                || method == "session/update"
                || method == "session/notification" else {
            return nil
        }
        let update = params["update"] ?? params
        guard update["sessionUpdate"]?.stringValue == "tool_call",
              update["title"]?.stringValue == "run_terminal_command",
              let sessionID = params["sessionId"]?.stringValue,
              !sessionID.isEmpty,
              let command = update["rawInput"]?["command"]?.stringValue,
              !command.isEmpty,
              command.range(
                  of: Self.egoBrowserInvocationPattern,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        let signals = Self.signals(in: command)
        guard !signals.isEmpty else { return nil }
        return GrokBrowserToolInvocation(
            sessionID: sessionID,
            signals: signals
        )
    }

    /// Extracts every Task Space open/close signal from one command's text,
    /// in the order the calls appear.
    ///
    /// `completeTaskSpace`/`closeTaskSpace` is frequently called with a
    /// variable such as `task.name` rather than a literal string (confirmed
    /// against a real recorded invocation), so a close call with no literal
    /// name attributes to the most recently opened literal name earlier in
    /// the *same* command text — the common one-shot open+close pattern. A
    /// close call in a later, separate command still requires its own
    /// literal name, since there is no shared command text to fall back to.
    static func signals(in command: String) -> [GrokBrowserSpaceSignal] {
        guard let openRegex, let closeRegex else { return [] }
        let nsCommand = command as NSString
        let fullRange = NSRange(location: 0, length: nsCommand.length)

        struct RawMatch {
            let location: Int
            let isOpen: Bool
            let literalName: String?
            let keepFrame: Bool
        }

        var raw: [RawMatch] = []

        for match in openRegex.matches(in: command, range: fullRange) {
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            raw.append(
                RawMatch(
                    location: match.range.location,
                    isOpen: true,
                    literalName: nsCommand.substring(with: nameRange),
                    keepFrame: false
                )
            )
        }

        for match in closeRegex.matches(in: command, range: fullRange) {
            var literal: String?
            let nameRange = match.range(at: 1)
            if nameRange.location != NSNotFound {
                literal = nsCommand.substring(with: nameRange)
            }
            let start = match.range.location
            let end = min(
                nsCommand.length,
                start + keepFrameLookaheadWindow
            )
            let window = nsCommand.substring(
                with: NSRange(location: start, length: end - start)
            )
            let keepFrame = window.range(
                of: #"keep\s*:\s*true"#,
                options: .regularExpression
            ) != nil
            raw.append(
                RawMatch(
                    location: start,
                    isOpen: false,
                    literalName: literal,
                    keepFrame: keepFrame
                )
            )
        }

        raw.sort { $0.location < $1.location }

        var signals: [GrokBrowserSpaceSignal] = []
        var lastOpenedName: String?
        for item in raw {
            if item.isOpen, let name = item.literalName {
                signals.append(GrokBrowserSpaceSignal(name: name, kind: .opened))
                lastOpenedName = name
            } else if !item.isOpen,
                      let name = item.literalName ?? lastOpenedName {
                signals.append(
                    GrokBrowserSpaceSignal(
                        name: name,
                        kind: .closed(keepFrame: item.keepFrame)
                    )
                )
            }
        }
        return signals
    }

    private static let egoBrowserInvocationPattern = #"\bego-browser\b"#
    private static let keepFrameLookaheadWindow = 200

    private static let openRegex = try? NSRegularExpression(
        pattern:
            #"(?:useOrCreateTaskSpace|takeOverTaskSpace)\(\s*['"]([^'"]+)['"]"#
    )
    private static let closeRegex = try? NSRegularExpression(
        pattern:
            #"(?:completeTaskSpace|closeTaskSpace)\(\s*(?:['"]([^'"]+)['"])?"#
    )
}
