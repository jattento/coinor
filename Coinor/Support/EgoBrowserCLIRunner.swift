import Foundation

/// Runs one `ego-browser nodejs <script>` invocation and returns its exit
/// status plus fully-drained stdout/stderr.
///
/// Shared by every Coinor feature that drives the `ego-browser` CLI
/// (`EgoBrowserScreenshotClient`'s poller, `EgoLiteActivator`'s "open in ego
/// lite" action) so the pipe-draining discipline only has to be gotten right
/// once: a real screenshot easily exceeds the pipe's kernel buffer (64KB),
/// so output is drained continuously as it arrives via `readabilityHandler`
/// rather than read once at termination — reading only after
/// `waitUntilExit`/termination would deadlock, since the child blocks on a
/// full pipe with nothing on this end draining it yet.
enum EgoBrowserCLIRunner {
    static func run(
        executablePath: String,
        stdin: String,
        timeout: Duration
    ) async -> Result<
        (status: Int32, stdout: Data, stderr: Data), EgoBrowserPollError
    > {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["nodejs"]
            // Never let DYLD/XCTest injection variables the host process
            // may be running under (e.g. under a test runner) leak into
            // the spawned Node.js/Chromium child — those have caused real,
            // reproducible interference with ego-browser's own output.
            process.environment = ProcessInfo.processInfo.environment
                .filter {
                    !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest")
                }
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let lock = NSLock()
            let didResumeBox = DidResumeBox()
            let stdoutBuffer = CLIOutputBuffer()
            let stderrBuffer = CLIOutputBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }
            let resumeOnce: @Sendable (
                Result<
                    (status: Int32, stdout: Data, stderr: Data),
                    EgoBrowserPollError
                >
            ) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !didResumeBox.value else { return }
                didResumeBox.value = true
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: result)
            }

            process.terminationHandler = { proc in
                // Drain whatever arrived between the last callback and exit.
                stdoutBuffer.append(
                    stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                )
                stderrBuffer.append(
                    stderrPipe.fileHandleForReading.readDataToEndOfFile()
                )
                resumeOnce(
                    .success(
                        (
                            proc.terminationStatus,
                            stdoutBuffer.data,
                            stderrBuffer.data
                        )
                    )
                )
            }

            do {
                try process.run()
            } catch {
                resumeOnce(
                    .failure(.launchFailed(error.localizedDescription))
                )
                return
            }

            if let data = stdin.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout.timeIntervalValue
            ) {
                guard process.isRunning else { return }
                process.terminate()
                resumeOnce(.failure(.timedOut))
            }
        }
    }
}

extension Duration {
    var timeIntervalValue: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// A single mutable flag shared between the process termination handler and
/// the timeout timer, both of which can fire concurrently on different
/// queues; access is always taken under the caller's lock.
private final class DidResumeBox: @unchecked Sendable {
    var value = false
}

/// Accumulates pipe output arriving from repeated `readabilityHandler`
/// callbacks, which fire on a dispatch-internal queue potentially
/// concurrently with the termination handler's own final drain.
private final class CLIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
