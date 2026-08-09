import Foundation
import Testing

@testable import Coinor

/// The remote-host operations that change state on the other computer:
/// renaming a conversation, creating a worktree, and reading the subagent
/// lifecycle Conan Code's panes depend on.
///
/// Skipped unless `COINOR_LIVE_REMOTE_HOST` names a reachable alias. Anything
/// created here is removed again before the test ends.
@Suite(.enabled(if: LiveRemoteEnvironment.isConfigured), .serialized)
struct RemoteHostLiveOperationsTests {
    private func ssh() throws -> SSHCommand {
        let command = SSHCommand(
            alias: try #require(LiveRemoteEnvironment.alias),
            controlPath: LiveRemoteEnvironment.controlPath
        )
        try command.prepareControlDirectory()
        return command
    }

    private func connected() async throws -> RemoteHostRuntime {
        try await RemoteHostRuntime.connect(
            alias: try #require(LiveRemoteEnvironment.alias),
            supportDirectory: LiveRemoteEnvironment.supportDirectory,
            localVersion: try LiveRemoteEnvironment.localVersion()
        )
    }

    @Test
    func renamingARemoteConversationGoesThroughTheRemoteLeader() async throws {
        let runtime = try await connected()
        let sessions = try await runtime.control.listPersistedSessions()
        let target = try #require(
            sessions.first { !$0.isSubagent && $0.cwd != nil }
        )
        let originalTitle = target.title

        let marker = "Conan Code remote check \(UUID().uuidString.prefix(8))"
        try await runtime.control.rename(
            target.id,
            to: marker,
            inDirectory: try #require(target.cwd)
        )

        let renamed = try await runtime.control.listPersistedSessions()
        let row = renamed.first { $0.id == target.id }
        #expect(row?.title == marker)

        // Grok owns the title, so the original is put back rather than left
        // renamed on the user's own computer.
        if let originalTitle {
            try await runtime.control.rename(
                target.id,
                to: originalTitle,
                inDirectory: try #require(target.cwd)
            )
        }
        await runtime.control.shutdown()
    }

    @Test
    func theSubagentLifecycleAPIAnswersOnTheRemoteComputer() async throws {
        let runtime = try await connected()
        let sessions = try await runtime.control.listPersistedSessions()
        let target = try #require(
            sessions.first { !$0.isSubagent && $0.cwd != nil }
        )

        // Conan Code opens and closes subagent panes from this stream, so a
        // remote host that cannot answer it would silently never show one.
        let observations = try await runtime.control.listSubagentLifecycle(
            sessionID: target.id.rawValue,
            cwd: try #require(target.cwd)
        )
        #expect(observations.allSatisfy { !$0.childSessionID.isEmpty })

        await runtime.control.shutdown()
    }

    @Test(.enabled(if: LiveRemoteEnvironment.repository != nil))
    func creatingAWorktreeRunsEntirelyOnTheRemoteComputer() throws {
        let alias = try #require(LiveRemoteEnvironment.alias)
        let repository = try #require(LiveRemoteEnvironment.repository)
        let runner = SSHCommandRunner(ssh: try ssh())
        let name = "coinor-live-\(UUID().uuidString.prefix(8))"

        let result = try WorktreeService(remote: alias, runner: runner)
            .prepareCreation(
                named: name,
                from: URL(fileURLWithPath: repository, isDirectory: true)
            )

        #expect(result.plan.project.identity.target == .remote(alias))
        #expect(result.plan.grokArguments.contains("--worktree=\(name)"))
        // The plan must point at the remote computer's paths, never this one's.
        #expect(result.plan.project.mainCheckout.path.hasPrefix("/Users/"))
        #expect(
            FileManager.default.fileExists(
                atPath: result.plan.project.mainCheckout.path
            ) == false
        )
    }
}
