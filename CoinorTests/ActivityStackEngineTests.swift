import Foundation
import Testing

@testable import Coinor

private func candidate(
    _ id: String,
    title: String = "Conversation",
    project: String = "project",
    activity: RuntimeActivity,
    since: Date? = nil
) -> ActivityStackCandidate {
    ActivityStackCandidate(
        id: id,
        title: title,
        project: project,
        activity: activity,
        since: since
    )
}

private func recompute(
    _ candidates: [ActivityStackCandidate],
    previousActivity: [String: RuntimeActivity] = [:],
    pendingReason: [String: ActivityQueueReason] = [:],
    suppressions: [String: ActivityStackSuppression] = [:],
    pushedOrder: [String: Int] = [:],
    now: Date = Date()
) -> ActivityStackEngineResult {
    ActivityStackEngine.recompute(
        candidates: candidates,
        previousActivity: previousActivity,
        pendingReason: pendingReason,
        suppressions: suppressions,
        pushedOrder: pushedOrder,
        now: now
    )
}

@Test
func aSessionAlreadyNeedingInputOnFirstObservationEntersTheQueueImmediately() {
    // Unlike the sidebar's transition-only attention, the Activity Stack must
    // surface a conversation that was already needsInput before Coinor ever
    // observed it (e.g. never opened this run).
    let result = recompute([candidate("a", activity: .needsInput)])

    #expect(result.queue.map(\.id) == ["a"])
    #expect(result.queue[0].reason == .needsInput)
}

@Test
func workingAndDormantAndIdleNeverEnterTheQueue() {
    let result = recompute([
        candidate("working", activity: .working),
        candidate("dormant", activity: .dormant),
        candidate("idle", activity: .idle),
    ])

    #expect(result.queue.isEmpty)
    #expect(result.workingCount == 1)
}

@Test
func failedAndCompletedAreLiveStatesNotEdgeTriggered() {
    // Calling recompute repeatedly with the same failed/completed activity
    // must keep surfacing the item every time, since these are live states
    // Grok reports directly rather than one-shot transitions.
    var previousActivity: [String: RuntimeActivity] = [:]
    var pendingReason: [String: ActivityQueueReason] = [:]

    for _ in 0..<3 {
        let result = recompute(
            [
                candidate("failed", activity: .failed),
                candidate("done", activity: .completed),
            ],
            previousActivity: previousActivity,
            pendingReason: pendingReason
        )
        #expect(Set(result.queue.map(\.id)) == ["failed", "done"])
        previousActivity = result.previousActivity
        pendingReason = result.pendingReason
    }
}

@Test
func aTurnSettlingWithoutAQuestionRaisesAFinishedReasonOnce() {
    var previousActivity: [String: RuntimeActivity] = [:]
    var pendingReason: [String: ActivityQueueReason] = [:]

    let working = recompute(
        [candidate("a", activity: .working)],
        previousActivity: previousActivity,
        pendingReason: pendingReason
    )
    #expect(working.queue.isEmpty)
    previousActivity = working.previousActivity
    pendingReason = working.pendingReason

    let settled = recompute(
        [candidate("a", activity: .idle)],
        previousActivity: previousActivity,
        pendingReason: pendingReason
    )
    #expect(settled.queue.map(\.id) == ["a"])
    #expect(settled.queue[0].reason == .finished)
}

@Test
func respondingLeavesTheQueueAutomaticallyWhenActivityReturnsToWorking() {
    var previousActivity: [String: RuntimeActivity] = [:]
    var pendingReason: [String: ActivityQueueReason] = [:]

    let needsInput = recompute(
        [candidate("a", activity: .needsInput)],
        previousActivity: previousActivity,
        pendingReason: pendingReason
    )
    #expect(needsInput.queue.map(\.id) == ["a"])
    previousActivity = needsInput.previousActivity
    pendingReason = needsInput.pendingReason

    let respondedTo = recompute(
        [candidate("a", activity: .working)],
        previousActivity: previousActivity,
        pendingReason: pendingReason
    )
    #expect(respondedTo.queue.isEmpty)
}

@Test
func orderingPutsBlockingReasonsFirstThenFailedThenFinishedOldestFirstWithinAGroup() {
    let now = Date()
    let result = recompute([
        candidate("finishedNew", activity: .completed, since: now),
        candidate("failed", activity: .failed, since: now),
        candidate("needsInputOld", activity: .needsInput, since: now.addingTimeInterval(-600)),
        candidate("needsInputNew", activity: .needsInput, since: now.addingTimeInterval(-60)),
    ])

    #expect(
        result.queue.map(\.id) == [
            "needsInputOld", "needsInputNew", "failed", "finishedNew",
        ]
    )
}

@Test
func pushingToEndOverridesReasonOrderingForThisPass() {
    let result = recompute(
        [
            candidate("a", activity: .needsInput),
            candidate("b", activity: .failed),
        ],
        pushedOrder: ["a": 1]
    )

    #expect(result.queue.map(\.id) == ["b", "a"])
}

@Test
func dismissRemovesTheItemUntilANewFingerprintAppears() {
    let now = Date()
    let fingerprint = ActivityStackFingerprint(reason: .needsInput, since: now)
    let suppressions = ["a": ActivityStackSuppression.dismissed(fingerprint)]

    let stillSameInstance = recompute(
        [candidate("a", activity: .needsInput, since: now)],
        suppressions: suppressions
    )
    #expect(stillSameInstance.queue.isEmpty)

    let newInstance = recompute(
        [candidate("a", activity: .needsInput, since: now.addingTimeInterval(120))],
        suppressions: suppressions
    )
    #expect(newInstance.queue.map(\.id) == ["a"])
}

@Test
func mutedItemsAppearInAwayListAndReappearOnANewFailure() {
    let now = Date()
    let fingerprint = ActivityStackFingerprint(reason: .finished, since: now)
    let suppressions = ["a": ActivityStackSuppression.muted(fingerprint)]

    let muted = recompute(
        [candidate("a", activity: .completed, since: now)],
        suppressions: suppressions
    )
    #expect(muted.queue.isEmpty)
    #expect(muted.away.map(\.id) == ["a"])
    #expect(muted.away[0].reason == .muted)

    // A fresh failure is a new fingerprint, so a muted conversation still
    // surfaces once instead of staying silent.
    let failedWhileMuted = recompute(
        [candidate("a", activity: .failed, since: now)],
        suppressions: suppressions
    )
    #expect(failedWhileMuted.queue.map(\.id) == ["a"])
    #expect(failedWhileMuted.away.isEmpty)
}

@Test
func snoozeHidesTheItemUntilTheTimerExpiresThenItReturnsOnItsOwn() {
    let now = Date()
    let fingerprint = ActivityStackFingerprint(reason: .needsInput, since: now)
    let suppressions = [
        "a": ActivityStackSuppression.snoozed(
            until: now.addingTimeInterval(900),
            fingerprint: fingerprint
        ),
    ]

    let stillSnoozed = recompute(
        [candidate("a", activity: .needsInput, since: now)],
        suppressions: suppressions,
        now: now.addingTimeInterval(300)
    )
    #expect(stillSnoozed.queue.isEmpty)
    #expect(stillSnoozed.away.count == 1)

    let expired = recompute(
        [candidate("a", activity: .needsInput, since: now)],
        suppressions: suppressions,
        now: now.addingTimeInterval(1000)
    )
    #expect(expired.queue.map(\.id) == ["a"])
}

