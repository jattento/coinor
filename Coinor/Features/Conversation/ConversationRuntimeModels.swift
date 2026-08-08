import Foundation

enum RuntimeActivity: String, Codable, Equatable, Sendable {
    case idle
    case working
    case needsInput
    case failed

    static func aggregate<S: Sequence>(_ values: S) -> RuntimeActivity
    where S.Element == RuntimeActivity {
        var hasWorking = false
        var hasFailed = false
        for value in values {
            switch value {
            case .needsInput:
                return .needsInput
            case .working:
                hasWorking = true
            case .failed:
                hasFailed = true
            case .idle:
                continue
            }
        }
        if hasWorking { return .working }
        if hasFailed { return .failed }
        return .idle
    }

    init(grokActivity: GrokSessionActivity) {
        switch grokActivity {
        case .working:
            self = .working
        case .needsInput:
            self = .needsInput
        case .dead:
            self = .failed
        case .idle, .dormant, .completed, .unknown:
            self = .idle
        }
    }
}

/// How a conversation's activity change affects its sidebar indicator.
///
/// Grok reports `needs_input` only while a conversation is blocked on a
/// question and reports a finished turn as plain `idle`, so a completed run is
/// invisible unless the settle edge itself is treated as attention.
enum ConversationAttention {
    enum Transition: Equatable {
        /// The conversation now wants the user.
        case raised
        /// The conversation went back to work and no longer wants anything.
        case settled
        case unchanged
    }

    static func transition(
        from previous: RuntimeActivity?,
        to current: RuntimeActivity
    ) -> Transition {
        if current == .working { return .settled }
        if current == .needsInput {
            return previous == .needsInput ? .unchanged : .raised
        }
        if current == .idle, previous == .working { return .raised }
        return .unchanged
    }
}

enum TerminalSurfaceContext: Equatable, Sendable {
    case window
    case tab
    case split
}

enum TerminalTabNavigationRequest: Equatable, Sendable {
    case previous
    case next
    case last
    case index(Int)
}

enum ConversationShellDirectorySource: Equatable, Sendable {
    case rootLaunchDirectory
    case explicit(String)
    case unavailable
}

struct TerminalLaunchRequest: Equatable, Identifiable, Sendable {
    enum Mode: Equatable, Sendable {
        case newSession
        case resume
        case shell
        case managedShell
        case command(String)
    }

    let sessionID: String
    let workingDirectory: String
    let grokExecutable: String
    let leaderSocket: String
    let mode: Mode
    let additionalArguments: [String]
    let environment: [String: String]
    let initialInput: String?
    let surfaceContext: TerminalSurfaceContext

    init(
        sessionID: String,
        workingDirectory: String,
        grokExecutable: String,
        leaderSocket: String,
        mode: Mode,
        additionalArguments: [String] = [],
        environment: [String: String] = [:],
        initialInput: String? = nil,
        surfaceContext: TerminalSurfaceContext = .window
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.grokExecutable = grokExecutable
        self.leaderSocket = leaderSocket
        self.mode = mode
        self.additionalArguments = additionalArguments
        self.environment = environment
        self.initialInput = initialInput
        self.surfaceContext = surfaceContext
    }

    init(shellTabID: String, workingDirectory: String) {
        self.sessionID = shellTabID
        self.workingDirectory = workingDirectory
        self.grokExecutable = ""
        self.leaderSocket = ""
        self.mode = .shell
        self.additionalArguments = []
        self.environment = [:]
        self.initialInput = nil
        self.surfaceContext = .tab
    }

    init(
        managedTabID: String,
        workingDirectory: String,
        environment: [String: String],
        bootstrapPath: String
    ) {
        self.sessionID = managedTabID
        self.workingDirectory = workingDirectory
        self.grokExecutable = ""
        self.leaderSocket = ""
        self.mode = .managedShell
        self.additionalArguments = []
        self.environment = environment
        self.initialInput =
            "source \(Self.shellQuote(bootstrapPath))\r"
        self.surfaceContext = .tab
    }

    init(
        commandID: String,
        workingDirectory: String,
        command: String
    ) {
        self.sessionID = commandID
        self.workingDirectory = workingDirectory
        self.grokExecutable = ""
        self.leaderSocket = ""
        self.mode = .command(command)
        self.additionalArguments = []
        self.environment = [:]
        self.initialInput = nil
        self.surfaceContext = .split
    }

    var id: String { sessionID }

    var arguments: [String] {
        switch mode {
        case .shell, .managedShell, .command:
            return []
        case .newSession, .resume:
            break
        }
        var values = [
            "--leader-socket", leaderSocket,
            "--leader",
            "--cwd", workingDirectory,
        ]
        values += additionalArguments
        switch mode {
        case .newSession:
            values += ["--session-id", sessionID]
        case .resume:
            values += ["--resume", sessionID]
        case .shell, .managedShell, .command:
            break
        }
        return values
    }

    var shellCommand: String {
        switch mode {
        case .shell:
            return ""
        case .managedShell:
            return "/bin/zsh -il"
        case .command(let command):
            return command
        case .newSession, .resume:
            return ([grokExecutable] + arguments)
                .map(Self.shellQuote)
                .joined(separator: " ")
        }
    }

    var explicitCommand: String? {
        switch mode {
        case .shell:
            nil
        case .newSession, .resume, .managedShell, .command:
            shellCommand
        }
    }

    var waitsAfterCommand: Bool {
        mode != .shell && mode != .managedShell
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct RuntimePane: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case root
        case subagent(parentSessionID: String)
    }

    let id: String
    let kind: Kind
    let launch: TerminalLaunchRequest
    let startSequence: UInt64
    var activity: RuntimeActivity
}

struct ConversationPaneCollection: Equatable, Sendable {
    let root: RuntimePane
    private(set) var descendants: [RuntimePane]
    private var terminalDescendantIDs: Set<String>

    init(root: RuntimePane) {
        precondition(root.kind == .root)
        self.root = root
        self.descendants = []
        self.terminalDescendantIDs = []
    }

    var usesSplitLayout: Bool {
        !descendants.isEmpty
    }

    var aggregateActivity: RuntimeActivity {
        RuntimeActivity.aggregate([root.activity] + descendants.map(\.activity))
    }

    var attentionPaneID: String? {
        if root.activity == .needsInput {
            return root.id
        }
        return descendants.first(where: { $0.activity == .needsInput })?.id
    }

    mutating func startDescendant(_ pane: RuntimePane) {
        guard pane.kind != .root,
              !terminalDescendantIDs.contains(pane.id),
              !descendants.contains(where: { $0.id == pane.id }) else {
            return
        }
        descendants.append(pane)
        descendants.sort {
            if $0.startSequence != $1.startSequence {
                return $0.startSequence < $1.startSequence
            }
            return $0.id < $1.id
        }
    }

    mutating func stopDescendant(sessionID: String) {
        terminalDescendantIDs.insert(sessionID)
        descendants.removeAll { $0.id == sessionID }
    }

    mutating func setActivity(_ activity: RuntimeActivity, paneID: String) {
        guard let index = descendants.firstIndex(where: { $0.id == paneID }) else {
            return
        }
        descendants[index].activity = activity
    }
}
