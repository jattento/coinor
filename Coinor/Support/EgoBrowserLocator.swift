import Foundation

/// Resolves the absolute path to the installed `ego-browser` CLI, the
/// automation runtime the third-party `ego lite` browser ships
/// (https://lite.ego.app). Coinor never bundles, installs, or updates this
/// binary itself; it only looks for it, and reports it missing rather than
/// failing when it is absent — the browser-mirror feature degrades to an
/// "unavailable" tab state instead of blocking anything else.
struct EgoBrowserLocator: @unchecked Sendable {
    /// The default install location ego lite's own onboarding writes to.
    static let defaultRelativePath = ".local/bin/ego-browser"
    static let executableName = "ego-browser"

    let fileManager: FileManager
    let environment: [String: String]
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// Returns the absolute path to `ego-browser` if it is installed and
    /// executable, checking the documented default location first, then
    /// `PATH`. Returns `nil` when it cannot be found.
    func resolve() -> String? {
        let defaultPath = homeDirectory
            .appendingPathComponent(Self.defaultRelativePath)
            .path
        if fileManager.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }
        guard let path = environment["PATH"], !path.isEmpty else {
            return nil
        }
        for directory in path.split(separator: ":") {
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(Self.executableName)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
