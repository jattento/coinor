import Foundation

struct GitWorktreeRecord: Equatable, Sendable {
    let path: String
    let head: String?
    let branch: String?
    let isBare: Bool
    let isDetached: Bool
}

enum GitPorcelain {
    static func worktrees(from output: String) throws -> [GitWorktreeRecord] {
        var records: [GitWorktreeRecord] = []
        var fields: [String: String] = [:]
        var flags: Set<String> = []

        func appendRecord() throws {
            guard !fields.isEmpty || !flags.isEmpty else { return }
            guard let path = fields["worktree"], !path.isEmpty else {
                throw GitServiceError.malformedOutput(
                    command: "git worktree list --porcelain",
                    detail: "a record has no worktree path"
                )
            }
            records.append(
                GitWorktreeRecord(
                    path: path,
                    head: fields["HEAD"],
                    branch: fields["branch"],
                    isBare: flags.contains("bare"),
                    isDetached: flags.contains("detached")
                )
            )
            fields.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty else {
                try appendRecord()
                continue
            }

            if let separator = line.firstIndex(of: " ") {
                fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
            } else {
                flags.insert(String(line))
            }
        }
        try appendRecord()
        return records
    }

    static func remoteDefaultBranch(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] == "HEAD" else { continue }
            let prefix = "ref: refs/heads/"
            guard fields[0].hasPrefix(prefix) else { continue }
            let branch = fields[0].dropFirst(prefix.count)
            return branch.isEmpty ? nil : String(branch)
        }
        return nil
    }
}
