import Foundation

struct RemoteCommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32

    var succeeded: Bool { terminationStatus == 0 }

    var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol RemoteCommandRunning: Sendable {
    func run(
        remoteCommand: String,
        timeout: Duration
    ) throws -> RemoteCommandResult
}

/// Runs one non-interactive command on a remote host and captures its output.
///
/// This is the background path: host health, project discovery, and Git. It
/// refuses credential prompts, because an invisible channel waiting on a
/// passphrase is indistinguishable from a hang.
struct SSHCommandRunner: RemoteCommandRunning, Sendable {
    private let ssh: SSHCommand

    init(ssh: SSHCommand) {
        self.ssh = ssh
    }

    func run(
        remoteCommand: String,
        timeout: Duration = .seconds(30)
    ) throws -> RemoteCommandResult {
        try ssh.prepareControlDirectory()

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: SSHCommand.executablePath,
            isDirectory: false
        )
        process.arguments = ssh.arguments(
            remoteCommand: remoteCommand,
            allocateTTY: false,
            batch: true
        )
        process.standardInput = FileHandle.nullDevice

        do {
            let capture = try SubprocessOutputCapture(label: "ssh")
            let captured = try capture.run(process: process, deadline: timeout)
            return RemoteCommandResult(
                standardOutput: captured.standardOutput,
                standardError: captured.standardError,
                terminationStatus: captured.terminationStatus
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch SubprocessCaptureError.timedOut {
            throw RemoteHostError.unreachable(
                alias: ssh.alias.rawValue,
                detail: "the command did not finish within "
                    + "\(Int(SubprocessOutputCapture.seconds(in: timeout))) seconds"
            )
        } catch {
            throw RemoteHostError.unreachable(
                alias: ssh.alias.rawValue,
                detail: error.localizedDescription
            )
        }
    }
}

extension RemoteCommandRunning {
    func runChecked(
        remoteCommand: String,
        alias: RemoteHostAlias,
        timeout: Duration = .seconds(30)
    ) throws -> RemoteCommandResult {
        let result = try run(remoteCommand: remoteCommand, timeout: timeout)
        guard result.succeeded else {
            throw RemoteHostError.commandFailed(
                alias: alias.rawValue,
                command: remoteCommand,
                status: result.terminationStatus,
                detail: RemoteHostError.detail(
                    fromSSHStandardError: result.standardError
                )
            )
        }
        return result
    }
}

/// Runs Git on a remote host through the same interface the local resolver
/// already uses, so project resolution, worktree listing, and fetch logic have
/// exactly one implementation.
struct SSHGitCommandRunner: GitCommandRunning, Sendable {
    private let runner: any RemoteCommandRunning
    private let alias: RemoteHostAlias
    private let gitExecutable: String

    init(
        runner: any RemoteCommandRunning,
        alias: RemoteHostAlias,
        gitExecutable: String = "git"
    ) {
        self.runner = runner
        self.alias = alias
        self.gitExecutable = gitExecutable
    }

    func run(arguments: [String], workingDirectory: URL) throws -> GitCommandResult {
        let remoteCommand = SSHCommand.remoteCommand(
            executable: gitExecutable,
            arguments: arguments,
            workingDirectory: workingDirectory.path,
            environment: [
                "LC_ALL": "C",
                "LANG": "C",
                "GIT_TERMINAL_PROMPT": "0",
            ]
        )
        let result: RemoteCommandResult
        do {
            result = try runner.run(
                remoteCommand: remoteCommand,
                timeout: .seconds(60)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitServiceError.commandLaunchFailed(
                arguments: arguments,
                detail: error.localizedDescription
            )
        }
        return GitCommandResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            terminationStatus: result.terminationStatus
        )
    }
}
