import Darwin
import Foundation

enum GrokSkillInstallerError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let skill):
            "Conan Code's \(skill) skill is missing from the application bundle."
        }
    }
}

/// One Grok skill Conan Code owns and keeps installed under `~/.grok/skills`.
///
/// The skills drive Conan Code's own control surface, so the application that
/// serves that surface is what ships them: an out-of-date copy on disk would
/// speak a protocol the running application no longer implements.
struct GrokSkillDescriptor: Sendable {
    struct File: Sendable {
        let resource: String
        let resourceExtension: String
        let installedName: String
        let permissions: Int
    }

    let directoryName: String
    let files: [File]

    static let longRunningTerminals = GrokSkillDescriptor(
        directoryName: "conan-code-long-running",
        files: [
            File(
                resource: "conan-code-long-running-SKILL",
                resourceExtension: "md",
                installedName: "SKILL.md",
                permissions: 0o600
            ),
            File(
                resource: "conan-code-terminal",
                resourceExtension: "sh",
                installedName: "terminal.sh",
                permissions: 0o700
            ),
        ]
    )

    static let sidechat = GrokSkillDescriptor(
        directoryName: "sidechat",
        files: [
            File(
                resource: "sidechat-SKILL",
                resourceExtension: "md",
                installedName: "SKILL.md",
                permissions: 0o600
            ),
            File(
                resource: "sidechat",
                resourceExtension: "sh",
                installedName: "sidechat.sh",
                permissions: 0o700
            ),
        ]
    )

    static let providerHealth = GrokSkillDescriptor(
        directoryName: "provider-health",
        files: [
            File(
                resource: "provider-health-SKILL",
                resourceExtension: "md",
                installedName: "SKILL.md",
                permissions: 0o600
            ),
            File(
                resource: "provider-health",
                resourceExtension: "sh",
                installedName: "provider-health.sh",
                permissions: 0o700
            ),
        ]
    )

    static let browser = GrokSkillDescriptor(
        directoryName: "conan-code-browser",
        files: [
            File(
                resource: "conan-code-browser-SKILL",
                resourceExtension: "md",
                installedName: "SKILL.md",
                permissions: 0o600
            ),
        ]
    )

    static let all: [GrokSkillDescriptor] = [
        longRunningTerminals,
        sidechat,
        providerHealth,
        browser,
    ]
}

struct GrokSkillInstaller {
    /// The convention Grok loads skills from: `<grok-home>/skills/<name>/`.
    /// This constant is the contract the live `grok` binary must keep.
    static let skillsDirectoryName = "skills"
    static let grokHomeDirectoryName = ".grok"

    let skills: [GrokSkillDescriptor]

    init(skills: [GrokSkillDescriptor] = GrokSkillDescriptor.all) {
        self.skills = skills
    }

    func install(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let skillsDirectory = homeDirectory
            .appendingPathComponent(Self.grokHomeDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.skillsDirectoryName, isDirectory: true)

        for skill in skills {
            let destinationDirectory = skillsDirectory
                .appendingPathComponent(
                    skill.directoryName,
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

            for file in skill.files {
                guard let source = bundle.url(
                    forResource: file.resource,
                    withExtension: file.resourceExtension
                ) else {
                    throw GrokSkillInstallerError.resourceMissing(
                        skill.directoryName
                    )
                }
                try install(
                    source: source,
                    destination: destinationDirectory
                        .appendingPathComponent(
                            file.installedName,
                            isDirectory: false
                        ),
                    permissions: file.permissions,
                    fileManager: fileManager
                )
            }
        }
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
