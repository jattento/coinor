import Foundation

/// Single source of truth for the wire contract between Coinor's
/// terminal-control server and the coinorctl CLI. Both targets compile
/// this file (CoinorCtl via a symlink), so a rename or typo here cannot
/// silently desync the client, the server, or the tests.
enum TerminalControlContract {
    static let protocolVersion = 1

    /// Names of the environment variables Conan Code sets in managed
    /// terminal shells. These literals are deliberately simple strings so
    /// the shell scripts and release script can be pinned against them by
    /// tests; apps must always read from these constants.
    enum EnvironmentVariable {
        static let controlSocket =
            "CONAN_CODE_CONTROL_SOCKET"
        static let controlToken =
            "CONAN_CODE_CONTROL_TOKEN"
        static let controlClient =
            "CONAN_CODE_CONTROL_CLIENT"
        static let tabID =
            "CONAN_CODE_TAB_ID"
        static let tabCapability =
            "CONAN_CODE_TAB_CAPABILITY"
        static let requestID =
            "CONAN_CODE_REQUEST_ID"
        /// Set on the IDE tab's `fresh .` process so the `conan-code-tour`
        /// plugin knows which conversation to poll `tourWait` for.
        static let conversationID =
            "CONAN_CODE_CONVERSATION_ID"
        /// Set on the root Grok process so its native `point_to_code` tool
        /// (github.com/jattento/grok-build) knows which conversation it is
        /// queuing a request for.
        static let sessionID =
            "CONAN_CODE_SESSION_ID"
    }

    /// Method names for the 13 terminal-control methods.
    enum Method {
        static let create = "create"
        static let execute = "execute"
        static let read = "read"
        static let write = "write"
        static let key = "key"
        static let interrupt = "interrupt"
        static let status = "status"
        static let close = "close"
        static let shellReady = "shell-ready"
        static let fetchCommand = "fetch-command"
        static let commandFinished = "command-finished"
        /// Queues a code-pointer request for a conversation's IDE tab.
        /// Called by the native `point_to_code` tool running inside the
        /// root Grok process (see ADR 0019).
        static let pointToCode = "point-to-code"
        /// Polled by the `conan-code-tour` Fresh plugin (running inside
        /// the IDE tab's `fresh .`) to drain queued `pointToCode` requests.
        static let tourWait = "tour-wait"

        /// The names of all 13 methods, for iteration.
        static let all: [String] = [
            create,
            execute,
            read,
            write,
            key,
            interrupt,
            status,
            close,
            shellReady,
            fetchCommand,
            commandFinished,
            pointToCode,
            tourWait,
        ]
    }

    /// JSON field keys in the terminal-control request, response, and
    /// enrichment payloads.
    enum Field {
        static let version = "version"
        static let method = "method"
        static let token = "token"
        static let requestID = "requestID"
        static let title = "title"
        static let cwd = "cwd"
        static let tabID = "tabID"
        static let capability = "capability"
        static let command = "command"
        static let commandID = "commandID"
        static let text = "text"
        static let key = "key"
        static let cursor = "cursor"
        static let maxBytes = "maxBytes"
        static let exitCode = "exitCode"
        static let ok = "ok"
        static let result = "result"
        static let error = "error"
        static let code = "code"
        static let message = "message"
        static let state = "state"
        static let reset = "reset"
        static let truncated = "truncated"
        static let closed = "closed"
        static let shellExitCode = "shellExitCode"
        static let lastExitCode = "lastExitCode"
        static let sessionID = "sessionID"
        static let filePath = "filePath"
        static let lineStart = "lineStart"
        static let lineEnd = "lineEnd"
        static let comment = "comment"
        static let pending = "pending"
    }
}

/// Canned text that must appear verbatim in the shipped shell scripts and
/// the release script. The scripts cannot import Swift, so tests pin their
/// literals against these constants; app code must not copy these strings.
enum TerminalControlScriptText {
    /// Text that must appear verbatim in `Coinor/Resources/conan-code-terminal.sh`.
    static let conanCodeTerminalScriptAdverts: [String] = [
        TerminalControlContract.EnvironmentVariable.controlClient,
    ]

    /// Text that must appear verbatim in `Coinor/Resources/sidechat.sh`.
    static let sidechatScriptAdverts: [String] = [
        TerminalControlContract.EnvironmentVariable.controlClient,
        TerminalControlContract.EnvironmentVariable.requestID,
    ]

    /// Text that must appear verbatim in
    /// `Coinor/Resources/managed-terminal-bootstrap.zsh`.
    static let managedTerminalBootstrapAdverts: [String] = [
        TerminalControlContract.EnvironmentVariable.controlClient,
        TerminalControlContract.EnvironmentVariable.tabID,
        TerminalControlContract.EnvironmentVariable.tabCapability,
        TerminalControlContract.Method.shellReady,
        TerminalControlContract.Method.fetchCommand,
        TerminalControlContract.Method.commandFinished,
    ]

    /// Text that must appear verbatim in
    /// `scripts/release/verify-app.sh`.
    static let verifyAppScriptAdverts: [String] = [
        TerminalControlContract.EnvironmentVariable.controlSocket,
        TerminalControlContract.EnvironmentVariable.controlToken,
        TerminalControlContract.Method.status,
    ]
}

/// Filesystem access to the shipped scripts, used only by the tests that
/// pin the script literals. Kept out of the CLI-facing contract type so a
/// script path can never leak into the app or the coinorctl binary.
enum TerminalControlScriptFile {
    /// `<repo>/Coinor/Resources`, anchored to this file's own path.
    static var coinorResourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Resources", isDirectory: true
            )
    }

    /// `<repo>/scripts/release`, anchored to this file's own path.
    static var releaseScriptsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "scripts/release", isDirectory: true
            )
    }
}