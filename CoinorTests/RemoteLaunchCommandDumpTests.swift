import Foundation
import Testing

@testable import Coinor

/// Writes the exact pane commands Conan Code would run for a remote
/// conversation so they can be executed on a real pseudo-terminal.
///
/// A Ghostty surface cannot be scripted, and this application's test host
/// cannot fork a pseudo-terminal safely, so the commands are dumped here and
/// driven by `scripts/verify/remote-panes.py`. Because the dump comes from
/// `TerminalLaunchRequest` itself, what the script runs is what the product
/// runs.
@Suite(.enabled(if: LiveRemoteEnvironment.isConfigured))
struct RemoteLaunchCommandDumpTests {
    @Test
    func dumpRemotePaneCommands() async throws {
        let alias = try #require(LiveRemoteEnvironment.alias)
        let runtime = try await RemoteHostRuntime.connect(
            alias: alias,
            supportDirectory: LiveRemoteEnvironment.supportDirectory,
            localVersion: try LiveRemoteEnvironment.localVersion()
        )
        let execution = await runtime.execution
        let home = await runtime.host.homeDirectory
        let sessions = try await runtime.control.listPersistedSessions()
        let root = sessions.first { !$0.isSubagent && $0.cwd != nil }
        let child = sessions.first { $0.isSubagent && $0.cwd != nil }
        let workingDirectory = LiveRemoteEnvironment.repository ?? home

        func grok(
            _ id: String,
            _ cwd: String,
            _ mode: TerminalLaunchRequest.Mode,
            context: TerminalSurfaceContext = .window
        ) -> String {
            TerminalLaunchRequest(
                sessionID: id,
                workingDirectory: cwd,
                grokExecutable: execution.grokExecutable,
                leaderSocket: execution.leaderSocket,
                mode: mode,
                surfaceContext: context,
                remote: execution.remote
            ).shellCommand
        }

        var commands: [String: String] = [
            "shell": TerminalLaunchRequest(
                shellTabID: UUID().uuidString,
                workingDirectory: home,
                remote: execution.remote
            ).explicitCommand ?? "",
            "ide_fresh": TerminalLaunchRequest(
                commandID: "ide.fresh",
                workingDirectory: workingDirectory,
                command: "fresh .",
                remote: execution.remote
            ).shellCommand,
            "ide_lazygit": TerminalLaunchRequest(
                commandID: "ide.lazygit",
                workingDirectory: workingDirectory,
                command: "lazygit",
                remote: execution.remote
            ).shellCommand,
            "new_session": grok(
                UUID().uuidString.lowercased(),
                workingDirectory,
                .newSession
            ),
        ]
        commands["home"] = home
        if let root, let cwd = root.cwd {
            commands["resume"] = grok(root.id.rawValue, cwd, .resume)
            commands["resume_session_id"] = root.id.rawValue
        }
        if let child, let cwd = child.cwd {
            commands["subagent"] = grok(
                child.id.rawValue,
                cwd,
                .resume,
                context: .split
            )
        }

        let data = try JSONSerialization.data(
            withJSONObject: commands,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: LiveRemoteEnvironment.dumpPath))
        await runtime.control.shutdown()

        #expect(commands["shell"]?.hasPrefix("'/usr/bin/ssh'") == true)
        #expect(commands["new_session"]?.contains("--session-id") == true)
    }
}
