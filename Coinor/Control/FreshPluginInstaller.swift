import Darwin
import Foundation

enum FreshPluginInstallerError: LocalizedError {
    case resourceMissing

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "Conan Code's conan-code-tour Fresh plugin is missing from the application bundle."
        }
    }
}

/// Installs the `conan-code-tour` plugin Fresh autoloads from
/// `~/.config/fresh/plugins/` (see ADR 0019). Mirrors
/// `GrokSkillInstaller`'s atomic-write, content-comparison, and
/// permission-setting behavior for the same reason: an out-of-date copy on
/// disk would poll a control-socket contract the running application no
/// longer implements.
struct FreshPluginInstaller {
    static let installedName = "conan-code-tour.ts"
    static let configDirectoryName = ".config"
    static let freshDirectoryName = "fresh"
    static let pluginsDirectoryName = "plugins"

    func install(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        // Bundled as `.txt`: Xcode's synchronized group does not copy a
        // `.ts` resource (it tries to treat it as TypeScript source), so
        // the extension changes at install time instead, same as skill
        // resources already do (`conan-code-long-running-SKILL.md` bundled
        // vs. installed `SKILL.md`).
        guard let source = bundle.url(
            forResource: "conan-code-tour",
            withExtension: "txt"
        ) else {
            throw FreshPluginInstallerError.resourceMissing
        }
        let pluginsDirectory = homeDirectory
            .appendingPathComponent(Self.configDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.freshDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.pluginsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try install(
            source: source,
            destination: pluginsDirectory
                .appendingPathComponent(Self.installedName, isDirectory: false),
            fileManager: fileManager
        )
    }

    private func install(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == data {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: destination.path
            )
            return
        }
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString)",
                isDirectory: false
            )
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporary.path
        )
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
