import Foundation

struct GrokTerminalToolInvocation: Equatable, Sendable {
    let sessionID: String
    let command: String

    static func parseNotification(
        method: String,
        params: GrokJSONValue
    ) -> GrokTerminalToolInvocation? {
        guard method == GrokMethod.sessionUpdate
                || method == GrokMethod.sessionNotification
                || method == "session/update"
                || method == "session/notification" else {
            return nil
        }
        let update = params["update"] ?? params
        guard update["sessionUpdate"]?.stringValue == "tool_call",
              update["title"]?.stringValue == "run_terminal_command",
              let sessionID = params["sessionId"]?.stringValue,
              !sessionID.isEmpty,
              let command = update["rawInput"]?["command"]?.stringValue,
              !command.isEmpty else {
            return nil
        }
        return GrokTerminalToolInvocation(
            sessionID: sessionID,
            command: command
        )
    }

    var terminalControlRequestID: String? {
        let literal =
            NSRegularExpression.escapedPattern(
                for: TerminalControlContract.EnvironmentVariable
                    .requestID
            )
        let pattern =
            #"(?:^|[\s;&|])"# + literal
            + #"=['"]?([A-Za-z0-9-]{16,128})['"]?"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ),
              let match = expression.firstMatch(
                  in: command,
                  range: NSRange(command.startIndex..., in: command)
              ),
              let range = Range(match.range(at: 1), in: command) else {
            return nil
        }
        return String(command[range])
    }
}

@MainActor
final class TerminalControlInvocationAuthorizer {
    private struct Observation {
        let sessionID: String
        let expiresAt: ContinuousClock.Instant
    }

    private let clock = ContinuousClock()
    private let lifetime: Duration
    private var observations: [String: Observation] = [:]

    init(lifetime: Duration = .seconds(20)) {
        self.lifetime = lifetime
    }

    func observe(_ invocation: GrokTerminalToolInvocation) {
        guard let requestID = invocation.terminalControlRequestID else {
            return
        }
        removeExpired()
        observations[requestID] = Observation(
            sessionID: invocation.sessionID,
            expiresAt: clock.now.advanced(by: lifetime)
        )
    }

    func consume(
        requestID: String,
        wait: Duration = .seconds(3)
    ) async -> String? {
        let deadline = clock.now.advanced(by: wait)
        repeat {
            removeExpired()
            if let observation = observations.removeValue(
                forKey: requestID
            ) {
                return observation.sessionID
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        return nil
    }

    func reset() {
        observations.removeAll()
    }

    private func removeExpired() {
        let now = clock.now
        observations = observations.filter {
            $0.value.expiresAt > now
        }
    }
}
