import Foundation

enum CoinorRuntimeEnvironment {
    static let applicationSupportDirectoryKey =
        "COINOR_APPLICATION_SUPPORT_DIRECTORY"

    static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[applicationSupportDirectoryKey],
           !override.isEmpty {
            return URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Coinor", isDirectory: true)
    }
}

/// Composition root for the application.
///
/// Later phases add the Grok control client, metadata store, and runtime manager
/// here so the entry point stays a one-line wiring of environment to shell.
struct AppEnvironment: Sendable {
    var startupDiagnostics: any StartupDiagnosticsProviding
    var grokUpdateChecker: any GrokUpdateChecking
    var grokUpstreamSyncChecker: any GrokUpstreamSyncChecking

    init(
        startupDiagnostics: any StartupDiagnosticsProviding,
        grokUpdateChecker: any GrokUpdateChecking =
            GitHubGrokUpdateChecker.live(),
        grokUpstreamSyncChecker: any GrokUpstreamSyncChecking =
            GitHubGrokUpstreamSyncChecker.live()
    ) {
        self.startupDiagnostics = startupDiagnostics
        self.grokUpdateChecker = grokUpdateChecker
        self.grokUpstreamSyncChecker = grokUpstreamSyncChecker
    }

    static func live() -> AppEnvironment {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let supportDirectory = try? CoinorRuntimeEnvironment
            .applicationSupportDirectory()
        let paths = StartupPaths.live(
            homeDirectory: home,
            bundleResources: Bundle.main.resourceURL,
            applicationSupportDirectory: supportDirectory
        )
        return AppEnvironment(
            startupDiagnostics: EnvironmentStartupDiagnostics(paths: paths),
            grokUpdateChecker: GitHubGrokUpdateChecker.live(),
            grokUpstreamSyncChecker: GitHubGrokUpstreamSyncChecker.live()
        )
    }
}


/// Environment the application must not pass on to its terminals.
enum InheritedTerminalEnvironment {
    /// `NO_COLOR` counts as set even when empty, so it cannot be neutralized
    /// through Ghostty's per-surface variables. A value inherited from
    /// whatever launched the application - a shell, `open`, a script - would
    /// silently strip color from every embedded terminal, including Grok's
    /// truecolor themes. A user who wants it can still set it in the shell
    /// that runs inside the terminal.
    static func removeColorSuppression(
        unset: (String) -> Void = { unsetenv($0) }
    ) {
        unset("NO_COLOR")
    }
}
