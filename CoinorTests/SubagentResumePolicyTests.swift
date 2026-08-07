import Testing

@testable import Coinor

private let policy = SubagentResumePolicy(
    delays: [.milliseconds(10), .milliseconds(20)]
)

@Test
func retriesOnlyTheExactFinalMissingSessionLine() {
    #expect(
        policy.shouldRetry(
            terminalText: "startup output\nError: Session does not exist\n",
            processRuntimeMilliseconds: 100,
            completedRetries: 0
        )
    )
    #expect(
        !policy.shouldRetry(
            terminalText: "Error: Session does not exist locally",
            processRuntimeMilliseconds: 100,
            completedRetries: 0
        )
    )
    #expect(
        !policy.shouldRetry(
            terminalText: "Error: Session does not exist\nAuthentication failed",
            processRuntimeMilliseconds: 100,
            completedRetries: 0
        )
    )
}

@Test
func retryRequiresAnEarlyExitAndRemainingAttempt() {
    #expect(
        !policy.shouldRetry(
            terminalText: "Error: Session does not exist",
            processRuntimeMilliseconds: 5_001,
            completedRetries: 0
        )
    )
    #expect(
        !policy.shouldRetry(
            terminalText: "Error: Session does not exist",
            processRuntimeMilliseconds: 100,
            completedRetries: 2
        )
    )
    #expect(policy.delay(after: 0) == .milliseconds(10))
    #expect(policy.delay(after: 1) == .milliseconds(20))
    #expect(policy.delay(after: 2) == nil)
}
