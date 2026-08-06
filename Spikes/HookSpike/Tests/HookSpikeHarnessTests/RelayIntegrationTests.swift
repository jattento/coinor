import Foundation
import Testing

@testable import HookSpikeHarnessCore

@Suite(.serialized)
struct RelayIntegrationTests {
    @Test
    func actualRelayDeliversCompletePayloadToListener() throws {
        let socketPath = temporarySocketPath()
        let listener = try UnixHookListener(socketPath: socketPath)
        let payload = try Fixture.data("subagent-start")

        let result = try runRelay(payload: payload, socketPath: socketPath)
        let received = try listener.receive(timeoutMilliseconds: 1_000)

        #expect(result.status == 0)
        #expect(result.elapsed < .milliseconds(500))
        #expect(received == payload)
    }

    @Test
    func actualRelayAndListenerDriveAllRegisteredLifecycleEvents() throws {
        let socketPath = temporarySocketPath()
        let listener = try UnixHookListener(socketPath: socketPath)
        var state = HookLifecycleState(
            activatedRootSessionIDs: [Fixture.root]
        )

        for fixture in [
            "session-start",
            "subagent-start",
            "subagent-stop",
            "session-end",
        ] {
            let payload = try Fixture.data(fixture)
            let result = try runRelay(payload: payload, socketPath: socketPath)
            #expect(result.status == 0)
            let delivered = try listener.receive(timeoutMilliseconds: 1_000)
            let received = try #require(delivered)
            try state.apply(jsonData: received)
        }

        #expect(
            state.observedEventNames == [
                .sessionStart,
                .subagentStart,
                .subagentStop,
                .sessionEnd,
            ]
        )
        #expect(state.orderedPanes.isEmpty)
    }

    @Test
    func actualRelaySucceedsQuicklyWithNoListener() throws {
        let socketPath = temporarySocketPath()
        let result = try runRelay(
            payload: Fixture.data("session-start"),
            socketPath: socketPath
        )

        #expect(result.status == 0)
        #expect(result.elapsed < .milliseconds(500))
        #expect(FileManager.default.fileExists(atPath: socketPath) == false)
    }

    @Test
    func actualRelayIsInertWithoutSocketConfiguration() throws {
        let result = try runRelay(
            payload: Fixture.data("session-start"),
            socketPath: nil
        )

        #expect(result.status == 0)
        #expect(result.elapsed < .milliseconds(500))
    }

    @Test
    func invalidJSONIsNotDelivered() throws {
        let socketPath = temporarySocketPath()
        let listener = try UnixHookListener(socketPath: socketPath)
        let result = try runRelay(
            payload: Data("not-json".utf8),
            socketPath: socketPath
        )

        #expect(result.status == 0)
        #expect(try listener.receive(timeoutMilliseconds: 100) == nil)
    }
}

private struct RelayResult {
    let status: Int32
    let elapsed: Duration
}

private func runRelay(
    payload: Data,
    socketPath: String?
) throws -> RelayResult {
    let executable = try relayExecutable()
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    var environment = ProcessInfo.processInfo.environment

    if let socketPath {
        environment["COINOR_HOOK_SOCKET"] = socketPath
        environment["COINOR_HOOK_TIMEOUT_MS"] = "100"
    } else {
        environment.removeValue(forKey: "COINOR_HOOK_SOCKET")
    }

    process.executableURL = executable
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    let clock = ContinuousClock()
    let started = clock.now
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: payload)
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    return RelayResult(
        status: process.terminationStatus,
        elapsed: clock.now - started
    )
}

private func relayExecutable() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment[
        "COINOR_HOOK_RELAY_EXECUTABLE"
    ] {
        return URL(fileURLWithPath: configured)
    }

    throw TestError(
        "Set COINOR_HOOK_RELAY_EXECUTABLE to the built coinor-hook-relay binary"
    )
}

private func temporarySocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("coinor-\(UUID().uuidString.prefix(8)).sock")
        .path
}

private struct TestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
