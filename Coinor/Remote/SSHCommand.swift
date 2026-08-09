import Foundation

/// POSIX single-quoting.
///
/// Remote execution always crosses at least one shell, so every interpolated
/// value is quoted here rather than concatenated. This is the only place that
/// is allowed to build a remote command string.
enum ShellQuoting {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}

/// Builds the `ssh` argument vectors Conan Code uses to run remote commands.
///
/// All channels for one host share a Conan Code-owned master connection, so a
/// conversation's root pane, subagents, IDE tools, shells, and control client
/// cost one TCP connection instead of one each.
struct SSHCommand: Sendable {
    static let executablePath = "/usr/bin/ssh"

    let alias: RemoteHostAlias
    let controlPath: String

    init(alias: RemoteHostAlias, controlPath: String) {
        self.alias = alias
        self.controlPath = controlPath
    }

    init(alias: RemoteHostAlias, supportDirectory: URL) {
        self.alias = alias
        self.controlPath = supportDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("\(alias.rawValue).sock", isDirectory: false)
            .path
    }

    var controlDirectory: String {
        (controlPath as NSString).deletingLastPathComponent
    }

    /// `ControlPath` binds a Unix socket, so its directory must exist and the
    /// path must fit `sockaddr_un`.
    func prepareControlDirectory(fileManager: FileManager = .default) throws {
        guard controlPath.utf8.count <= GrokLeaderSocket.maximumPathLength else {
            throw RemoteHostError.controlPathTooLong(
                path: controlPath,
                limit: GrokLeaderSocket.maximumPathLength
            )
        }
        do {
            try fileManager.createDirectory(
                atPath: controlDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RemoteHostError.controlPathUnavailable(
                path: controlDirectory,
                detail: error.localizedDescription
            )
        }
    }

    /// Options shared by every channel. `ServerAlive*` is what turns a dead
    /// network into a prompt non-zero exit instead of a pane that hangs
    /// forever.
    private var connectionOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
    }

    /// - Parameters:
    ///   - remoteCommand: an already-composed remote shell command.
    ///   - allocateTTY: true for interactive panes, false for stdio and
    ///     capture commands.
    ///   - batch: refuses interactive credential prompts. Used for background
    ///     work so a passphrase prompt cannot hang an invisible channel.
    func arguments(
        remoteCommand: String,
        allocateTTY: Bool,
        batch: Bool
    ) -> [String] {
        var values = connectionOptions
        if allocateTTY {
            values.append("-tt")
        } else {
            values.append("-T")
        }
        if batch {
            values += ["-o", "BatchMode=yes"]
        }
        values.append(alias.rawValue)
        values.append(remoteCommand)
        return values
    }

    /// A single shell command string, for surfaces that take a command rather
    /// than an argument vector.
    func shellCommand(
        remoteCommand: String,
        allocateTTY: Bool,
        batch: Bool
    ) -> String {
        ShellQuoting.command(
            [Self.executablePath]
                + arguments(
                    remoteCommand: remoteCommand,
                    allocateTTY: allocateTTY,
                    batch: batch
                )
        )
    }

    /// Composes the remote side: enter the directory, then replace the login
    /// shell so no extra process sits between SSH and the real command.
    static func remoteCommand(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String] = [:]
    ) -> String {
        var parts: [String] = []
        if let workingDirectory {
            parts.append("cd \(ShellQuoting.quote(workingDirectory))")
        }
        var exec = "exec"
        if !environment.isEmpty {
            exec += " env"
            for key in environment.keys.sorted() {
                exec += " \(ShellQuoting.quote("\(key)=\(environment[key] ?? "")"))"
            }
        }
        exec += " " + ShellQuoting.command([executable] + arguments)
        parts.append(exec)
        return parts.joined(separator: " && ")
    }

    /// The remote user's own login shell, so a remote shell tab behaves like a
    /// local one. `$SHELL` is expanded by the remote shell, never here.
    static func remoteLoginShellCommand(workingDirectory: String) -> String {
        "cd \(ShellQuoting.quote(workingDirectory)) && "
            + #"exec "${SHELL:-/bin/zsh}" -il"#
    }

    /// Runs an already-written command line, such as the IDE tab's `fresh .`
    /// and `lazygit`, in the remote user's login shell.
    static func remoteShellCommand(
        command: String,
        workingDirectory: String
    ) -> String {
        "cd \(ShellQuoting.quote(workingDirectory)) && "
            + "exec \"${SHELL:-/bin/zsh}\" -ilc \(ShellQuoting.quote(command))"
    }
}

/// Everything a surface needs to run its command on a remote host.
struct RemoteExecution: Equatable, Sendable {
    let alias: RemoteHostAlias
    let controlPath: String

    init(alias: RemoteHostAlias, controlPath: String) {
        self.alias = alias
        self.controlPath = controlPath
    }

    init(ssh: SSHCommand) {
        self.alias = ssh.alias
        self.controlPath = ssh.controlPath
    }

    var ssh: SSHCommand {
        SSHCommand(alias: alias, controlPath: controlPath)
    }
}

enum RemoteHostError: LocalizedError, Equatable, Sendable {
    case controlPathTooLong(path: String, limit: Int)
    case controlPathUnavailable(path: String, detail: String)
    case unreachable(alias: String, detail: String)
    case grokNotFound(alias: String, path: String)
    case versionMismatch(alias: String, remote: String, local: String)
    case leaderUnavailable(alias: String, detail: String)
    case commandFailed(alias: String, command: String, status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case let .controlPathTooLong(path, limit):
            "Conan Code's SSH control path \(path) is longer than \(limit) bytes."
        case let .controlPathUnavailable(path, detail):
            "Conan Code could not create its SSH control directory at \(path): \(detail)"
        case let .unreachable(alias, detail):
            "Conan Code could not reach \(alias) over SSH: \(detail)"
        case let .grokNotFound(alias, path):
            "Conan Code found no Grok executable at \(path) on \(alias)."
        case let .versionMismatch(alias, remote, local):
            "\(alias) runs Grok \(remote) but this computer runs \(local). "
                + "Conan Code requires the same Grok build on both computers."
        case let .leaderUnavailable(alias, detail):
            "Conan Code could not start its Grok runtime on \(alias): \(detail)"
        case let .commandFailed(alias, command, status, detail):
            "`\(command)` failed on \(alias) with status \(status): \(detail)"
        }
    }
}
