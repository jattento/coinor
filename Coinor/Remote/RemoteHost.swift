import Foundation

/// One registered remote computer, identified only by its `~/.ssh/config`
/// alias.
///
/// Conan Code deliberately stores nothing else. User, port, key, and jump host
/// are OpenSSH's business, so no credential or connection detail is ever
/// persisted by the application.
struct RemoteHostAlias: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    /// Aliases come from the user's own SSH configuration, but they end up
    /// inside remote command lines, so anything that is not a plain host token
    /// is rejected rather than quoted.
    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 255 else { return nil }
        // ssh would parse a leading `-` as an option, not a destination.
        guard !trimmed.hasPrefix("-") else { return nil }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
        )
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        self.rawValue = trimmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let alias = RemoteHostAlias(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\(raw) is not a usable SSH host alias"
            )
        }
        self = alias
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a command runs.
///
/// Every Conan Code process is described by this before it is turned into an
/// argument vector or a shell command, so the local and remote paths cannot
/// drift apart.
enum ExecutionTarget: Hashable, Codable, Sendable {
    case local
    case remote(RemoteHostAlias)

    var remoteAlias: RemoteHostAlias? {
        switch self {
        case .local: nil
        case let .remote(alias): alias
        }
    }

    var isRemote: Bool { remoteAlias != nil }
}

/// A registered host and the remote facts Conan Code verified when it was
/// added.
struct RemoteHost: Equatable, Sendable {
    let alias: RemoteHostAlias
    let grokExecutablePath: String
    let grokVersion: String
    let leaderSocketPath: String
    let homeDirectory: String
    /// `sshd`'s `MaxSessions`, when it could be read. One conversation opens
    /// many multiplexed channels, so a low value is a real limit.
    let maximumSessions: Int?
    /// Set when both computers run the same base Grok version but different
    /// overlay builds. Worth telling the user about, not worth refusing.
    let versionWarning: String?
}
