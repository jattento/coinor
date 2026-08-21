import Foundation

/// One decoded screenshot poll result.
struct EgoBrowserFrame: Equatable, Sendable {
    /// Raw JPEG bytes. Decoding into `NSImage` is left to the caller so this
    /// type stays usable off the main actor.
    let jpegData: Data
    let url: String?
    let title: String?
}

enum EgoBrowserPollError: Equatable, Sendable, LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case timedOut
    case nonZeroExit(code: Int32, message: String)
    case malformedOutput
    case missingFrame

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The ego-browser CLI was not found. Install ego lite (https://lite.ego.app) to see a live browser preview."
        case .launchFailed(let message):
            "Could not launch ego-browser: \(message)"
        case .timedOut:
            "ego-browser did not respond in time."
        case .nonZeroExit(let code, let message):
            "ego-browser exited with code \(code)"
                + (message.isEmpty ? "." : ": \(message)")
        case .malformedOutput:
            "ego-browser did not return a recognizable screenshot response."
        case .missingFrame:
            "ego-browser did not return a screenshot."
        }
    }
}

/// Drives one `ego-browser nodejs` invocation to capture a single screenshot
/// of a named ego lite Task Space via the Chrome DevTools Protocol.
///
/// Each call is a fresh, independent subprocess — `ego-browser` carries no
/// state of its own between invocations, so every poll re-attaches to the
/// Task Space by name via `useOrCreateTaskSpace`, exactly like driving it by
/// hand. The invocation shape mirrors the one measured live during the
/// Phase 0 spike (warm poll ~100-160ms end to end).
struct EgoBrowserScreenshotClient: Sendable {
    let executablePath: String
    let timeout: Duration
    let jpegQuality: Int

    init(
        executablePath: String,
        timeout: Duration = .seconds(10),
        jpegQuality: Int = 55
    ) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.jpegQuality = jpegQuality
    }

    func captureScreenshot(
        taskSpaceName: String
    ) async -> Result<EgoBrowserFrame, EgoBrowserPollError> {
        let script = Self.script(
            taskSpaceName: taskSpaceName,
            quality: jpegQuality
        )
        switch await Self.run(
            executablePath: executablePath,
            stdin: script,
            timeout: timeout
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let outcome):
            guard outcome.status == 0 else {
                let message = String(
                    decoding: outcome.stderr,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(
                    .nonZeroExit(code: outcome.status, message: message)
                )
            }
            // ego-browser's own output stream selection is not a stable
            // contract Coinor controls, and was observed (diagnosed live)
            // to land on stderr rather than stdout depending on how the
            // process was launched, even on a clean exit. Scan both.
            var combined = outcome.stdout
            combined.append(contentsOf: [0x0A])
            combined.append(outcome.stderr)
            return Self.parse(stdout: combined)
        }
    }

    /// The Node.js snippet piped to `ego-browser nodejs` on stdin, mirroring
    /// the heredoc validated during the Phase 0 spike but fed directly via a
    /// pipe rather than shell heredoc syntax, so the task-space name never
    /// needs shell-level escaping.
    static func script(taskSpaceName: String, quality: Int) -> String {
        let literal = jsStringLiteral(taskSpaceName)
        return """
            const task = await useOrCreateTaskSpace(\(literal))
            const shot = await cdp('Page.captureScreenshot', { format: 'jpeg', quality: \(quality) })
            const info = await pageInfo()
            cliLog(JSON.stringify({ ok: true, jpeg: shot?.data ?? null, url: info?.url ?? null, title: info?.title ?? null }))
            """
    }

    /// Scans stdout bottom-up for the first line that decodes as the JSON
    /// object this script logs. Bottom-up because `ego-browser` can append
    /// an out-of-band "update available" trailer line after the script's own
    /// output; scanning defensively for the `ok` marker also tolerates it
    /// appearing before that output instead.
    static func parse(stdout: Data) -> Result<EgoBrowserFrame, EgoBrowserPollError> {
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let value = try? GrokJSONValue.decode(lineData),
                  value["ok"]?.boolValue == true else {
                continue
            }
            guard let base64 = value["jpeg"]?.stringValue,
                  let data = Data(base64Encoded: base64) else {
                return .failure(.missingFrame)
            }
            return .success(
                EgoBrowserFrame(
                    jpegData: data,
                    url: value["url"]?.stringValue,
                    title: value["title"]?.stringValue
                )
            )
        }
        return .failure(.malformedOutput)
    }

    private static func jsStringLiteral(_ value: String) -> String {
        (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func run(
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
            // A real screenshot easily exceeds the pipe's kernel buffer
            // (64KB), so output is drained continuously as it arrives
            // rather than read once at termination — reading only after
            // `waitUntilExit`/termination would deadlock: the child blocks
            // on a full pipe with nothing on this end draining it yet.
            let stdoutBuffer = OutputBuffer()
            let stderrBuffer = OutputBuffer()
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

private extension Duration {
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
private final class OutputBuffer: @unchecked Sendable {
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
