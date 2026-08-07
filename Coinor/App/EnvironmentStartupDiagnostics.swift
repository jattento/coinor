import Foundation

/// Absolute locations the startup checks look at.
///
/// Every path is explicit so tests can point the checks at a temporary tree
/// instead of the developer's real home directory.
struct StartupPaths: Sendable {
    var homeDirectory: URL
    var grokExecutable: URL
    var ghosttyShellIntegration: URL
    var ghosttyTerminfo: URL
    var hookRegistration: URL
    var hookRelay: URL
    var bundledHookRelay: URL
    var leaderSocket: URL

    static func live(homeDirectory: URL, bundleResources: URL?) -> StartupPaths {
        let grokHooks = homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Coinor", isDirectory: true)
        let resources = bundleResources ?? Bundle.main.bundleURL

        return StartupPaths(
            homeDirectory: homeDirectory,
            grokExecutable: homeDirectory
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("grok"),
            ghosttyShellIntegration: resources
                .appendingPathComponent("ghostty", isDirectory: true)
                .appendingPathComponent("shell-integration", isDirectory: true),
            ghosttyTerminfo: resources
                .appendingPathComponent("terminfo", isDirectory: true)
                .appendingPathComponent("78", isDirectory: true)
                .appendingPathComponent("xterm-ghostty"),
            hookRegistration: grokHooks.appendingPathComponent("coinor.json"),
            hookRelay: grokHooks.appendingPathComponent("coinor-hook-relay"),
            bundledHookRelay: resources.appendingPathComponent("coinor-hook-relay"),
            leaderSocket: applicationSupport.appendingPathComponent("grok-leader.sock")
        )
    }

    /// Renders a path the way the user reads it, with the home directory folded to `~`.
    func display(_ url: URL) -> String {
        let path = url.path
        let home = homeDirectory.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// The file-system questions the startup checks ask.
struct StartupFileProbe: Sendable {
    var exists: @Sendable (URL) -> Bool
    var isExecutable: @Sendable (URL) -> Bool
    var readData: @Sendable (URL) -> Data?

    static let live = StartupFileProbe(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
        readData: { try? Data(contentsOf: $0) }
    )
}

/// Reports what the local machine can already provide, without starting Grok,
/// opening the leader socket, or touching the user's configuration.
struct EnvironmentStartupDiagnostics: StartupDiagnosticsProviding {
    let paths: StartupPaths
    let probe: StartupFileProbe

    init(paths: StartupPaths, probe: StartupFileProbe = .live) {
        self.paths = paths
        self.probe = probe
    }

    func runStartupChecks() async -> [StartupCheck] {
        StartupCheck.Kind.allCases.map(check(for:))
    }

    private func check(for kind: StartupCheck.Kind) -> StartupCheck {
        switch kind {
        case .grokExecutable:
            return grokExecutableCheck()
        case .ghosttyRuntime:
            return ghosttyRuntimeCheck()
        case .hookRegistration:
            return hookRegistrationCheck()
        case .leaderSocket:
            return leaderSocketCheck()
        }
    }

    private func grokExecutableCheck() -> StartupCheck {
        let location = paths.display(paths.grokExecutable)
        if probe.isExecutable(paths.grokExecutable) {
            return StartupCheck(kind: .grokExecutable, status: .passed, detail: location)
        }
        if probe.exists(paths.grokExecutable) {
            return StartupCheck(kind: .grokExecutable, status: .failed, detail: "Not executable at \(location)")
        }
        return StartupCheck(kind: .grokExecutable, status: .failed, detail: "Missing at \(location)")
    }

    private func ghosttyRuntimeCheck() -> StartupCheck {
        if probe.exists(paths.ghosttyShellIntegration),
           probe.exists(paths.ghosttyTerminfo) {
            return StartupCheck(kind: .ghosttyRuntime, status: .passed, detail: "Bundled resources available")
        }
        return StartupCheck(kind: .ghosttyRuntime, status: .failed, detail: "Bundled resources missing")
    }

    private func hookRegistrationCheck() -> StartupCheck {
        HookInstallationValidator(paths: paths, probe: probe).startupCheck()
    }

    private func leaderSocketCheck() -> StartupCheck {
        let location = paths.display(paths.leaderSocket)
        if probe.exists(paths.leaderSocket) {
            return StartupCheck(kind: .leaderSocket, status: .passed, detail: location)
        }
        return StartupCheck(kind: .leaderSocket, status: .warning, detail: "Not running at \(location)")
    }
}
