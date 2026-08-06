import Foundation
import Testing

@testable import HookSpikeHarnessCore

@Test
func decodesEveryRegisteredHookEnvelope() throws {
    let names = try [
        GrokHookEvent.decode(Fixture.data("session-start")).hookEventName,
        GrokHookEvent.decode(Fixture.data("subagent-start")).hookEventName,
        GrokHookEvent.decode(Fixture.data("subagent-stop")).hookEventName,
        GrokHookEvent.decode(Fixture.data("session-end")).hookEventName,
    ]

    #expect(
        names == [
            .sessionStart,
            .subagentStart,
            .subagentStop,
            .sessionEnd,
        ]
    )
}

@Test
func mapsNestedChildrenToUltimateRootAndKeepsFlatStartOrder() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("session-start"))
    try state.apply(jsonData: Fixture.data("subagent-start"))
    try state.apply(jsonData: Fixture.data("nested-subagent-start"))

    #expect(state.rootSessionID(for: Fixture.child) == Fixture.root)
    #expect(state.rootSessionID(for: Fixture.grandchild) == Fixture.root)
    #expect(
        state.orderedPanes.map(\.childSessionID)
            == [Fixture.child, Fixture.grandchild]
    )
}

@Test
func duplicateStartIsIdempotent() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    let start = try Fixture.data("subagent-start")

    try state.apply(jsonData: start)
    try state.apply(jsonData: start)

    #expect(state.orderedPanes.count == 1)
    #expect(state.orderedPanes.first?.startSequence == 1)
}

@Test
func stopBeforeStartPreventsDelayedResurrection() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )

    try state.apply(jsonData: Fixture.data("subagent-stop"))
    try state.apply(jsonData: Fixture.data("subagent-start"))

    #expect(state.orderedPanes.isEmpty)
    #expect(state.snapshot().terminalSessionIDs.contains(Fixture.child))
}

@Test
func duplicateStopRemainsIdempotent() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("subagent-start"))
    let stop = try Fixture.data("subagent-stop")

    try state.apply(jsonData: stop)
    try state.apply(jsonData: stop)

    #expect(state.orderedPanes.isEmpty)
    #expect(
        state.snapshot().terminalSessionIDs.filter { $0 == Fixture.child }.count == 1
    )
}

@Test
func observePhaseStopDoesNotCloseAStillRunningPane() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("subagent-start"))
    let gateStop = String(
        data: try Fixture.data("subagent-stop"),
        encoding: .utf8
    )!
    let observeStop = Data(
        gateStop.replacingOccurrences(
            of: #""phase": "gate""#,
            with: #""phase": "observe""#
        ).utf8
    )

    try state.apply(jsonData: observeStop)

    #expect(state.orderedPanes.map(\.childSessionID) == [Fixture.child])
    #expect(!state.snapshot().terminalSessionIDs.contains(Fixture.child))
}

@Test
func nestedStartBuffersUntilItsParentStartArrives() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )

    try state.apply(jsonData: Fixture.data("nested-subagent-start"))
    #expect(state.pendingChildSessionIDs == [Fixture.grandchild])

    try state.apply(jsonData: Fixture.data("subagent-start"))

    #expect(state.pendingChildSessionIDs.isEmpty)
    #expect(
        state.orderedPanes.map(\.childSessionID)
            == [Fixture.child, Fixture.grandchild]
    )
    #expect(state.rootSessionID(for: Fixture.grandchild) == Fixture.root)
}

@Test
func stoppingParentClosesItsWholeNestedSubtree() throws {
    var state = try populatedNestedState()

    try state.apply(jsonData: Fixture.data("subagent-stop"))

    #expect(state.orderedPanes.isEmpty)
    #expect(
        Set(state.snapshot().terminalSessionIDs)
            .isSuperset(of: [Fixture.child, Fixture.grandchild])
    )
}

@Test
func sessionEndClosesAllRootDescendants() throws {
    var state = try populatedNestedState()

    try state.apply(jsonData: Fixture.data("session-end"))

    #expect(state.orderedPanes.isEmpty)
    #expect(state.snapshot().activeRootSessionIDs.isEmpty)
}

@Test
func childSessionEndClosesOnlyThatChildSubtree() throws {
    var state = try populatedNestedState()
    let childEnd = try Fixture.replacing(
        Fixture.data("session-end"),
        sessionID: Fixture.child
    )

    try state.apply(jsonData: childEnd)

    #expect(state.orderedPanes.isEmpty)
    #expect(state.snapshot().activeRootSessionIDs == [Fixture.root])
}

@Test
func rootDeathClosesEveryDescendantUsingUltimateRootIdentity() throws {
    var state = try populatedNestedState()

    let closed = state.rootProcessExited(sessionID: Fixture.root)

    #expect(Set(closed) == [Fixture.child, Fixture.grandchild])
    #expect(state.orderedPanes.isEmpty)
    #expect(state.rootSessionID(for: Fixture.grandchild) == nil)
}

@Test
func cancellationFixtureClosesChildWithoutSubagentStop() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("subagent-start"))

    let closed = state.applyPersistedRecord(
        sessionID: Fixture.child,
        jsonLine: try Fixture.data("cancelled-event", extension: "jsonl")
    )

    #expect(closed == [Fixture.child])
    #expect(state.orderedPanes.isEmpty)
}

@Test
func rootCancellationDoesNotCloseAStillRunningChild() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("subagent-start"))

    let closed = state.applyPersistedRecord(
        sessionID: Fixture.root,
        jsonLine: try Fixture.data("cancelled-event", extension: "jsonl")
    )

    #expect(closed.isEmpty)
    #expect(state.orderedPanes.map(\.childSessionID) == [Fixture.child])
}

@Test
func failedRetryFixtureClosesButRetryingFixtureDoesNot() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("subagent-start"))

    let retrying = state.applyPersistedRecord(
        sessionID: Fixture.child,
        jsonLine: try Fixture.data("retrying-update", extension: "jsonl")
    )
    #expect(retrying.isEmpty)
    #expect(state.orderedPanes.count == 1)

    let failed = state.applyPersistedRecord(
        sessionID: Fixture.child,
        jsonLine: try Fixture.data("retry-failed-update", extension: "jsonl")
    )
    #expect(failed == [Fixture.child])
    #expect(state.orderedPanes.isEmpty)
}

@Test
func eventsForUnactivatedRootRemainInert() throws {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    let externalStart = try Fixture.replacing(
        Fixture.data("session-start"),
        sessionID: Fixture.external
    )
    let externalChild = try Fixture.replacing(
        Fixture.data("subagent-start"),
        sessionID: Fixture.external,
        subagentID: "00000000-0000-7000-8000-000000000998"
    )

    try state.apply(jsonData: externalChild)
    #expect(
        state.pendingChildSessionIDs
            == ["00000000-0000-7000-8000-000000000998"]
    )

    try state.apply(jsonData: externalStart)

    #expect(state.orderedPanes.isEmpty)
    #expect(state.pendingChildSessionIDs.isEmpty)
    #expect(state.rootSessionID(for: Fixture.external) == nil)
}

private func populatedNestedState() throws -> HookLifecycleState {
    var state = HookLifecycleState(
        activatedRootSessionIDs: [Fixture.root]
    )
    try state.apply(jsonData: Fixture.data("session-start"))
    try state.apply(jsonData: Fixture.data("subagent-start"))
    try state.apply(jsonData: Fixture.data("nested-subagent-start"))
    return state
}
