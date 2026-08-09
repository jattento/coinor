import Foundation

/// What a conversation's process is doing, as Grok's roster reports it.
///
/// The cases are ordered by how much they want from the user: `needsInput`
/// outranks everything because it blocks, and `dormant` ranks last because a
/// suspended session is the least alive thing a conversation can be.
enum RuntimeActivity: String, Codable, Equatable, Sendable, CaseIterable {
    case needsInput
    case working
    case failed
    case idle
    case completed
    case dormant

    private var rank: Int {
        switch self {
        case .needsInput: return 0
        case .working: return 1
        case .failed: return 2
        case .idle: return 3
        case .completed: return 4
        case .dormant: return 5
        }
    }

    static func aggregate<S: Sequence>(_ values: S) -> RuntimeActivity
    where S.Element == RuntimeActivity {
        values.min { $0.rank < $1.rank } ?? .idle
    }

    init(grokActivity: GrokSessionActivity) {
        switch grokActivity {
        case .working:
            self = .working
        case .needsInput:
            self = .needsInput
        case .dead:
            self = .failed
        case .completed:
            self = .completed
        case .dormant:
            self = .dormant
        case .idle, .unknown:
            self = .idle
        }
    }

    /// Whether the conversation still has work in flight.
    var isBusy: Bool { self == .working }
}

/// Why a conversation is asking for the user.
enum ConversationAttentionReason: Equatable, Sendable {
    /// Grok is blocked on a question and cannot continue alone.
    case question
    /// A run settled and its result has not been seen yet.
    case finished
}

/// How a conversation's activity change affects its sidebar indicator.
///
/// Grok reports `needs_input` only while a conversation is blocked on a
/// question and reports a finished turn as plain `idle`, so a completed run is
/// invisible unless the settle edge itself is treated as attention.
enum ConversationAttention {
    enum Transition: Equatable {
        /// The conversation now wants the user.
        case raised(ConversationAttentionReason)
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
            return previous == .needsInput ? .unchanged : .raised(.question)
        }
        guard previous == .working, current != .failed else {
            return .unchanged
        }
        return .raised(.finished)
    }
}

/// The single mark a conversation row, project row, or tab shows for its state.
///
/// Each case owns a distinct symbol and color: the indicator must stay legible
/// to someone who cannot separate green from amber.
enum ConversationIndicator: Equatable, Sendable {
    case none
    case working
    case waiting
    case finished
    case failed
    case completed
    case dormant

    private var rank: Int {
        switch self {
        case .failed: return 0
        case .waiting: return 1
        case .finished: return 2
        case .working: return 3
        case .completed: return 4
        case .dormant: return 5
        case .none: return 6
        }
    }

    static func resolve(
        activity: RuntimeActivity,
        attention: ConversationAttentionReason?
    ) -> ConversationIndicator {
        if activity == .failed { return .failed }
        switch attention {
        case .question: return .waiting
        case .finished: return .finished
        case nil: break
        }
        switch activity {
        case .working: return .working
        case .completed: return .completed
        case .dormant: return .dormant
        case .needsInput, .failed, .idle: return .none
        }
    }

    static func aggregate<S: Sequence>(_ values: S) -> ConversationIndicator
    where S.Element == ConversationIndicator {
        values.min { $0.rank < $1.rank } ?? .none
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
