import Foundation
import Testing

@testable import Coinor

private let rootID = "00000000-0000-7000-8000-000000000001"
private let childID = "00000000-0000-7000-8000-000000000002"
private let nestedID = "00000000-0000-7000-8000-000000000003"

private func event(
    _ name: GrokHookEventName,
    sessionID: String,
    childID: String? = nil,
    phase: String? = nil,
    timestamp: String = "2026-08-06T20:00:00Z"
) -> GrokHookEvent {
    GrokHookEvent(
        hookEventName: name,
        sessionId: sessionID,
        cwd: "/tmp/project",
        workspaceRoot: "/tmp/project",
        timestamp: timestamp,
        transcriptPath: nil,
        clientIdentifier: nil,
        promptId: nil,
        permissionMode: nil,
        source: nil,
        reason: nil,
        subagentId: childID,
        subagentType: nil,
        description: nil,
        phase: phase
    )
}

private func observation(
    _ kind: GrokSubagentLifecycleObservation.Kind,
    child: String = childID,
    parent: String = rootID
) -> GrokSubagentLifecycleObservation {
    GrokSubagentLifecycleObservation(
        kind: kind,
        childSessionID: child,
        parentSessionID: parent,
        description: nil,
        subagentType: nil,
        status: kind == .finished ? "completed" : nil,
        timestamp: "1786120000000"
    )
}

@Test
func nestedStartsMapToUltimateRootAndRemainFlat() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
    _ = state.apply(
        event(
            .subagentStart,
            sessionID: childID,
            childID: nestedID,
            timestamp: "2026-08-06T20:00:01Z"
        )
    )

    #expect(state.rootSessionID(for: nestedID) == rootID)
    #expect(state.orderedPanes.map(\.childSessionID) == [childID, nestedID])
}

@Test
func stopBeforeStartCannotResurrectPane() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = state.apply(
        event(.subagentStop, sessionID: childID, childID: childID, phase: "gate")
    )
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))

    #expect(state.orderedPanes.isEmpty)
}

@Test
func observeStopDoesNotCloseRunningPane() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))

    _ = state.apply(
        event(.subagentStop, sessionID: childID, childID: childID, phase: "observe")
    )

    #expect(state.orderedPanes.map(\.childSessionID) == [childID])
}

@Test
func rootDeathClosesEveryNestedDescendant() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
    _ = state.apply(
        event(.subagentStart, sessionID: childID, childID: nestedID)
    )

    let closed = state.rootProcessExited(sessionID: rootID)

    #expect(Set(closed) == [childID, nestedID])
    #expect(state.orderedPanes.isEmpty)
}

@Test
func persistedCancellationClosesChildWithoutStopHook() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
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

    let action = state.apply(
        observation(.progressed),
        workingDirectory: "/tmp/project"
    )

    guard case let .panesOpened(panes) = action else {
        Issue.record("progress should ensure the missing pane exists")
        return
    }
    #expect(panes.map(\.childSessionID) == [childID])
    #expect(state.rootSessionID(for: childID) == rootID)
}

@Test
func hookAndNativeStartOpenOnlyOnePane() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
    let duplicate = state.apply(
        observation(.started),
        workingDirectory: "/tmp/project"
    )

    #expect(duplicate == .ignored)
    #expect(state.orderedPanes.map(\.childSessionID) == [childID])
}

@Test
func nativeFinishBeforeStartLeavesATombstone() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)

    _ = state.apply(
        observation(.finished),
        workingDirectory: "/tmp/project"
    )
    _ = state.apply(
        observation(.started),
        workingDirectory: "/tmp/project"
    )

    #expect(state.orderedPanes.isEmpty)
}

@Test
func finishingAnIntermediateChildReparentsItsLiveDescendant() {
    var state = HookLifecycleState()
    state.activateRoot(sessionID: rootID)
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
    _ = state.apply(
        event(.subagentStart, sessionID: childID, childID: nestedID)
    )

    let action = state.apply(
        observation(.finished, child: childID, parent: rootID),
        workingDirectory: "/tmp/project"
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
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))

    let closed = state.deactivateRoot(sessionID: rootID)

    #expect(closed == [childID])
    #expect(state.orderedPanes.isEmpty)
    #expect(state.rootSessionID(for: rootID) == nil)

    state.activateRoot(sessionID: rootID)
    let action = state.apply(
        event(.subagentStart, sessionID: rootID, childID: nestedID)
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
    _ = state.apply(
        event(.subagentStart, sessionID: childID, childID: nestedID)
    )

    let action = state.apply(
        observation(.finished, child: childID, parent: rootID),
        workingDirectory: "/tmp/project"
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
    _ = state.apply(event(.subagentStart, sessionID: rootID, childID: childID))
    _ = state.apply(
        observation(.finished, child: childID, parent: rootID),
        workingDirectory: "/tmp/project"
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

    let action = state.apply(
        replayed,
        workingDirectory: "/tmp/project"
    )

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
    _ = state.apply(
        event(
            .subagentStart,
            sessionID: rootID,
            childID: nestedID,
            timestamp: "2026-08-06T20:00:02Z"
        )
    )
    _ = state.apply(
        event(
            .subagentStart,
            sessionID: rootID,
            childID: childID,
            timestamp: "2026-08-06T20:00:01Z"
        )
    )

    #expect(state.orderedPanes.map(\.childSessionID) == [childID, nestedID])
}
