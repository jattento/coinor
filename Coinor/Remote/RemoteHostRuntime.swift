import Foundation

/// One registered remote computer as Conan Code uses it at runtime: its SSH
/// channel, its own Grok control plane, and the catalog facts that came from
/// it.
///
/// Every remote host owns a separate control client, because a control client
/// is bound to exactly one Grok leader and each computer has its own.
@MainActor
final class RemoteHostRuntime {
    let host: RemoteHost
    let ssh: SSHCommand
    let control: GrokControlClient

    var persistedSessions: [GrokPersistedSession] = []
    var roster: [String: GrokRosterEntry] = [:]
    var projectIDBySessionID: [String: String] = [:]
    var mainCheckoutByProjectID: [String: String] = [:]
    /// Set when the host stops answering. Its projects stay in the sidebar so
    /// an unreachable computer looks unavailable rather than deleted.
    var unreachableReason: String?

    var alias: RemoteHostAlias { host.alias }

    var target: ExecutionTarget { .remote(host.alias) }

    var execution: ConversationExecution {
        ConversationExecution(
            grokExecutable: host.grokExecutablePath,
            leaderSocket: host.leaderSocketPath,
            remote: RemoteExecution(ssh: ssh)
        )
    }

    var commandRunner: any RemoteCommandRunning {
        SSHCommandRunner(ssh: ssh)
    }

    init(host: RemoteHost, ssh: SSHCommand, control: GrokControlClient) {
        self.host = host
        self.ssh = ssh
        self.control = control
    }

    /// Probes the host, then opens its control plane. Connecting is what
    /// starts the remote Grok leader: the first `--leader` client spawns it as
    /// a detached process, so it keeps running after this connection closes.
    static func connect(
        alias: RemoteHostAlias,
        supportDirectory: URL,
        localVersion: GrokForkVersion
    ) async throws -> RemoteHostRuntime {
        let ssh = SSHCommand(alias: alias, supportDirectory: supportDirectory)
        try ssh.prepareControlDirectory()

        let runner = SSHCommandRunner(ssh: ssh)
        let probe = RemoteHostProbe(runner: runner, alias: alias)
        let host = try await Task.detached {
            try probe.probe(localVersion: localVersion)
        }.value

        let launch = GrokControlLaunch(
            executable: GrokExecutable(
                url: URL(
                    fileURLWithPath: host.grokExecutablePath,
                    isDirectory: false
                )
            ),
            leaderSocket: try GrokLeaderSocket(path: host.leaderSocketPath),
            // The compatibility probes send this directory to the remote agent
            // as a `cwd`, so it must be a path that exists there.
            workingDirectory: URL(
                fileURLWithPath: host.homeDirectory,
                isDirectory: true
            ),
            remote: RemoteControlPlane(ssh: ssh)
        )
        // The version was already read on the remote computer in the probe's
        // single round trip; running `grok --version` here would execute a
        // remote path against this file system.
        let versionText = host.grokVersion
        let control = GrokControlClient(
            launch: launch,
            executableVersionProbe: { _, _ in versionText }
        )
        do {
            _ = try await control.connect()
        } catch {
            await control.shutdown()
            throw RemoteHostError.leaderUnavailable(
                alias: alias.rawValue,
                detail: error.localizedDescription
            )
        }
        return RemoteHostRuntime(host: host, ssh: ssh, control: control)
    }

    func shutdown() async {
        await control.shutdown()
    }

    /// Ends the remote runtime itself. Explicit and destructive: every agent
    /// still working on that computer stops.
    func stopRemoteRuntime() async throws {
        await control.shutdown()
        let runner = commandRunner
        let alias = host.alias
        let command = RemoteRuntimeStopCommand.command(
            lockPath: RemoteRuntimeStopCommand.lockPath(
                forSocket: host.leaderSocketPath
            )
        )
        try await Task.detached {
            _ = try runner.runChecked(remoteCommand: command, alias: alias)
        }.value
    }
}

/// Ends the Grok leader on a remote computer.
///
/// The leader daemonizes: it reparents to `launchd` and its command line does
/// not repeat `--leader-socket`, so a command-line pattern never matches it.
/// It is identified by the PID in the lock file beside its socket, exactly as
/// the local path does, and is only signalled when that PID really is Grok.
enum RemoteRuntimeStopCommand {
    static func lockPath(forSocket socket: String) -> String {
        (socket as NSString).deletingPathExtension.appending(".lock")
    }

    /// Mirrors the local leader shutdown: a graceful signal, a bounded wait,
    /// then `SIGKILL`. A single `SIGTERM` returns before the leader is gone,
    /// which leaves the runtime running behind a UI that says it stopped.
    static func command(lockPath: String) -> String {
        """
        pid=$(cat \(ShellQuoting.quote(lockPath)) 2>/dev/null)
        [ -n "${pid:-}" ] || exit 0
        case "$(ps -p "$pid" -o command= 2>/dev/null)" in
            *grok*) ;;
            *) exit 0 ;;
        esac
        kill "$pid" 2>/dev/null || exit 0
        i=0
        while [ $i -lt 40 ]; do
            kill -0 "$pid" 2>/dev/null || exit 0
            sleep 0.1
            i=$((i + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
        i=0
        while [ $i -lt 20 ]; do
            kill -0 "$pid" 2>/dev/null || exit 0
            sleep 0.1
            i=$((i + 1))
        done
        exit 1
        """
    }
}
