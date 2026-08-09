import Foundation

/// A repository Conan Code found on a remote computer, ready to be offered in
/// the picker.
struct RemoteRepositoryCandidate: Equatable, Identifiable, Sendable {
    let path: String
    let name: String

    var id: String { path }
}

/// One entry of a remote directory listing.
struct RemoteDirectoryEntry: Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let isRepository: Bool

    var id: String { path }
}

/// Finds repositories on a remote computer so the user never types a path.
///
/// `NSOpenPanel` can only see this computer's file system, so the picker is
/// fed from here: the repositories the host's Grok catalog already knows,
/// plus a bounded scan, plus an explicit directory listing as a fallback.
struct RemoteProjectDiscovery: Sendable {
    private let runner: any RemoteCommandRunning
    private let alias: RemoteHostAlias

    init(runner: any RemoteCommandRunning, alias: RemoteHostAlias) {
        self.runner = runner
        self.alias = alias
    }

    /// - Parameter knownGitRoots: repository paths already present in the
    ///   host's Grok catalog. They are cheap, exact, and listed first.
    func candidates(
        knownGitRoots: [String],
        searchRoots: [String] = ["$HOME/projects", "$HOME/Developer", "$HOME/src"],
        maximumDepth: Int = 4
    ) throws -> [RemoteRepositoryCandidate] {
        var seen: Set<String> = []
        var found: [RemoteRepositoryCandidate] = []
        for path in knownGitRoots {
            let normalized = Self.normalized(path)
            guard seen.insert(normalized).inserted else { continue }
            found.append(Self.candidate(path: normalized))
        }

        // One bounded `find` per host: deeper or unbounded scans on a large
        // disk cost far more than the picker is worth.
        let roots = searchRoots
            .map { $0.hasPrefix("$HOME") ? "\"$HOME\"" + $0.dropFirst(5) : ShellQuoting.quote($0) }
            .joined(separator: " ")
        let command = """
        for root in \(roots); do
            [ -d "$root" ] || continue
            find "$root" -maxdepth \(maximumDepth) -type d -name .git \
        -prune -print 2>/dev/null
        done
        """
        let result = try runner.run(remoteCommand: command, timeout: .seconds(45))
        guard result.succeeded else {
            // A discovery failure is not fatal: the browser fallback and the
            // known roots still let the user add a project.
            return found
        }
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let gitPath = String(line).trimmingCharacters(in: .whitespaces)
            guard gitPath.hasSuffix("/.git") else { continue }
            let repository = String(gitPath.dropLast("/.git".count))
            let normalized = Self.normalized(repository)
            guard seen.insert(normalized).inserted else { continue }
            found.append(Self.candidate(path: normalized))
        }
        return found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Lists one remote directory, marking which entries are repositories.
    func directoryEntries(at path: String) throws -> [RemoteDirectoryEntry] {
        let command = """
        cd \(ShellQuoting.quote(path)) || exit 4
        for entry in */ ; do
            [ -d "$entry" ] || continue
            name=${entry%/}
            if [ -e "$name/.git" ]; then
                printf 'repo\\t%s\\n' "$name"
            else
                printf 'dir\\t%s\\n' "$name"
            fi
        done
        """
        let result = try runner.runChecked(
            remoteCommand: command,
            alias: alias,
            timeout: .seconds(30)
        )
        let base = Self.normalized(path)
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2 else { return nil }
                let name = String(fields[1])
                return RemoteDirectoryEntry(
                    path: base == "/" ? "/" + name : base + "/" + name,
                    name: name,
                    isRepository: fields[0] == "repo"
                )
            }
    }

    func homeDirectory() throws -> String {
        try runner.runChecked(
            remoteCommand: "printf %s \"$HOME\"",
            alias: alias,
            timeout: .seconds(20)
        ).trimmedOutput
    }

    private static func candidate(path: String) -> RemoteRepositoryCandidate {
        RemoteRepositoryCandidate(
            path: path,
            name: (path as NSString).lastPathComponent
        )
    }

    private static func normalized(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix("/.git") {
            value = String(value.dropLast("/.git".count))
        }
        return value
    }
}
