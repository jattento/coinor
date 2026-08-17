import Foundation

/// One thing that happened on the control-plane byte stream.
enum GrokTransportEvent: Sendable {
    /// Bytes Grok wrote to standard output. Arbitrarily chunked.
    case output(Data)
    /// Bytes Grok wrote to standard error. Kept for diagnostics only.
    case diagnostic(Data)
    /// The stream is over. No further events follow.
    case ended(status: Int32)
}

/// The byte pipe under `GrokControlClient`.
///
/// The client owns framing, request routing, and lifecycle; the transport only
/// moves bytes. Tests substitute an in-memory transport and drive the exact
/// chunk boundaries a pipe would produce.
protocol GrokTransport: Sendable {
    /// Starts the underlying stream. Call once.
    func start() throws -> AsyncStream<GrokTransportEvent>
    func send(_ payload: Data) throws
    func terminate()
    /// Closes the stream and waits until the underlying process has actually
    /// exited. The default implementation is fire-and-forget `terminate()`.
    func shutdown() async
}

extension GrokTransport {
    func shutdown() async {
        terminate()
    }
}

/// Runs Grok as a child process and speaks to it over its standard streams.
final class GrokSubprocessTransport: GrokTransport, @unchecked Sendable {
    private let launch: GrokControlLaunch
    private let terminationGrace: DispatchTimeInterval
    private let process = Process()
    private let inbound = Pipe()
    private let outbound = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "dev.coinor.grok.transport")
    private let state = TransportState()

    init(launch: GrokControlLaunch, terminationGrace: DispatchTimeInterval = .seconds(2)) {
        self.launch = launch
        self.terminationGrace = terminationGrace
    }

    func start() throws -> AsyncStream<GrokTransportEvent> {
        try launch.prepare()
        Self.ignoreBrokenPipeSignal()

        process.executableURL = launch.processExecutableURL
        process.arguments = launch.processArguments
        if launch.remote == nil {
            process.currentDirectoryURL = launch.workingDirectory
        }
        process.environment = launch.processEnvironment
        process.standardInput = inbound
        process.standardOutput = outbound
        process.standardError = errors

        let (stream, continuation) = AsyncStream<GrokTransportEvent>.makeStream()
        state.adopt(continuation)

        outbound.fileHandleForReading.readabilityHandler = { [state] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.markOutputClosed()
            } else {
                state.yield(.output(data))
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [state] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                state.yield(.diagnostic(data))
            }
        }
        process.terminationHandler = { [state] process in
            state.markExited(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            state.finish(status: -1)
            throw GrokControlError.launchFailed(
                "\(launch.processExecutableURL.path): "
                    + error.localizedDescription
            )
        }
        SubprocessOutputCapture.isolateProcessGroup(process)
        return stream
    }

    func send(_ payload: Data) throws {
        guard process.isRunning else {
            throw GrokControlError.notConnected
        }
        do {
            try inbound.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            throw GrokControlError.launchFailed(
                "could not write to Grok: \(error.localizedDescription)"
            )
        }
    }

    /// Closes stdin first: Grok's stdio agent treats EOF as a clean shutdown,
    /// which lets it finish in-flight work instead of dying mid-write. Signals
    /// only escalate if it is still alive after the grace period.
    func terminate() {
        try? inbound.fileHandleForWriting.close()
        queue.asyncAfter(deadline: .now() + terminationGrace) { [process] in
            guard process.isRunning else { return }
            SubprocessOutputCapture.signalProcessGroup(process, SIGTERM)
        }
        queue.asyncAfter(deadline: .now() + terminationGrace + terminationGrace) { [process] in
            guard process.isRunning else { return }
            SubprocessOutputCapture.signalProcessGroup(process, SIGKILL)
        }
    }

    /// Same escalation as `terminate()`, but this method does not return until
    /// the child (and its process group) has actually exited or the bounded
    /// wait elapses.
    func shutdown() async {
        try? inbound.fileHandleForWriting.close()
        SubprocessOutputCapture.isolateProcessGroup(process)

        let grace = Self.duration(from: terminationGrace)
        let started = ContinuousClock.now
        let termAt = started + grace
        let killAt = started + grace + grace
        let hardCap = started + grace + grace + .seconds(2)

        if !Task.isCancelled {
            await waitWhileRunning(until: termAt)
        }
        if process.isRunning {
            SubprocessOutputCapture.signalProcessGroup(process, SIGTERM)
        }
        if !Task.isCancelled {
            await waitWhileRunning(until: killAt)
        }
        if process.isRunning {
            SubprocessOutputCapture.signalProcessGroup(process, SIGKILL)
        }
        await waitWhileRunning(until: hardCap)
        if process.isRunning {
            SubprocessOutputCapture.signalProcessGroup(process, SIGKILL)
        }
    }

    private func waitWhileRunning(until deadline: ContinuousClock.Instant) async {
        while process.isRunning, ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    private static func duration(
        from interval: DispatchTimeInterval
    ) -> Duration {
        switch interval {
        case let .seconds(value):
            .seconds(Int64(value))
        case let .milliseconds(value):
            .milliseconds(Int64(value))
        case let .microseconds(value):
            .microseconds(Int64(value))
        case let .nanoseconds(value):
            .nanoseconds(Int64(value))
        case .never:
            .seconds(60)
        @unknown default:
            .seconds(2)
        }
    }

    /// Writing to a pipe whose reader has exited raises `SIGPIPE`, whose
    /// default disposition kills the whole application. Ignoring it lets the
    /// write path report `EPIPE` as a thrown error instead.
    private static let brokenPipeSignalIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func ignoreBrokenPipeSignal() {
        _ = brokenPipeSignalIgnored
    }
}

/// Serializes the stream continuation against the pipe and termination
/// callbacks, which arrive on Foundation's own queues.
private final class TransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<GrokTransportEvent>.Continuation?
    private var outputClosed = false
    private var exitStatus: Int32?

    func adopt(_ continuation: AsyncStream<GrokTransportEvent>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func yield(_ event: GrokTransportEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func markOutputClosed() {
        lock.lock()
        outputClosed = true
        let status = exitStatus
        lock.unlock()
        if let status {
            finish(status: status)
        }
    }

    func markExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let drained = outputClosed
        lock.unlock()
        if drained {
            finish(status: status)
        }
    }

    /// Emitted only once both the process has exited and its output has
    /// drained, so a response written just before exit is never dropped.
    func finish(status: Int32) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.yield(.ended(status: status))
        continuation.finish()
    }
}
