import Darwin
import Foundation

/// One bounded capture of a child process's standard streams.
///
/// Coinor used to give each runner its own temporary files and an unbounded
/// `Data(contentsOf:)` read. A noisy command could fill the disk inside a
/// timeout window, and a full pipe could deadlock the child. This type drains
/// stdout and stderr into a 1 MiB head/tail budget per stream, isolates the
/// child in its own process group, and always removes its workspace.
struct SubprocessCaptureResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
}

enum SubprocessCaptureError: Error, Equatable, Sendable, LocalizedError {
    case workspaceCreationFailed
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .workspaceCreationFailed:
            "could not create temporary output files"
        case let .launchFailed(detail):
            detail
        case .timedOut:
            "the command did not finish before its deadline"
        }
    }
}

/// Temporary workspace, pipe drains, UTF-8 decoding, and deadline-aware
/// process-group termination for Coinor-owned subprocesses.
final class SubprocessOutputCapture: @unchecked Sendable {
    /// 512 KiB of the start plus 512 KiB of the end of each stream.
    static let byteBudget = 1_048_576
    static let headByteBudget = 524_288
    static let tailByteBudget = 524_288
    /// How long to wait after SIGTERM before SIGKILL, and again after SIGKILL.
    static let terminationEscalationGrace = Duration.milliseconds(50)

    let directory: URL

    private let lock = NSLock()
    private var removed = false

    init(label: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coinor-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SubprocessCaptureError.workspaceCreationFailed
        }
        self.directory = directory
    }

    deinit {
        removeWorkspace()
    }

    func removeWorkspace() {
        lock.lock()
        let alreadyRemoved = removed
        removed = true
        lock.unlock()
        guard !alreadyRemoved else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs a fully configured `Process` and captures both streams.
    ///
    /// The caller sets the executable, arguments, environment, working
    /// directory, and stdin. This method owns stdout, stderr, the deadline,
    /// and cleanup.
    func run(
        process: Process,
        deadline: Duration
    ) throws -> SubprocessCaptureResult {
        defer { removeWorkspace() }
        let session = CaptureSession()
        defer { session.finish() }

        try Self.launch(process, session: session)
        do {
            try wait(
                for: process,
                deadline: deadline,
                exit: session.exit
            )
        } catch {
            session.finish(waitForDrains: false)
            throw error
        }
        session.finish()
        return session.result(for: process)
    }

    func run(
        process: Process,
        deadline: Duration
    ) async throws -> SubprocessCaptureResult {
        defer { removeWorkspace() }
        let session = CaptureSession()
        defer { session.finish() }

        try Self.launch(process, session: session)
        do {
            try await wait(for: process, deadline: deadline)
        } catch {
            session.finish(waitForDrains: false)
            throw error
        }
        session.finish()
        return session.result(for: process)
    }

    static func truncationMarker(omittedByteCount: Int) -> String {
        "… output truncated (\(omittedByteCount) bytes omitted) …"
    }

    static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }

    /// Puts the child in its own process group so a later signal can reach
    /// every descendant without touching Conan Code's group.
    ///
    /// `Process.qualityOfService` is unrelated. After `run()`, `setpgid(pid, 0)`
    /// makes the child a group leader when it is not one already. If that
    /// fails, signals fall back to the direct child so we never `kill(-pid)` a
    /// group we still share with the application.
    static func isolateProcessGroup(_ process: Process) {
        isolateProcessGroup(pid: process.processIdentifier)
    }

    static func isolateProcessGroup(pid: pid_t) {
        guard pid > 1 else { return }
        if getpgid(pid) == pid { return }
        _ = setpgid(pid, 0)
    }

    static func signalProcessGroup(_ process: Process, _ signal: Int32) {
        signalProcessGroup(pid: process.processIdentifier, signal)
    }

    static func signalProcessGroup(pid: pid_t, _ signal: Int32) {
        guard pid > 1 else { return }
        if getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    static func escalateTermination(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        // Tell Foundation first so `Process` deinit does not wait out the
        // child's remaining lifetime after we have already given up.
        process.terminate()
        signalProcessGroup(pid: pid, SIGTERM)
        signalProcessGroup(pid: pid, SIGKILL)
        let deadline = ContinuousClock.now + terminationEscalationGrace
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            signalProcessGroup(pid: pid, SIGKILL)
        }
    }

    static func escalateTermination(pid: pid_t) {
        guard pid > 1 else { return }
        signalProcessGroup(pid: pid, SIGTERM)
        signalProcessGroup(pid: pid, SIGKILL)
    }

    private static func launch(
        _ process: Process,
        session: CaptureSession
    ) throws {
        process.standardOutput = session.outputPipe
        process.standardError = session.errorPipe
        process.terminationHandler = { _ in
            session.exit.signal()
        }
        session.startDrains()

        do {
            try process.run()
        } catch {
            throw SubprocessCaptureError.launchFailed(error.localizedDescription)
        }
        // Do not close the pipe write ends here: `Process` still holds them
        // and the child writes through the same handle. Closing now drops
        // output and can SIGPIPE the child. They close when the child exits
        // (or when we kill it and `finish()` drops the session).
        isolateProcessGroup(process)
    }

    private func wait(
        for process: Process,
        deadline: Duration,
        exit: DispatchSemaphore
    ) throws {
        let deadlineInstant = ContinuousClock.now + deadline
        while true {
            if Task.isCancelled {
                Self.escalateTermination(process)
                throw CancellationError()
            }
            if ContinuousClock.now >= deadlineInstant {
                Self.escalateTermination(process)
                throw SubprocessCaptureError.timedOut
            }
            let remaining = Self.seconds(in: deadlineInstant - ContinuousClock.now)
            let slice = min(max(remaining, 0), 0.02)
            if exit.wait(timeout: .now() + slice) == .success {
                try Task.checkCancellation()
                return
            }
        }
    }

    private func wait(
        for process: Process,
        deadline: Duration
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                let deadlineInstant = ContinuousClock.now + deadline
                while process.isRunning {
                    try Task.checkCancellation()
                    if ContinuousClock.now >= deadlineInstant {
                        Self.escalateTermination(process)
                        throw SubprocessCaptureError.timedOut
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                try Task.checkCancellation()
            } onCancel: {
                Self.escalateTermination(process)
            }
        } catch is CancellationError {
            Self.escalateTermination(process)
            throw CancellationError()
        }
    }

    private static func waitWhileRunning(_ process: Process, grace: Duration) {
        let deadline = ContinuousClock.now + grace
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(10_000)
        }
    }

    private static func waitWhileAlive(pid: pid_t, grace: Duration) {
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline, isAlive(pid) {
            usleep(10_000)
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

/// Drains one pair of pipes into independent head/tail buffers.
private final class CaptureSession: @unchecked Sendable {
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let stdout = BoundedByteBuffer()
    let stderr = BoundedByteBuffer()
    let exit = DispatchSemaphore(value: 0)
    private let stdoutDone = DispatchSemaphore(value: 0)
    private let stderrDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false

    func startDrains() {
        attach(outputPipe.fileHandleForReading, buffer: stdout, done: stdoutDone)
        attach(errorPipe.fileHandleForReading, buffer: stderr, done: stderrDone)
    }

    private func attach(
        _ handle: FileHandle,
        buffer: BoundedByteBuffer,
        done: DispatchSemaphore
    ) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
            } else {
                buffer.append(data)
            }
        }
    }

    func finish(waitForDrains: Bool = true) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        // The child is gone (or we have given up waiting). Closing the write
        // ends forces EOF on the drains if Process is still holding them.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        if waitForDrains {
            _ = stdoutDone.wait(timeout: .now() + .milliseconds(200))
            _ = stderrDone.wait(timeout: .now() + .milliseconds(200))
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
    }

    func result(for process: Process) -> SubprocessCaptureResult {
        SubprocessCaptureResult(
            standardOutput: stdout.decodeUTF8(),
            standardError: stderr.decodeUTF8(),
            terminationStatus: process.terminationStatus
        )
    }
}

/// Keeps the first and last bytes of a stream and records how much was dropped.
private final class BoundedByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var total = 0
    private let headLimit = SubprocessOutputCapture.headByteBudget
    private let tailLimit = SubprocessOutputCapture.tailByteBudget

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        total += data.count

        var incoming = data
        if head.count < headLimit {
            let need = headLimit - head.count
            if incoming.count <= need {
                head.append(incoming)
                return
            }
            head.append(incoming.prefix(need))
            incoming = Data(incoming.dropFirst(need))
        }

        if incoming.count >= tailLimit {
            tail = Data(incoming.suffix(tailLimit))
            return
        }
        tail.append(incoming)
        if tail.count > tailLimit {
            tail = Data(tail.suffix(tailLimit))
        }
    }

    func decodeUTF8() -> String {
        lock.lock()
        defer { lock.unlock() }
        let omitted = total - head.count - tail.count
        if omitted <= 0 {
            if tail.isEmpty {
                return String(decoding: head, as: UTF8.self)
            }
            return String(decoding: head + tail, as: UTF8.self)
        }
        return String(decoding: head, as: UTF8.self)
            + SubprocessOutputCapture.truncationMarker(omittedByteCount: omitted)
            + String(decoding: tail, as: UTF8.self)
    }
}
