import Darwin
import Foundation

enum GrokLeaderTerminationError: LocalizedError, Equatable, Sendable {
    case lockOpen(path: String, code: Int32)
    case lockInspection(path: String, code: Int32)
    case invalidPID(path: String)
    case unexpectedProcess(pid: Int32)
    case signal(pid: Int32, code: Int32)
    case didNotExit(pid: Int32)

    var errorDescription: String? {
        switch self {
        case let .lockOpen(path, code):
            "Conan Code could not open its Grok leader lock at \(path) (\(code))."
        case let .lockInspection(path, code):
            "Conan Code could not inspect its Grok leader lock at \(path) (\(code))."
        case let .invalidPID(path):
            "Conan Code's Grok leader lock at \(path) does not contain a valid process ID."
        case let .unexpectedProcess(pid):
            "Conan Code refused to terminate PID \(pid) because it is not a Grok process."
        case let .signal(pid, code):
            "Conan Code could not terminate its Grok leader at PID \(pid) (\(code))."
        case let .didNotExit(pid):
            "Conan Code's Grok leader at PID \(pid) did not exit."
        }
    }
}

/// Stops only the leader that holds Coinor's private socket lock.
///
/// The lock must be contended and name a live Grok process before any signal
/// is sent. This prevents a stale lock file from targeting a recycled PID.
struct GrokLeaderProcessManager: Sendable {
    private let gracefulWaitIterations: Int
    private let forcedWaitIterations: Int
    private let waitMicroseconds: useconds_t

    init(
        gracefulWaitIterations: Int = 20,
        forcedWaitIterations: Int = 20,
        waitMicroseconds: useconds_t = 100_000
    ) {
        self.gracefulWaitIterations = gracefulWaitIterations
        self.forcedWaitIterations = forcedWaitIterations
        self.waitMicroseconds = waitMicroseconds
    }

    @discardableResult
    func stop(leaderSocket: GrokLeaderSocket) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try stopSynchronously(leaderSocket: leaderSocket)
        }.value
    }

    private func stopSynchronously(
        leaderSocket: GrokLeaderSocket
    ) throws -> Bool {
        let socketURL = URL(fileURLWithPath: leaderSocket.path)
        let lockURL = socketURL
            .deletingPathExtension()
            .appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT {
                _ = Darwin.unlink(leaderSocket.path)
                return false
            }
            throw GrokLeaderTerminationError.lockOpen(
                path: lockURL.path,
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.unlink(leaderSocket.path)
            return false
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw GrokLeaderTerminationError.lockInspection(
                path: lockURL.path,
                code: errno
            )
        }

        let rawPID = (try? String(contentsOf: lockURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPID,
              let parsedPID = Int32(rawPID),
              parsedPID > 1 else {
            throw GrokLeaderTerminationError.invalidPID(path: lockURL.path)
        }
        guard Self.isAlive(parsedPID) else {
            _ = Darwin.unlink(leaderSocket.path)
            return false
        }
        guard Self.isGrokProcess(parsedPID) else {
            throw GrokLeaderTerminationError.unexpectedProcess(pid: parsedPID)
        }

        guard Darwin.kill(parsedPID, SIGTERM) == 0 || errno == ESRCH else {
            throw GrokLeaderTerminationError.signal(
                pid: parsedPID,
                code: errno
            )
        }
        if Self.waitForExit(
            parsedPID,
            iterations: gracefulWaitIterations,
            microseconds: waitMicroseconds
        ) {
            Self.removeLeaderFiles(socketURL: socketURL, lockURL: lockURL)
            return true
        }

        guard Darwin.kill(parsedPID, SIGKILL) == 0 || errno == ESRCH else {
            throw GrokLeaderTerminationError.signal(
                pid: parsedPID,
                code: errno
            )
        }
        guard Self.waitForExit(
            parsedPID,
            iterations: forcedWaitIterations,
            microseconds: waitMicroseconds
        ) else {
            throw GrokLeaderTerminationError.didNotExit(pid: parsedPID)
        }

        Self.removeLeaderFiles(socketURL: socketURL, lockURL: lockURL)
        return true
    }

    private static func waitForExit(
        _ pid: Int32,
        iterations: Int,
        microseconds: useconds_t
    ) -> Bool {
        for _ in 0 ..< iterations {
            if !isAlive(pid) {
                return true
            }
            usleep(microseconds)
        }
        return !isAlive(pid)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func isGrokProcess(_ pid: Int32) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let command = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executableName = URL(
            fileURLWithPath: command
        ).pathComponents.last else {
            return false
        }
        return executableName.localizedCaseInsensitiveContains("grok")
    }

    private static func removeLeaderFiles(
        socketURL: URL,
        lockURL: URL
    ) {
        _ = Darwin.unlink(socketURL.path)
        _ = Darwin.unlink(lockURL.path)
    }
}
