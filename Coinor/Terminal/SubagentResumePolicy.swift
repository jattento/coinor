import Foundation

struct SubagentResumePolicy: Equatable, Sendable {
    static let missingSessionLine = "Error: Session does not exist"

    let delays: [Duration]
    let maximumInitialRuntimeMilliseconds: UInt64

    init(
        delays: [Duration] = [
            .milliseconds(50),
            .milliseconds(100),
            .milliseconds(200),
            .milliseconds(350),
            .milliseconds(500),
            .milliseconds(800),
            .seconds(1),
        ],
        maximumInitialRuntimeMilliseconds: UInt64 = 5_000
    ) {
        self.delays = delays
        self.maximumInitialRuntimeMilliseconds =
            maximumInitialRuntimeMilliseconds
    }

    func shouldRetry(
        terminalText: String,
        processRuntimeMilliseconds: UInt64,
        completedRetries: Int
    ) -> Bool {
        guard completedRetries < delays.count,
              processRuntimeMilliseconds <= maximumInitialRuntimeMilliseconds
        else {
            return false
        }
        let lastLine = terminalText
            .split(whereSeparator: \.isNewline)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastLine == Self.missingSessionLine
    }

    func delay(after completedRetries: Int) -> Duration? {
        guard delays.indices.contains(completedRetries) else { return nil }
        return delays[completedRetries]
    }
}
