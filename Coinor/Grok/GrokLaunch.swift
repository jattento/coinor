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

    init(
        executable: GrokExecutable,
        leaderSocket: GrokLeaderSocket,
        workingDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.leaderSocket = leaderSocket
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// `grok --leader-socket <coinor-socket> agent --leader stdio`.
    ///
    /// The socket is passed as a flag rather than through `GROK_LEADER_SOCKET`
    /// so nothing outside this process tree inherits Coinor's leader.
    var arguments: [String] {
        ["--leader-socket", leaderSocket.path, "agent", "--leader", "stdio"]
    }

    func validate(fileManager: FileManager = .default) throws {
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
/// Output goes to temporary files so an unexpectedly noisy binary cannot fill
/// a pipe and deadlock. The completion gate makes process exit and timeout
/// race safely; whichever wins resolves the probe exactly once.
struct GrokExecutableVersionProbe: Sendable {
    private static let captureLimit = 16 * 1024

    func run(
        launch: GrokControlLaunch,
        timeout: Duration
    ) async throws -> String {
        try launch.validate()

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "coinor-grok-version-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")

        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        do {
            guard fileManager.createFile(atPath: outputURL.path, contents: nil),
                  fileManager.createFile(atPath: errorURL.path, contents: nil)
            else {
                throw GrokControlError.launchFailed(
                    "could not create temporary files for `grok --version`"
                )
            }

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            let process = Process()
            process.executableURL = launch.executable.url
            process.arguments = ["--version"]
            process.currentDirectoryURL = launch.workingDirectory
            process.environment = launch.environment
            process.standardOutput = outputHandle
            process.standardError = errorHandle

            let timeoutSeconds = Self.seconds(in: timeout)
            return try await withCheckedThrowingContinuation { continuation in
                let completion = GrokVersionProbeCompletion(
                    continuation: continuation,
                    captureDirectory: captureDirectory
                )

                do {
                    try process.run()
                    try? outputHandle.close()
                    try? errorHandle.close()
                } catch {
                    try? outputHandle.close()
                    try? errorHandle.close()
                    guard let continuation = completion.claim() else { return }
                    completion.cleanup()
                    continuation.resume(
                        throwing: GrokControlError.launchFailed(
                            "could not run \(launch.executable.path) --version: "
                                + error.localizedDescription
                        )
                    )
                    return
                }

                Thread.detachNewThread {
                    process.waitUntilExit()
                    guard let continuation = completion.claim() else { return }
                    let result = Self.result(
                        path: launch.executable.path,
                        status: process.terminationStatus,
                        outputURL: outputURL,
                        errorURL: errorURL
                    )
                    completion.cleanup()
                    continuation.resume(with: result)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeoutSeconds
                ) {
                    guard let continuation = completion.claim() else { return }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    completion.cleanup()
                    continuation.resume(
                        throwing: GrokControlError.executableVersionTimedOut(
                            path: launch.executable.path,
                            seconds: timeoutSeconds
                        )
                    )
                }
            }
        } catch {
            try? fileManager.removeItem(at: captureDirectory)
            throw error
        }
    }

    private static func result(
        path: String,
        status: Int32,
        outputURL: URL,
        errorURL: URL
    ) -> Result<String, any Error> {
        let output = readTail(outputURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = readTail(errorURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0 else {
            let detail = [diagnostic, output]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return .failure(
                GrokControlError.executableVersionFailed(
                    path: path,
                    status: status,
                    diagnostics: detail
                )
            )
        }

        let version = output.isEmpty ? diagnostic : output
        guard !version.isEmpty else {
            return .failure(GrokControlError.executableVersionEmpty(path))
        }
        return .success(version)
    }

    private static func readTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ""
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else {
            return ""
        }
        let offset = size > UInt64(captureLimit)
            ? size - UInt64(captureLimit)
            : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? nil
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(value, 0.001)
    }
}

private final class GrokVersionProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private let captureDirectory: URL

    init(
        continuation: CheckedContinuation<String, any Error>,
        captureDirectory: URL
    ) {
        self.continuation = continuation
        self.captureDirectory = captureDirectory
    }

    func claim() -> CheckedContinuation<String, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: captureDirectory)
    }
}
