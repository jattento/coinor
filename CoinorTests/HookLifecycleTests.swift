import Foundation
import Testing

@testable import Coinor

private let rootID = "00000000-0000-7000-8000-000000000001"
private let childID = "00000000-0000-7000-8000-000000000002"
private let nestedID = "00000000-0000-7000-8000-000000000003"

private func observation(
    _ kind: GrokSubagentLifecycleObservation.Kind,
    child: String = childID,
    parent: String = rootID,
    timestamp: String = "1786120000000"
) -> GrokSubagentLifecycleObservation {
    GrokSubagentLifecycleObservation(
        kind: kind,
        childSessionID: child,
        parentSessionID: parent,
        description: nil,
        subagentType: nil,
        status: kind == .finished ? "completed" : nil,
        timestamp: timestamp
    )
}

private func apply(
    _ observation: GrokSubagentLifecycleObservation,
    to state: inout HookLifecycleState
) -> HookLifecycleAction {
    state.apply(observation, workingDirectory: "/tmp/project")
}

@Test
func nestedStartsMapToUltimateRootAndRemainFlat() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = apply(observation(.started), to: &state)
    _ = apply(
        observation(
            .started,
            child: nestedID,
            parent: childID,
            timestamp: "1786120001000"
        ),
        to: &state
    )

    #expect(state.rootSessionID(for: nestedID) == rootID)
    #expect(state.orderedPanes.map(\.childSessionID) == [childID, nestedID])
}

@Test
func finishBeforeStartCannotResurrectPane() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = apply(observation(.finished), to: &state)
    _ = apply(observation(.started), to: &state)

    #expect(state.orderedPanes.isEmpty)
}

@Test
func rootDeathClosesEveryNestedDescendant() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(observation(.started), to: &state)
    _ = apply(
        observation(.started, child: nestedID, parent: childID),
        to: &state
    )

    let closed = state.rootProcessExited(sessionID: rootID)

    #expect(Set(closed) == [childID, nestedID])
    #expect(state.orderedPanes.isEmpty)
}

@Test
func persistedCancellationClosesChildWithoutLifecycleFinish() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(observation(.started), to: &state)
    let line = Data(
        #"{"type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort"}"#.utf8
    )

    let action = state.applyPersistedRecord(
        sessionID: childID,
        jsonLine: line
    )

    #expect(action == .panesClosed([childID]))
    #expect(state.orderedPanes.isEmpty)
}

@Test
func nativeProgressRecoversAMissedStart() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    let action = apply(observation(.progressed), to: &state)

    guard case let .panesOpened(panes) = action else {
        Issue.record("progress should ensure the missing pane exists")
        return
    }
    #expect(panes.map(\.childSessionID) == [childID])
    #expect(state.rootSessionID(for: childID) == rootID)
}

@Test
func duplicateNativeStartOpensOnlyOnePane() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = apply(observation(.started), to: &state)
    let duplicate = apply(observation(.started), to: &state)

    #expect(duplicate == .ignored)
    #expect(state.orderedPanes.map(\.childSessionID) == [childID])
}

@Test
func finishingAnIntermediateChildReparentsItsLiveDescendant() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(observation(.started), to: &state)
    _ = apply(
        observation(.started, child: nestedID, parent: childID),
        to: &state
    )

    let action = apply(
        observation(.finished, child: childID, parent: rootID),
        to: &state
    )

    #expect(action == .panesClosed([childID]))
    #expect(state.orderedPanes.map(\.childSessionID) == [nestedID])
    #expect(state.orderedPanes.first?.immediateParentSessionID == rootID)
    #expect(state.rootSessionID(for: nestedID) == rootID)
}

@Test
func archivedUnloadCanDeactivateAndLaterReactivateARoot() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(observation(.started), to: &state)

    let closed = state.deactivateRoot(sessionID: rootID)

    #expect(closed == [childID])
    #expect(state.orderedPanes.isEmpty)
    #expect(state.rootSessionID(for: rootID) == nil)

    state.activateRoot(sessionID: rootID)
    let action = apply(
        observation(.started, child: nestedID),
        to: &state
    )
    guard case let .panesOpened(panes) = action else {
        Issue.record("a non-terminal unload must allow later reactivation")
        return
    }
    #expect(panes.map(\.childSessionID) == [nestedID])
}

@Test
func finishingAnUnobservedParentOpensItsBufferedLiveChild() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(
        observation(.started, child: nestedID, parent: childID),
        to: &state
    )

    let action = apply(
        observation(.finished, child: childID, parent: rootID),
        to: &state
    )

    guard case let .panesOpened(panes) = action else {
        Issue.record("reparenting should surface the buffered live child")
        return
    }
    #expect(panes.map(\.childSessionID) == [nestedID])
    #expect(state.orderedPanes.first?.immediateParentSessionID == rootID)
}

@Test
func replayReparentsAChildDiscoveredAfterItsParentFinished() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(observation(.started), to: &state)
    _ = apply(
        observation(.finished, child: childID, parent: rootID),
        to: &state
    )
    let nestedStart = observation(
        .started,
        child: nestedID,
        parent: childID
    )
    let replayed = AppCoordinator.normalizedReplayObservation(
        nestedStart,
        targetSessionID: childID,
        targetIsActive: false,
        rootSessionID: rootID
    )

    let action = apply(replayed, to: &state)

    guard case let .panesOpened(panes) = action else {
        Issue.record("the replayed nested child should open under the root")
        return
    }
    #expect(panes.map(\.childSessionID) == [nestedID])
    #expect(panes.first?.immediateParentSessionID == rootID)
    #expect(state.rootSessionID(for: nestedID) == rootID)
}

@Test
func panesUseStartTimeBeforeDeliveryOrder() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = apply(
        observation(
            .started,
            child: nestedID,
            timestamp: "1786120002000"
        ),
        to: &state
    )
    _ = apply(
        observation(
            .started,
            child: childID,
            timestamp: "1786120001000"
        ),
        to: &state
    )

    #expect(state.orderedPanes.map(\.childSessionID) == [childID, nestedID])
}
