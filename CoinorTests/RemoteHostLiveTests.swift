import Foundation
import Testing

@testable import Coinor

/// Exercises the remote-host path against a real computer over real SSH.
///
/// Everything here runs through the production types, so a passing run is
/// evidence about Conan Code rather than about a hand-written command. The
/// suite is skipped unless `COINOR_LIVE_REMOTE_HOST` names a reachable
/// `~/.ssh/config` alias, because the ordinary test suite must never depend on
/// another machine.
///
/// Optional `COINOR_LIVE_REMOTE_REPO` points at a Git repository on that
/// computer and enables the project-resolution checks.
@Suite(.enabled(if: LiveRemoteEnvironment.isConfigured))
struct RemoteHostLiveTests {
    private var alias: RemoteHostAlias {
        get throws {
            try #require(LiveRemoteEnvironment.alias)
        }
    }

    private func ssh() throws -> SSHCommand {
        SSHCommand(
            alias: try alias,
            controlPath: LiveRemoteEnvironment.controlPath
        )
    }

    @Test
    func probeReportsTheRemoteRuntimeFacts() throws {
        let command = try ssh()
        try command.prepareControlDirectory()
        let host = try RemoteHostProbe(
            runner: SSHCommandRunner(ssh: command),
            alias: try alias
        ).probe(localVersion: try LiveRemoteEnvironment.localVersion())

        #expect(host.homeDirectory.hasPrefix("/"))
        #expect(host.grokExecutablePath.hasSuffix("/bin/grok"))
        #expect(host.leaderSocketPath.hasSuffix("grok-leader-remote.sock"))
        #expect(
            host.leaderSocketPath.utf8.count
                <= GrokLeaderSocket.maximumPathLength
        )
        // The remote runtime socket must never be the one that computer's own
        // Conan Code uses, or the two installations would fight over it.
        #expect(!host.leaderSocketPath.hasSuffix("/grok-leader.sock"))
    }

    @Test
    func connectingStartsTheRemoteRuntimeAndReadsItsCatalog() async throws {
        let runtime = try await RemoteHostRuntime.connect(
            alias: try alias,
            supportDirectory: LiveRemoteEnvironment.supportDirectory,
            localVersion: try LiveRemoteEnvironment.localVersion()
        )

        // `connect` completes only after the ACP handshake and the required
        // extension probes succeed against the remote agent.
        let sessions = try await runtime.control.listPersistedSessions()
        let roster = try await runtime.control.listRoster()
        #expect(sessions.allSatisfy { !$0.id.rawValue.isEmpty })
        #expect(roster.allSatisfy { !$0.id.rawValue.isEmpty })

        let execution = await runtime.execution
        #expect(execution.isRemote)
        #expect(execution.remote?.alias == (try alias))

        // The leader is a detached process, so it is still there after the
        // control connection goes away.
        await runtime.control.shutdown()
        let lockPath = RemoteRuntimeStopCommand.lockPath(
            forSocket: await runtime.host.leaderSocketPath
        )
        let survivor = try SSHCommandRunner(ssh: try ssh()).run(
            remoteCommand: "ps -p \"$(cat "
                + ShellQuoting.quote(lockPath)
                + ")\" -o command=",
            timeout: .seconds(20)
        )
        #expect(survivor.trimmedOutput.contains("grok"))
        #expect(survivor.trimmedOutput.contains("--no-exit-on-disconnect"))

        try await runtime.stopRemoteRuntime()
        let stopped = try SSHCommandRunner(ssh: try ssh()).run(
            remoteCommand: "ps -p \"$(cat "
                + ShellQuoting.quote(lockPath)
                + " 2>/dev/null)\" -o command= 2>/dev/null || true",
            timeout: .seconds(20)
        )
        #expect(!stopped.trimmedOutput.contains("agent leader"))
    }

    @Test(.enabled(if: LiveRemoteEnvironment.repository != nil))
    func gitResolvesARemoteProjectOverSSH() throws {
        let repository = try #require(LiveRemoteEnvironment.repository)
        let resolution = try GitProjectResolver(
            remote: try alias,
            runner: SSHCommandRunner(ssh: try ssh())
        ).resolve(
            checkout: URL(fileURLWithPath: repository, isDirectory: true)
        )

        #expect(resolution.identity.target == .remote(try alias))
        #expect(resolution.identity.rawValue.hasPrefix(
            (try alias).rawValue + ":/"
        ))
        #expect(resolution.mainCheckout.path.hasPrefix("/"))
    }

    @Test
    func discoveryListsRemoteDirectoriesAndRepositories() throws {
        let runner = SSHCommandRunner(ssh: try ssh())
        let discovery = RemoteProjectDiscovery(runner: runner, alias: try alias)
        let home = try discovery.homeDirectory()
        #expect(home.hasPrefix("/"))

        let entries = try discovery.directoryEntries(at: home)
        #expect(entries.allSatisfy { $0.path.hasPrefix(home) })

        let candidates = try discovery.candidates(knownGitRoots: [])
        #expect(candidates.allSatisfy { !$0.name.isEmpty })
    }

    @Test
    func theIDEAndGitTabToolsExistOnTheRemoteComputer() throws {
        // A remote IDE or Git tab runs these through the remote login shell,
        // so a missing tool is a real product failure rather than a warning.
        let result = try SSHCommandRunner(ssh: try ssh()).run(
            remoteCommand: SSHCommand.remoteShellCommand(
                command: "command -v fresh; command -v lazygit",
                workingDirectory: try RemoteProjectDiscovery(
                    runner: SSHCommandRunner(ssh: try ssh()),
                    alias: try alias
                ).homeDirectory()
            ),
            timeout: .seconds(45)
        )

        #expect(result.standardOutput.contains("fresh"))
        #expect(result.standardOutput.contains("lazygit"))
    }

    @Test
    func manyConcurrentChannelsShareOneConnection() throws {
        // One conversation opens root, subagents, two IDE tools, shells, and
        // the control client at once. `MaxSessions` on the remote host caps
        // that, so the real ceiling is measured rather than assumed.
        let runner = SSHCommandRunner(ssh: try ssh())
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        for index in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let result = try runner.run(
                        remoteCommand: "sleep 2; echo channel-\(index)",
                        timeout: .seconds(45)
                    )
                    if !result.succeeded {
                        lock.lock()
                        failures.append(
                            "channel \(index): \(result.standardError)"
                        )
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failures.append("channel \(index): \(error)")
                    lock.unlock()
                }
            }
        }
        group.wait()

        #expect(failures.isEmpty, "\(failures)")
    }
}

enum LiveRemoteEnvironment {
    static var alias: RemoteHostAlias? {
        ProcessInfo.processInfo.environment["COINOR_LIVE_REMOTE_HOST"]
            .flatMap(RemoteHostAlias.init(rawValue:))
    }

    static var repository: String? {
        ProcessInfo.processInfo.environment["COINOR_LIVE_REMOTE_REPO"]
    }

    static var isConfigured: Bool { alias != nil }

    /// Kept short so the multiplexing socket fits `sockaddr_un`.
    static let controlPath = "/tmp/coinor-live.sock"

    /// Where the pane commands are written for `scripts/verify/remote-panes.py`.
    static let dumpPath = "/tmp/coinor-remote-commands.json"

    static var supportDirectory: URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
    }

    static func localVersion() throws -> GrokForkVersion {
        let executable = try GrokExecutable.resolve()
        let process = Process()
        process.executableURL = executable.url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let version = GrokForkVersion(text: text) else {
            throw GrokControlError.executableVersionEmpty(executable.path)
        }
        return version
    }
}
