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
        let supportDirectory = try? CoinorRuntimeEnvironment
            .applicationSupportDirectory()
        let paths = StartupPaths.live(
            homeDirectory: home,
            bundleResources: Bundle.main.resourceURL,
            applicationSupportDirectory: supportDirectory
        )
        return AppEnvironment(
            startupDiagnostics: EnvironmentStartupDiagnostics(paths: paths),
            grokUpdateChecker: GitHubGrokUpdateChecker.live()
        )
    }
}
