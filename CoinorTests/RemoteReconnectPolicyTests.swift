import Testing

@testable import Coinor

@Suite
struct RemoteReconnectPolicyTests {
    private let policy = RemoteReconnectPolicy(
        delays: [
            .milliseconds(10),
            .milliseconds(20),
            .milliseconds(40),
        ]
    )

    @Test
    func reconnectsOnlyForSSHFailureExitCode() {
        #expect(policy.shouldReconnect(exitCode: 255, completedAttempts: 0))
        #expect(!policy.shouldReconnect(exitCode: 0, completedAttempts: 0))
        #expect(!policy.shouldReconnect(exitCode: 1, completedAttempts: 0))
        #expect(!policy.shouldReconnect(exitCode: 254, completedAttempts: 0))
    }

    @Test
    func reconnectAttemptBudgetMatchesAvailableDelays() {
        #expect(policy.shouldReconnect(exitCode: 255, completedAttempts: 0))
        #expect(policy.shouldReconnect(exitCode: 255, completedAttempts: 1))
        #expect(policy.shouldReconnect(exitCode: 255, completedAttempts: 2))
        #expect(!policy.shouldReconnect(exitCode: 255, completedAttempts: 3))
        #expect(!policy.shouldReconnect(exitCode: 255, completedAttempts: 4))
    }

    @Test
    func delaysAreReturnedInAttemptOrder() {
        #expect(policy.delay(after: 0) == .milliseconds(10))
        #expect(policy.delay(after: 1) == .milliseconds(20))
        #expect(policy.delay(after: 2) == .milliseconds(40))
        #expect(policy.delay(after: 3) == nil)
    }
}
