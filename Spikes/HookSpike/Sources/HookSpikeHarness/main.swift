import Darwin
import Foundation
import HookSpikeHarnessCore

struct Arguments {
    let socketPath: String
    let rootSessionIDs: Set<String>
    let eventCount: Int
    let timeoutMilliseconds: Int

    init(_ values: [String]) throws {
        var socketPath: String?
        var rootSessionIDs: Set<String> = []
        var eventCount = 1
        var timeoutMilliseconds = 2_000
        var index = 1

        while index < values.count {
            let option = values[index]
            guard index + 1 < values.count else {
                throw ArgumentError("Missing value for \(option)")
            }
            let value = values[index + 1]

            switch option {
            case "--socket":
                socketPath = value
            case "--root":
                rootSessionIDs.insert(value)
            case "--event-count":
                guard let count = Int(value), count > 0 else {
                    throw ArgumentError("--event-count must be a positive integer")
                }
                eventCount = count
            case "--timeout-ms":
                guard let timeout = Int(value), timeout > 0 else {
                    throw ArgumentError("--timeout-ms must be a positive integer")
                }
                timeoutMilliseconds = timeout
            default:
                throw ArgumentError("Unknown option: \(option)")
            }
            index += 2
        }

        guard let socketPath else {
            throw ArgumentError("--socket is required")
        }

        self.socketPath = socketPath
        self.rootSessionIDs = rootSessionIDs
        self.eventCount = eventCount
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

struct ArgumentError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

do {
    let arguments = try Arguments(CommandLine.arguments)
    let listener = try UnixHookListener(socketPath: arguments.socketPath)
    var state = HookLifecycleState(
        activatedRootSessionIDs: arguments.rootSessionIDs
    )

    for _ in 0 ..< arguments.eventCount {
        guard let payload = try listener.receive(
            timeoutMilliseconds: arguments.timeoutMilliseconds
        ) else {
            throw ArgumentError("Timed out waiting for a hook event")
        }
        try state.apply(jsonData: payload)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(state.snapshot()))
    FileHandle.standardOutput.write(Data([0x0A]))
} catch {
    FileHandle.standardError.write(Data("Hook spike failed: \(error)\n".utf8))
    Darwin.exit(2)
}
