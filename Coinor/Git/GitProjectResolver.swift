import Foundation

struct GitProjectResolution: Equatable, Sendable {
    let identity: ProjectIdentity
    let commonDirectory: URL
    let mainCheckout: URL
}

struct GitProjectResolver: Sendable {
    private let runner: any GitCommandRunning
    private let target: ExecutionTarget
    /// Used only to read files that live on the remote computer.
    private let remoteRunner: (any RemoteCommandRunning)?

    init(runner: any GitCommandRunning, target: ExecutionTarget = .local) {
        self.runner = runner
        self.target = target
        self.remoteRunner = nil
    }

    init() throws {
        self.runner = try GitProcessRunner()
        self.target = .local
        self.remoteRunner = nil
    }

    /// Resolves a repository that lives on a remote computer. Git runs there;
    /// no path is ever checked against this file system.
    init(remote alias: RemoteHostAlias, runner: any RemoteCommandRunning) {
        self.runner = SSHGitCommandRunner(runner: runner, alias: alias)
        self.target = .remote(alias)
        self.remoteRunner = runner
    }

    func resolve(checkout: URL) throws -> GitProjectResolution {
        let directory = checkout.standardizedFileURL
        let commonResult: GitCommandResult
        do {
            commonResult = try runner.runChecked(
                arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                workingDirectory: directory
            )
        } catch {
            throw GitServiceError.invalidRepository(
                path: directory.path,
                detail: error.localizedDescription
            )
        }

        let commonPath = commonResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonPath.isEmpty else {
            throw GitServiceError.malformedOutput(
                command: "git rev-parse --git-common-dir",
                detail: "Git returned an empty common directory"
            )
        }
        let commonDirectory = canonicalURL(path: commonPath, relativeTo: directory)

        let worktreeResult = try runner.runChecked(
            arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: directory
        )
        let worktrees = try GitPorcelain.worktrees(from: worktreeResult.standardOutput)
        guard let primary = worktrees.first(where: { !$0.isBare }) else {
            throw GitServiceError.malformedOutput(
                command: "git worktree list --porcelain",
                detail: "Git returned no primary checkout"
            )
        }

        return GitProjectResolution(
            identity: ProjectIdentity(
                target: target,
                commonDirectory: commonDirectory
            ),
            commonDirectory: commonDirectory,
            mainCheckout: canonicalURL(path: primary.path, relativeTo: directory)
        )
    }

    func resolve(projectFor session: GrokPersistedSession) throws
        -> GitProjectResolution {
        var candidates: [URL] = []
        if let sourceWorkspaceDirectory = session.sourceWorkspaceDirectory {
            candidates.append(
                URL(
                    fileURLWithPath: sourceWorkspaceDirectory,
                    isDirectory: true
                )
            )
        }
        if let cwd = session.cwd {
            let checkout = URL(fileURLWithPath: cwd, isDirectory: true)
            if let source = grokWorktreeSource(checkout: checkout) {
                candidates.append(source)
            }
        }
        if let gitRootDirectory = session.gitRootDirectory {
            candidates.append(
                URL(
                    fileURLWithPath: gitRootDirectory,
                    isDirectory: true
                )
            )
        }
        if let cwd = session.cwd {
            candidates.append(URL(fileURLWithPath: cwd, isDirectory: true))
        }

        var visited: Set<String> = []
        var lastError: Error?
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard visited.insert(path).inserted else { continue }
            do {
                return try resolve(checkout: candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GitServiceError.invalidRepository(
            path: session.cwd ?? NSHomeDirectory(),
            detail: "Grok did not report a usable project directory"
        )
    }

    private func grokWorktreeSource(checkout: URL) -> URL? {
        guard let gitDirectoryResult = try? runner.runChecked(
            arguments: [
                "rev-parse",
                "--path-format=absolute",
                "--git-dir",
            ],
            workingDirectory: checkout
        ) else {
            return nil
        }
        let gitDirectoryPath = gitDirectoryResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDirectoryPath.isEmpty else { return nil }

        let gitDirectory = canonicalURL(
            path: gitDirectoryPath,
            relativeTo: checkout
        )
        let marker = gitDirectory.appendingPathComponent(
            "grok-worktree-source",
            isDirectory: false
        )
        let sourcePath: String
        switch target {
        case .local:
            guard let data = try? Data(contentsOf: marker) else { return nil }
            sourcePath = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .remote:
            // The marker lives on the remote file system, so it is read over
            // the same SSH channel rather than through `Data(contentsOf:)`.
            guard let remoteRunner,
                  let result = try? remoteRunner.run(
                      remoteCommand: "cat "
                          + ShellQuoting.quote(marker.path),
                      timeout: .seconds(20)
                  ),
                  result.succeeded
            else {
                return nil
            }
            sourcePath = result.trimmedOutput
        }
        guard !sourcePath.isEmpty else { return nil }
        return canonicalURL(path: sourcePath, relativeTo: checkout)
    }

    /// A remote path is canonical as text only. Local symlink resolution would
    /// silently rewrite it against the wrong file system.
    private func canonicalURL(path: String, relativeTo directory: URL) -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            url = directory.appendingPathComponent(path, isDirectory: true)
        }
        switch target {
        case .local:
            return url.standardizedFileURL.resolvingSymlinksInPath()
        case .remote:
            return URL(
                fileURLWithPath: ProjectIdentity(
                    target: target,
                    commonDirectory: url
                ).path,
                isDirectory: true
            )
        }
    }
}
