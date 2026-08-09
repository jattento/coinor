import Foundation

/// Reads the `Host` aliases the user already configured.
///
/// Conan Code offers these instead of asking for connection details, so it
/// never stores a user, port, key path, or credential of its own. Patterns and
/// negations are skipped: only a literal alias can be connected to.
struct SSHConfigHosts: Sendable {
    private let configURL: URL

    init(configURL: URL? = nil) {
        self.configURL = configURL
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".ssh/config", isDirectory: false)
    }

    func aliases() -> [RemoteHostAlias] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        return Self.aliases(in: String(decoding: data, as: UTF8.self))
    }

    static func aliases(in contents: String) -> [RemoteHostAlias] {
        var found: [RemoteHostAlias] = []
        var seen: Set<String> = []
        for line in contents.split(whereSeparator: \.isNewline) {
            // A trailing comment is part of the line, so it is cut before
            // tokenizing; otherwise its words are read as extra aliases.
            let withoutComment = line.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first ?? ""
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let separators = CharacterSet(charactersIn: " \t=")
            let fields = trimmed
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }
            guard fields.count > 1,
                  fields[0].caseInsensitiveCompare("Host") == .orderedSame
            else {
                continue
            }
            for field in fields.dropFirst() {
                guard !field.contains("*"),
                      !field.contains("?"),
                      !field.hasPrefix("!"),
                      let alias = RemoteHostAlias(rawValue: field),
                      seen.insert(alias.rawValue).inserted
                else {
                    continue
                }
                found.append(alias)
            }
        }
        return found
    }
}
