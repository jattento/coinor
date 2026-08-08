import Foundation

enum ManagedTerminalState: Equatable, Sendable {
    case starting
    case idle
    case running(commandID: String)
    case exited(code: UInt32)

    var wireValue: String {
        switch self {
        case .starting:
            "starting"
        case .idle:
            "idle"
        case .running:
            "running"
        case .exited:
            "exited"
        }
    }
}

struct ManagedTerminalReadResult: Equatable, Sendable {
    let text: String
    let cursor: String
    let reset: Bool
    let truncated: Bool
}

struct ManagedTerminalOutputCache: Sendable {
    static let defaultMaximumBytes = 64 * 1024
    static let hardMaximumBytes = 256 * 1024
    private static let retainedMaximumBytes = 1024 * 1024
    private static let retainedMaximumLines = 20_000

    private(set) var revision = 0
    private var current = ""
    private var snapshots: [String: String] = [:]
    private var snapshotOrder: [String] = []

    mutating func read(
        snapshot: String,
        generation: Int,
        cursor: String?,
        maximumBytes requestedMaximumBytes: Int?
    ) -> ManagedTerminalReadResult {
        let retained = Self.retainedTail(of: snapshot)
        if retained != current {
            current = retained
            revision += 1
            let key = Self.cursor(
                generation: generation,
                revision: revision
            )
            snapshots[key] = retained
            snapshotOrder.append(key)
            while snapshotOrder.count > 8 {
                snapshots.removeValue(
                    forKey: snapshotOrder.removeFirst()
                )
            }
        }

        let nextCursor = Self.cursor(
            generation: generation,
            revision: revision
        )
        let candidate: String
        let reset: Bool
        if let cursor, let previous = snapshots[cursor] {
            if current.hasPrefix(previous) {
                candidate = String(current.dropFirst(previous.count))
                reset = false
            } else {
                candidate = current
                reset = true
            }
        } else if cursor != nil {
            candidate = current
            reset = true
        } else {
            candidate = current
            reset = false
        }

        let maximumBytes = min(
            max(
                requestedMaximumBytes ?? Self.defaultMaximumBytes,
                1
            ),
            Self.hardMaximumBytes
        )
        let bounded = Self.utf8Tail(
            candidate,
            maximumBytes: maximumBytes
        )
        return ManagedTerminalReadResult(
            text: bounded.text,
            cursor: nextCursor,
            reset: reset,
            truncated: bounded.truncated
        )
    }

    private static func cursor(
        generation: Int,
        revision: Int
    ) -> String {
        "\(generation):\(revision)"
    }

    private static func retainedTail(of text: String) -> String {
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let lineBounded = lines.count > retainedMaximumLines
            ? lines.suffix(retainedMaximumLines).joined(separator: "\n")
            : text
        return utf8Tail(
            lineBounded,
            maximumBytes: retainedMaximumBytes
        ).text
    }

    private static func utf8Tail(
        _ text: String,
        maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        let data = Data(text.utf8)
        guard data.count > maximumBytes else {
            return (text, false)
        }
        var start = data.count - maximumBytes
        while start < data.count {
            let suffix = data[start...]
            if let text = String(data: suffix, encoding: .utf8) {
                return (text, true)
            }
            start += 1
        }
        return ("", true)
    }
}

@MainActor
final class ManagedTerminalTab: Identifiable {
    let id: String
    let capability: String
    let ownerSessionID: String
    let session: TerminalSession
    var name: String
    private(set) var state: ManagedTerminalState = .starting
    private(set) var lastExitCode: Int?

    private var commands: [String: String] = [:]
    private var outputCache = ManagedTerminalOutputCache()
    private var lastScreenReadAt: ContinuousClock.Instant?
    private var cachedScreenText = ""
    private let clock = ContinuousClock()

    init(
        id: String,
        capability: String,
        ownerSessionID: String,
        name: String,
        session: TerminalSession
    ) {
        self.id = id
        self.capability = capability
        self.ownerSessionID = ownerSessionID
        self.name = name
        self.session = session
        session.onProcessDidExit = { [weak self] exitCode in
            self?.state = .exited(code: exitCode)
        }
    }

    func markShellReady() throws {
        guard case .starting = state else {
            if case .exited = state {
                throw TerminalControlError.shellExited
            }
            return
        }
        state = .idle
    }

    func execute(_ command: String) throws -> String {
        guard session.isAttached else {
            throw TerminalControlError.shellStarting
        }
        switch state {
        case .starting:
            throw TerminalControlError.shellStarting
        case .running:
            throw TerminalControlError.commandRunning
        case .exited:
            throw TerminalControlError.shellExited
        case .idle:
            break
        }

        let commandID = UUID().uuidString.lowercased()
        commands[commandID] = command
        state = .running(commandID: commandID)
        session.write("__conan_code_run \(commandID)")
        session.sendKey(.enter)
        return commandID
    }

    func command(commandID: String) throws -> String {
        guard case .running(let currentID) = state,
              currentID == commandID,
              let command = commands[commandID] else {
            throw TerminalControlError.commandUnavailable
        }
        return command
    }

    func finish(commandID: String, exitCode: Int) throws {
        guard case .running(let currentID) = state,
              currentID == commandID else {
            throw TerminalControlError.commandUnavailable
        }
        commands.removeValue(forKey: commandID)
        lastExitCode = exitCode
        state = .idle
    }

    func write(_ text: String) throws {
        if case .exited = state {
            throw TerminalControlError.shellExited
        }
        guard session.isAttached else {
            throw TerminalControlError.shellStarting
        }
        session.write(text)
    }

    func sendKey(_ key: TerminalInputKey) throws {
        if case .exited = state {
            throw TerminalControlError.shellExited
        }
        guard session.isAttached else {
            throw TerminalControlError.shellStarting
        }
        session.sendKey(key)
    }

    func read(
        cursor: String?,
        maximumBytes: Int?
    ) -> ManagedTerminalReadResult {
        let now = clock.now
        if let lastScreenReadAt {
            if lastScreenReadAt.duration(to: now) >= .milliseconds(250) {
                cachedScreenText = session.screenText()
                self.lastScreenReadAt = now
            }
        } else {
            cachedScreenText = session.screenText()
            lastScreenReadAt = now
        }
        return outputCache.read(
            snapshot: cachedScreenText,
            generation: session.generation,
            cursor: cursor,
            maximumBytes: maximumBytes
        )
    }

    var statusPayload: GrokJSONValue {
        var payload: [String: GrokJSONValue] = [
            "tabID": .string(id),
            "title": .string(name),
            "state": .string(state.wireValue),
            "cwd": .string(session.workingDirectory),
        ]
        if case .running(let commandID) = state {
            payload["commandID"] = .string(commandID)
        }
        if case .exited(let code) = state {
            payload["shellExitCode"] = .int(Int(code))
        }
        if let lastExitCode {
            payload["lastExitCode"] = .int(lastExitCode)
        }
        return .object(payload)
    }
}
