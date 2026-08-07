import Foundation

/// Stable identity for one local Git repository.
///
/// Linked worktrees share a canonical common directory. Independent clones
/// have different common directories even when they point at the same remote.
struct ProjectIdentity: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    init(commonDirectory: URL) {
        self.init(rawValue: commonDirectory.path)
    }

    var commonDirectory: URL {
        URL(fileURLWithPath: rawValue, isDirectory: true)
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
