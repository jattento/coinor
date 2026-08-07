import Foundation

/// Composition root for the application.
///
/// Later phases add the Grok control client, metadata store, and runtime manager
/// here so the entry point stays a one-line wiring of environment to shell.
struct AppEnvironment: Sendable {
    var startupDiagnostics: any StartupDiagnosticsProviding
    var grokUpdateChecker: any GrokUpdateChecking

    init(
        startupDiagnostics: any StartupDiagnosticsProviding,
        grokUpdateChecker: any GrokUpdateChecking =
            GitHubGrokUpdateChecker.live()
    ) {
        self.startupDiagnostics = startupDiagnostics
        self.grokUpdateChecker = grokUpdateChecker
    }

    static func live() -> AppEnvironment {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let paths = StartupPaths.live(homeDirectory: home, bundleResources: Bundle.main.resourceURL)
        return AppEnvironment(
            startupDiagnostics: EnvironmentStartupDiagnostics(paths: paths),
            grokUpdateChecker: GitHubGrokUpdateChecker.live()
        )
    }
}
