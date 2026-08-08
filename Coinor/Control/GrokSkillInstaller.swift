import Darwin
import Foundation

enum GrokSkillInstallerError: LocalizedError {
    case resourceMissing

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "Conan Code's long-running-command skill is missing from the application bundle."
        }
    }
}

struct GrokSkillInstaller {
    static let skillDirectoryName = "conan-code-long-running"

    func install(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        guard let skillSource = bundle.url(
            forResource: "conan-code-long-running-SKILL",
            withExtension: "md"
        ), let wrapperSource = bundle.url(
            forResource: "conan-code-terminal",
            withExtension: "sh"
        ) else {
            throw GrokSkillInstallerError.resourceMissing
        }
        let destinationDirectory = homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(
                Self.skillDirectoryName,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: 0o700),
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: destinationDirectory.path
        )

        try install(
            source: skillSource,
            destination: destinationDirectory.appendingPathComponent(
                "SKILL.md",
                isDirectory: false
            ),
            permissions: 0o600,
            fileManager: fileManager
        )
        try install(
            source: wrapperSource,
            destination: destinationDirectory.appendingPathComponent(
                "terminal.sh",
                isDirectory: false
            ),
            permissions: 0o700,
            fileManager: fileManager
        )
    }

    private func install(
        source: URL,
        destination: URL,
        permissions: Int,
        fileManager: FileManager
    ) throws {
        let data = try Data(contentsOf: source)
        if (try? Data(contentsOf: destination)) == data {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
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
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: temporary.path
        )
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
