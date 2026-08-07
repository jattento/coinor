import Foundation

@testable import Coinor

final class GitRepositoryFixture {
    let root: URL
    let repository: URL
    let runner: GitProcessRunner

    init(label: String) throws {
        runner = try GitProcessRunner()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coinor Git Tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        repository = root.appendingPathComponent("Primary Checkout", isDirectory: true)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try run(["init", "--initial-branch", "main", repository.path], at: root)
        try configureAuthor(at: repository)
        try commitFile(
            named: "README.md",
            contents: "initial\n",
            message: "Initial commit",
            at: repository
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func run(_ arguments: [String], at directory: URL? = nil) throws -> GitCommandResult {
        try runner.runChecked(
            arguments: arguments,
            workingDirectory: directory ?? repository
        )
    }

    func output(_ arguments: [String], at directory: URL? = nil) throws -> String {
        try run(arguments, at: directory).standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configureAuthor(at directory: URL) throws {
        try run(["config", "user.name", "Coinor Tests"], at: directory)
        try run(["config", "user.email", "coinor-tests@example.invalid"], at: directory)
    }

    @discardableResult
    func commitFile(
        named name: String,
        contents: String,
        message: String,
        at directory: URL
    ) throws -> String {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
        try run(["add", "--", name], at: directory)
        try run(["commit", "-m", message], at: directory)
        return try output(["rev-parse", "HEAD"], at: directory)
    }

    func addLinkedWorktree(named name: String = "Feature Worktree") throws -> URL {
        let worktree = root.appendingPathComponent(name, isDirectory: true)
        try run(
            ["worktree", "add", "-b", "feature-\(UUID().uuidString)", worktree.path, "HEAD"]
        )
        return worktree
    }

    func cloneIndependently(named name: String = "Independent Clone") throws -> URL {
        let clone = root.appendingPathComponent(name, isDirectory: true)
        try run(["clone", repository.path, clone.path], at: root)
        return clone
    }

    func addOrigin() throws -> URL {
        let remote = root.appendingPathComponent("Remote Repository.git", isDirectory: true)
        try run(
            ["init", "--bare", "--initial-branch", "main", remote.path],
            at: root
        )
        try run(["remote", "add", "origin", remote.path])
        try run(["push", "--set-upstream", "origin", "main"])
        try run(["remote", "set-head", "origin", "--auto"])
        return remote
    }

    func publishRemoteCommit(remote: URL) throws -> String {
        let publisher = root.appendingPathComponent("Remote Publisher", isDirectory: true)
        try run(["clone", remote.path, publisher.path], at: root)
        try configureAuthor(at: publisher)
        let commit = try commitFile(
            named: "remote.txt",
            contents: "remote update\n",
            message: "Remote update",
            at: publisher
        )
        try run(["push", "origin", "main"], at: publisher)
        return commit
    }
}

final class RemoveRemoteBeforeFetchRunner: GitCommandRunning, @unchecked Sendable {
    private let base: GitProcessRunner
    private let remote: URL
    private let lock = NSLock()
    private var removed = false

    init(base: GitProcessRunner, remote: URL) {
        self.base = base
        self.remote = remote
    }

    func run(arguments: [String], workingDirectory: URL) throws -> GitCommandResult {
        if arguments.first == "fetch" {
            lock.lock()
            let shouldRemove = !removed
            removed = true
            lock.unlock()
            if shouldRemove {
                try FileManager.default.removeItem(at: remote)
            }
        }
        return try base.run(
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}
