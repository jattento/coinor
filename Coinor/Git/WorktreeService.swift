import Foundation

struct WorktreeName: Hashable, Sendable {
    let rawValue: String

    init(validating value: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        let startsSafely = value.unicodeScalars.first.map {
            CharacterSet.alphanumerics.contains($0)
        } ?? false

        guard (1...64).contains(value.count),
              startsSafely,
              value.unicodeScalars.allSatisfy(allowed.contains),
              !value.contains("..")
        else {
            throw GitServiceError.invalidWorktreeName(value)
        }
        rawValue = value
    }
}

enum WorktreeBase: Equatable, Sendable {
    case remoteDefault(remote: String, branch: String, commit: String)
    case localHead(commit: String)

    var grokReference: String? {
        switch self {
        case let .remoteDefault(remote, branch, _):
            return "\(remote)/\(branch)"
        case .localHead:
            return nil
        }
    }
}

struct WorktreeCreationPlan: Equatable, Sendable {
    let project: GitProjectResolution
    let name: WorktreeName
    let base: WorktreeBase

    var workingDirectory: URL { project.mainCheckout }

    var grokArguments: [String] {
        var arguments = ["--worktree=\(name.rawValue)"]
        if let reference = base.grokReference {
            arguments.append("--worktree-ref=\(reference)")
        }
        return arguments
    }
}

struct WorktreeCreationResult: Equatable, Sendable {
    let plan: WorktreeCreationPlan
    let warning: String?
}

struct WorktreeService: Sendable {
    private let runner: any GitCommandRunning
    private let projectResolver: GitProjectResolver

    init(runner: any GitCommandRunning, target: ExecutionTarget = .local) {
        self.runner = runner
        self.projectResolver = GitProjectResolver(
            runner: runner,
            target: target
        )
    }

    /// Creates worktrees on a remote computer. Git, the fetch, and the
    /// default-branch resolution all run there, using that computer's own Git
    /// credentials.
    init(remote alias: RemoteHostAlias, runner: any RemoteCommandRunning) {
        self.runner = SSHGitCommandRunner(runner: runner, alias: alias)
        self.projectResolver = GitProjectResolver(
            remote: alias,
            runner: runner
        )
    }

    init() throws {
        let runner = try GitProcessRunner()
        self.init(runner: runner)
    }

    func prepareCreation(
        named rawName: String,
        from checkout: URL,
        preferredRemote: String? = nil
    ) throws -> WorktreeCreationResult {
        let name = try WorktreeName(validating: rawName)
        let project = try projectResolver.resolve(checkout: checkout)
        try validateBranchName(name, workingDirectory: project.mainCheckout)
        let localHead = try commit(
            reference: "HEAD",
            workingDirectory: project.mainCheckout
        )

        do {
            let remote = try selectRemote(
                preferred: preferredRemote,
                workingDirectory: project.mainCheckout
            )
            let branch = try discoverDefaultBranch(
                remote: remote,
                workingDirectory: project.mainCheckout
            )
            try fetch(remote: remote, workingDirectory: project.mainCheckout)
            let remoteReference = "\(remote)/\(branch)"
            let remoteCommit = try commit(
                reference: "refs/remotes/\(remoteReference)",
                workingDirectory: project.mainCheckout
            )
            return WorktreeCreationResult(
                plan: WorktreeCreationPlan(
                    project: project,
                    name: name,
                    base: .remoteDefault(
                        remote: remote,
                        branch: branch,
                        commit: remoteCommit
                    )
                ),
                warning: nil
            )
        } catch {
            return WorktreeCreationResult(
                plan: WorktreeCreationPlan(
                    project: project,
                    name: name,
                    base: .localHead(commit: localHead)
                ),
                warning: Self.fallbackWarning(for: error)
            )
        }
    }

    private func selectRemote(
        preferred: String?,
        workingDirectory: URL
    ) throws -> String {
        let result = try runner.runChecked(
            arguments: ["remote"],
            workingDirectory: workingDirectory
        )
        let remotes = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        if let preferred {
            guard remotes.contains(preferred) else {
                throw GitServiceError.malformedOutput(
                    command: "git remote",
                    detail: "the requested remote \(preferred) does not exist"
                )
            }
            return preferred
        }
        if remotes.contains("origin") {
            return "origin"
        }
        if remotes.count == 1, let only = remotes.first {
            return only
        }
        if remotes.isEmpty {
            throw GitServiceError.malformedOutput(
                command: "git remote",
                detail: "the repository has no remotes"
            )
        }
        throw GitServiceError.malformedOutput(
            command: "git remote",
            detail: "the repository has several remotes and none is named origin"
        )
    }

    private func validateBranchName(
        _ name: WorktreeName,
        workingDirectory: URL
    ) throws {
        let result = try runner.run(
            arguments: ["check-ref-format", "--branch", name.rawValue],
            workingDirectory: workingDirectory
        )
        guard result.succeeded else {
            throw GitServiceError.invalidWorktreeName(name.rawValue)
        }
    }

    private func discoverDefaultBranch(
        remote: String,
        workingDirectory: URL
    ) throws -> String {
        let advertised = try runner.runChecked(
            arguments: ["ls-remote", "--symref", remote, "HEAD"],
            workingDirectory: workingDirectory
        )
        guard let branch = GitPorcelain.remoteDefaultBranch(
            from: advertised.standardOutput
        ) else {
            throw GitServiceError.malformedOutput(
                command: "git ls-remote --symref \(remote) HEAD",
                detail: "the remote did not advertise a default branch"
            )
        }
        return branch
    }

    private func fetch(remote: String, workingDirectory: URL) throws {
        _ = try runner.runChecked(
            arguments: ["fetch", "--no-write-fetch-head", remote],
            workingDirectory: workingDirectory
        )
    }

    private func commit(reference: String, workingDirectory: URL) throws -> String {
        let result = try runner.runChecked(
            arguments: ["rev-parse", "--verify", "\(reference)^{commit}"],
            workingDirectory: workingDirectory
        )
        let commit = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else {
            throw GitServiceError.malformedOutput(
                command: "git rev-parse \(reference)",
                detail: "Git returned an empty commit"
            )
        }
        return commit
    }

    private static func fallbackWarning(for error: Error) -> String {
        let detail = error.localizedDescription
        return "Conan Code could not update the remote default branch. The new worktree will start from local HEAD instead. \(detail)"
    }
}
