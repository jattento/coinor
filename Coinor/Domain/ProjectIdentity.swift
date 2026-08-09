import Foundation

/// Stable identity for one Git repository, on this computer or a remote one.
///
/// Linked worktrees share a canonical common directory. Independent clones
/// have different common directories even when they point at the same remote.
/// A remote repository is additionally qualified by its host, because the same
/// path can exist on two computers and mean two different projects.
///
/// Local identities keep their bare-path representation so metadata written
/// before remote hosts existed still resolves.
struct ProjectIdentity: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        if let separator = Self.hostSeparator(in: rawValue) {
            let alias = String(rawValue[rawValue.startIndex..<separator])
            let path = String(rawValue[rawValue.index(after: separator)...])
            self.rawValue = alias + ":" + Self.normalizedRemotePath(path)
            return
        }
        self.rawValue = URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    init(commonDirectory: URL) {
        self.init(rawValue: commonDirectory.path)
    }

    /// Remote paths are never resolved through the local file system: symlink
    /// resolution belongs to the machine that owns the path.
    init(target: ExecutionTarget, commonDirectory: URL) {
        switch target {
        case .local:
            self.init(rawValue: commonDirectory.path)
        case let .remote(alias):
            self.init(
                rawValue: alias.rawValue + ":"
                    + Self.normalizedRemotePath(commonDirectory.path)
            )
        }
    }

    var target: ExecutionTarget {
        guard let separator = Self.hostSeparator(in: rawValue),
              let alias = RemoteHostAlias(
                  rawValue: String(rawValue[rawValue.startIndex..<separator])
              )
        else {
            return .local
        }
        return .remote(alias)
    }

    /// The repository path on whichever computer owns it.
    var path: String {
        guard let separator = Self.hostSeparator(in: rawValue) else {
            return rawValue
        }
        return String(rawValue[rawValue.index(after: separator)...])
    }

    var commonDirectory: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A raw value is host-qualified only when the part before the first colon
    /// is a usable alias and the remainder is an absolute path, so a local
    /// directory containing a colon is never misread as a host.
    private static func hostSeparator(in rawValue: String) -> String.Index? {
        guard !rawValue.hasPrefix("/"),
              let separator = rawValue.firstIndex(of: ":"),
              separator != rawValue.startIndex,
              RemoteHostAlias(
                  rawValue: String(rawValue[rawValue.startIndex..<separator])
              ) != nil,
              rawValue[rawValue.index(after: separator)...].hasPrefix("/")
        else {
            return nil
        }
        return separator
    }

    /// Purely textual: a remote path must never be interpreted against this
    /// computer's file system, which is what `NSString.standardizingPath`
    /// would do for any path that happens to exist here too.
    private static func normalizedRemotePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            components.append(String(component))
        }
        let joined = "/" + components.joined(separator: "/")
        return joined
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
