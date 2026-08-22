import Foundation

/// One decoded screenshot poll result.
struct EgoBrowserFrame: Equatable, Sendable {
    /// Raw JPEG bytes. Decoding into `NSImage` is left to the caller so this
    /// type stays usable off the main actor.
    let jpegData: Data
    let url: String?
    let title: String?
}

enum EgoBrowserPollError: Equatable, Sendable, LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case timedOut
    case nonZeroExit(code: Int32, message: String)
    case malformedOutput
    case missingFrame

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The ego-browser CLI was not found. Install ego lite (https://lite.ego.app) to see a live browser preview."
        case .launchFailed(let message):
            "Could not launch ego-browser: \(message)"
        case .timedOut:
            "ego-browser did not respond in time."
        case .nonZeroExit(let code, let message):
            "ego-browser exited with code \(code)"
                + (message.isEmpty ? "." : ": \(message)")
        case .malformedOutput:
            "ego-browser did not return a recognizable screenshot response."
        case .missingFrame:
            "ego-browser did not return a screenshot."
        }
    }
}

/// Drives one `ego-browser nodejs` invocation to capture a single screenshot
/// of a named ego lite Task Space via the Chrome DevTools Protocol.
///
/// Each call is a fresh, independent subprocess — `ego-browser` carries no
/// state of its own between invocations, so every poll re-attaches to the
/// Task Space by name via `useOrCreateTaskSpace`, exactly like driving it by
/// hand. The invocation shape mirrors the one measured live during the
/// Phase 0 spike (warm poll ~100-160ms end to end).
struct EgoBrowserScreenshotClient: Sendable {
    let executablePath: String
    let timeout: Duration
    let jpegQuality: Int

    init(
        executablePath: String,
        timeout: Duration = .seconds(10),
        jpegQuality: Int = 55
    ) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.jpegQuality = jpegQuality
    }

    func captureScreenshot(
        taskSpaceName: String
    ) async -> Result<EgoBrowserFrame, EgoBrowserPollError> {
        let script = Self.script(
            taskSpaceName: taskSpaceName,
            quality: jpegQuality
        )
        switch await EgoBrowserCLIRunner.run(
            executablePath: executablePath,
            stdin: script,
            timeout: timeout
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let outcome):
            guard outcome.status == 0 else {
                let message = String(
                    decoding: outcome.stderr,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(
                    .nonZeroExit(code: outcome.status, message: message)
                )
            }
            // ego-browser's own output stream selection is not a stable
            // contract Coinor controls, and was observed (diagnosed live)
            // to land on stderr rather than stdout depending on how the
            // process was launched, even on a clean exit. Scan both.
            var combined = outcome.stdout
            combined.append(contentsOf: [0x0A])
            combined.append(outcome.stderr)
            return Self.parse(stdout: combined)
        }
    }

    /// The Node.js snippet piped to `ego-browser nodejs` on stdin, mirroring
    /// the heredoc validated during the Phase 0 spike but fed directly via a
    /// pipe rather than shell heredoc syntax, so the task-space name never
    /// needs shell-level escaping.
    static func script(taskSpaceName: String, quality: Int) -> String {
        let literal = jsStringLiteral(taskSpaceName)
        return """
            const task = await useOrCreateTaskSpace(\(literal))
            const shot = await cdp('Page.captureScreenshot', { format: 'jpeg', quality: \(quality) })
            const info = await pageInfo()
            cliLog(JSON.stringify({ ok: true, jpeg: shot?.data ?? null, url: info?.url ?? null, title: info?.title ?? null }))
            """
    }

    /// Scans stdout bottom-up for the first line that decodes as the JSON
    /// object this script logs. Bottom-up because `ego-browser` can append
    /// an out-of-band "update available" trailer line after the script's own
    /// output; scanning defensively for the `ok` marker also tolerates it
    /// appearing before that output instead.
    static func parse(stdout: Data) -> Result<EgoBrowserFrame, EgoBrowserPollError> {
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let value = try? GrokJSONValue.decode(lineData),
                  value["ok"]?.boolValue == true else {
                continue
            }
            guard let base64 = value["jpeg"]?.stringValue,
                  let data = Data(base64Encoded: base64) else {
                return .failure(.missingFrame)
            }
            return .success(
                EgoBrowserFrame(
                    jpegData: data,
                    url: value["url"]?.stringValue,
                    title: value["title"]?.stringValue
                )
            )
        }
        return .failure(.malformedOutput)
    }

    private static func jsStringLiteral(_ value: String) -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

}
