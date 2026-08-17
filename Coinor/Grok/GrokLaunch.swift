import Foundation

/// A Grok executable Coinor has verified it can run.
///
/// Coinor is launched from Finder, where `PATH` is the minimal system default,
/// so a relative or `PATH`-resolved command is never trustworthy. The path is
/// validated once, up front, and the resolved absolute URL is what every
/// Coinor-owned process is started from.
struct GrokExecutable: Sendable, Equatable {
    static let defaultConfiguredPath = "~/bin/grok"

    let url: URL

    var path: String { url.path }

    /// Expands a leading `~` and then requires an absolute path to an existing
    /// executable file. A symlink is accepted as configured: `~/bin/grok`
    /// points at the local fork's launcher on purpose.
    static func resolve(
        configuredPath: String = defaultConfiguredPath,
        fileManager: FileManager = .default
    ) throws -> GrokExecutable {
        let expanded = (configuredPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw GrokControlError.executablePathNotAbsolute(configuredPath)
        }

        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw GrokControlError.executableNotFound(standardized.path)
        }
        guard fileManager.isExecutableFile(atPath: standardized.path) else {
            throw GrokControlError.executableNotExecutable(standardized.path)
        }
        return GrokExecutable(url: standardized)
    }
}

/// The Unix socket for Coinor's own Grok leader.
///
/// Every Coinor-owned Grok process is pointed at this socket with
/// `--leader-socket`, which is what keeps the root pane, the subagent panes,
/// and this control client attached to the same in-memory sessions without
/// touching the machine-wide `use_leader` setting.
struct GrokLeaderSocket: Sendable, Equatable {
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the
    /// terminator. A longer path fails at bind time with an obscure error.
    static let maximumPathLength = 103

    let path: String

    init(path: String) throws {
        guard path.hasPrefix("/") else {
            throw GrokControlError.leaderSocketPathNotAbsolute(path)
        }
        guard path.utf8.count <= Self.maximumPathLength else {
            throw GrokControlError.leaderSocketPathTooLong(
                path: path,
                limit: Self.maximumPathLength
            )
        }
        self.path = path
    }

    static func coinorDefault(fileManager: FileManager = .default) throws -> GrokLeaderSocket {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let socket = support
            .appendingPathComponent("Coinor", isDirectory: true)
        return try coinorDefault(supportDirectory: socket)
    }

    static func coinorDefault(
        supportDirectory: URL
    ) throws -> GrokLeaderSocket {
        let socket = supportDirectory
            .appendingPathComponent("grok-leader.sock", isDirectory: false)
        return try GrokLeaderSocket(path: socket.path)
    }

    /// Grok binds the socket itself but will not create its parent directory.
    func prepareDirectory(fileManager: FileManager = .default) throws {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw GrokControlError.launchFailed(
                "could not create \(directory): \(error.localizedDescription)"
            )
        }
    }
}

/// Everything needed to start the control-plane Grok process.
struct GrokControlLaunch: Sendable, Equatable {
    let executable: GrokExecutable
    let leaderSocket: GrokLeaderSocket
    let workingDirectory: URL
    let environment: [String: String]
    /// Absent for the local control plane. When present, `executable`,
    /// `leaderSocket`, and `workingDirectory` describe the remote computer and
    /// the process started here is `ssh`.
    let remote: RemoteControlPlane?

    init(
        executable: GrokExecutable,
        leaderSocket: GrokLeaderSocket,
        workingDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        remote: RemoteControlPlane? = nil
    ) {
        self.executable = executable
        self.leaderSocket = leaderSocket
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.remote = remote
    }

    /// The process actually started on this computer.
    var processExecutableURL: URL {
        remote == nil
            ? executable.url
            : URL(fileURLWithPath: SSHCommand.executablePath, isDirectory: false)
    }

    var processArguments: [String] {
        guard let remote else { return arguments }
        return remote.ssh.arguments(
            remoteCommand: SSHCommand.remoteCommand(
                executable: executable.path,
                arguments: arguments,
                workingDirectory: nil
            ),
            allocateTTY: false,
            batch: true
        )
    }

    /// The remote control plane inherits nothing from this computer: no
    /// terminal-control socket, no instance token, no local paths.
    var processEnvironment: [String: String] {
        remote == nil ? environment : ProcessInfo.processInfo.environment
    }

    /// Local preflight only. A remote path is owned by the remote machine and
    /// is never checked against this file system.
    func prepare(fileManager: FileManager = .default) throws {
        if let remote {
            try remote.ssh.prepareControlDirectory(fileManager: fileManager)
            return
        }
        try validate(fileManager: fileManager)
        try leaderSocket.prepareDirectory(fileManager: fileManager)
    }

    /// `grok --leader-socket <coinor-socket> agent --leader stdio`.
    ///
    /// The socket is passed as a flag rather than through `GROK_LEADER_SOCKET`
    /// so nothing outside this process tree inherits Coinor's leader.
    var arguments: [String] {
        ["--leader-socket", leaderSocket.path, "agent", "--leader", "stdio"]
    }

    func validate(fileManager: FileManager = .default) throws {
        guard remote == nil else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw GrokControlError.workingDirectoryNotFound(workingDirectory.path)
        }
    }
}

/// Runs the already-resolved Grok executable directly to capture its version.
///
/// Capture, bounding, and process-group termination are owned by
/// `SubprocessOutputCapture` so a noisy `--version` cannot fill a pipe or the
/// disk, and a hang is killed instead of racing a detached waiter.
struct GrokExecutableVersionProbe: Sendable {
    func run(
        launch: GrokControlLaunch,
        timeout: Duration
    ) async throws -> String {
        try launch.validate()

        let capture: SubprocessOutputCapture
        do {
            capture = try SubprocessOutputCapture(label: "grok-version")
        } catch {
            throw GrokControlError.launchFailed(
                "could not create temporary files for `grok --version`"
            )
        }

        let process = Process()
        process.executableURL = launch.executable.url
        process.arguments = ["--version"]
        process.currentDirectoryURL = launch.workingDirectory
        process.environment = launch.environment

        let captured: SubprocessCaptureResult
        do {
            captured = try await capture.run(process: process, deadline: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch SubprocessCaptureError.timedOut {
            throw GrokControlError.executableVersionTimedOut(
                path: launch.executable.path,
                seconds: Self.seconds(in: timeout)
            )
        } catch {
            throw GrokControlError.launchFailed(
                "could not run \(launch.executable.path) --version: "
                    + error.localizedDescription
            )
        }

        return try Self.result(
            path: launch.executable.path,
            status: captured.terminationStatus,
            output: captured.standardOutput,
            diagnostic: captured.standardError
        )
    }

    private static func result(
        path: String,
        status: Int32,
        output: String,
        diagnostic: String
    ) throws -> String {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0 else {
            let detail = [diagnostic, output]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            throw GrokControlError.executableVersionFailed(
                path: path,
                status: status,
                diagnostics: detail
            )
        }

        let version = output.isEmpty ? diagnostic : output
        guard !version.isEmpty else {
            throw GrokControlError.executableVersionEmpty(path)
        }
        return version
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(value, 0.001)
    }
}

/// The SSH channel Conan Code's remote control plane runs through.
struct RemoteControlPlane: Sendable, Equatable {
    let alias: RemoteHostAlias
    let controlPath: String

    init(ssh: SSHCommand) {
        self.alias = ssh.alias
        self.controlPath = ssh.controlPath
    }

    var ssh: SSHCommand {
        SSHCommand(alias: alias, controlPath: controlPath)
    }
}
