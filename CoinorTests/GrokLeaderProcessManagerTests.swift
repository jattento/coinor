import Darwin
import Foundation
import Testing

@testable import Coinor

@Test
func staleUnlockedLeaderFilesAreCleanedWithoutSignalingTheirPID() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(
            "cnr-l-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let socket = try GrokLeaderSocket(
        path: directory.appendingPathComponent("leader.sock").path
    )
    let lock = directory.appendingPathComponent("leader.lock")
    try Data("\(getpid())\n".utf8).write(to: lock)
    _ = FileManager.default.createFile(atPath: socket.path, contents: Data())

    let stopped = try await GrokLeaderProcessManager().stop(
        leaderSocket: socket
    )

    #expect(stopped == false)
    #expect(!FileManager.default.fileExists(atPath: socket.path))
    #expect(FileManager.default.fileExists(atPath: lock.path))
}

@Test
func contendedLockRefusesToSignalANonGrokProcess() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(
            "cnr-g-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let socket = try GrokLeaderSocket(
        path: directory.appendingPathComponent("leader.sock").path
    )
    let lock = directory.appendingPathComponent("leader.lock")
    let descriptor = Darwin.open(
        lock.path,
        O_CREAT | O_RDWR | O_TRUNC,
        S_IRUSR | S_IWUSR
    )
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let pid = "\(getpid())\n"
    _ = pid.withCString {
        Darwin.write(descriptor, $0, strlen($0))
    }

    await #expect(
        throws: GrokLeaderTerminationError.unexpectedProcess(pid: getpid())
    ) {
        _ = try await GrokLeaderProcessManager(
            gracefulWaitIterations: 1,
            forcedWaitIterations: 1,
            waitMicroseconds: 1
        ).stop(leaderSocket: socket)
    }
    #expect(Darwin.kill(getpid(), 0) == 0)
}
