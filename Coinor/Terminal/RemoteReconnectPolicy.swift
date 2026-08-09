import Foundation

/// How a remote pane reacts when its SSH channel dies.
///
/// The work itself does not stop: the Grok leader on the remote computer keeps
/// the session alive after its client disconnects, so reconnecting reattaches
/// to live work instead of restarting it.
struct RemoteReconnectPolicy: Equatable, Sendable {
    /// `ssh` reports its own failures, including every network failure, as
    /// 255. Any other status came from the remote command and must be shown
    /// rather than hidden behind a reconnect loop.
    static let sshFailureExitCode: UInt32 = 255

    let delays: [Duration]

    init(
        delays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8),
            .seconds(15),
        ]
    ) {
        self.delays = delays
    }

    func shouldReconnect(exitCode: UInt32, completedAttempts: Int) -> Bool {
        exitCode == Self.sshFailureExitCode
            && completedAttempts < delays.count
    }

    func delay(after completedAttempts: Int) -> Duration? {
        guard delays.indices.contains(completedAttempts) else { return nil }
        return delays[completedAttempts]
    }
}

/// What a remote pane is currently doing about its connection.
enum RemoteConnectionState: Equatable, Sendable {
    case connected
    case reconnecting(attempt: Int, of: Int)
    case disconnected

    var bannerText: String? {
        switch self {
        case .connected:
            nil
        case let .reconnecting(attempt, total):
            "Reconnecting… (\(attempt) of \(total))"
        case .disconnected:
            "Disconnected"
        }
    }
}


/// The environment every embedded terminal is started with.
///
/// Kept apart from the AppKit surface so the guarantees it carries can be
/// asserted directly: a Coinor terminal is always truecolor, and it never
/// passes on a colour suppression inherited from whatever launched the
/// application.
enum TerminalSurfaceEnvironment {
    static func variables(
        resourcesDirectory: String,
        terminfoDirectory: String,
        path: String,
        launch: TerminalLaunchRequest
    ) -> [(String, String)] {
        [
            ("GHOSTTY_RESOURCES_DIR", resourcesDirectory),
            ("TERMINFO", terminfoDirectory),
            ("PATH", path),
            // Programs that ask the environment instead of terminfo, including
            // Grok's theme catalog, need this to offer their full palette.
            ("COLORTERM", "truecolor"),
        ] + launch.surfaceEnvironment.sorted { $0.key < $1.key }
    }
}
