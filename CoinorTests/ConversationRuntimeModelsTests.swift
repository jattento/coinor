import Testing

@testable import Coinor

private func launch(_ id: String) -> TerminalLaunchRequest {
    TerminalLaunchRequest(
        sessionID: id,
        workingDirectory: "/tmp/Project With Space",
        grokExecutable: "/Users/example/bin/grok",
        leaderSocket: "/tmp/coinor leader.sock",
        mode: .resume
    )
}

private func pane(
    _ id: String,
    parent: String,
    sequence: UInt64,
    activity: RuntimeActivity = .idle
) -> RuntimePane {
    RuntimePane(
        id: id,
        kind: .subagent(parentSessionID: parent),
        launch: launch(id),
        startSequence: sequence,
        activity: activity
    )
}

@Test
func terminalLaunchRequestQuotesEveryArgumentAndSelectsExactMode() {
    let request = launch("child-id")

    #expect(
        request.arguments == [
            "--leader-socket", "/tmp/coinor leader.sock",
            "--leader",
            "--cwd", "/tmp/Project With Space",
            "--resume", "child-id",
        ]
    )
    #expect(request.shellCommand.contains("'/tmp/Project With Space'"))
    #expect(request.shellCommand.contains("'--resume' 'child-id'"))
}

@Test
func terminalLaunchRequestPlacesWorktreeArgumentsBeforeTheSessionID() {
    let request = TerminalLaunchRequest(
        sessionID: "root-id",
        workingDirectory: "/tmp/project",
        grokExecutable: "/Users/example/bin/grok",
        leaderSocket: "/tmp/leader.sock",
        mode: .newSession,
        additionalArguments: [
            "--worktree=feature",
            "--worktree-ref=origin/main",
        ]
    )

    #expect(
        request.arguments == [
            "--leader-socket", "/tmp/leader.sock",
            "--leader",
            "--cwd", "/tmp/project",
            "--worktree=feature",
            "--worktree-ref=origin/main",
            "--session-id", "root-id",
        ]
    )
}

@Test
func descendantsStayFlatAndOrderedByStartSequence() {
    let root = RuntimePane(
        id: "root",
        kind: .root,
        launch: launch("root"),
        startSequence: 0,
        activity: .idle
    )
    var collection = ConversationPaneCollection(root: root)

    collection.startDescendant(pane("grandchild", parent: "child", sequence: 2))
    collection.startDescendant(pane("child", parent: "root", sequence: 1))

    #expect(collection.descendants.map(\.id) == ["child", "grandchild"])
    #expect(collection.usesSplitLayout)
}

@Test
func stopTombstonePreventsDelayedPaneResurrection() {
    let root = RuntimePane(
        id: "root",
        kind: .root,
        launch: launch("root"),
        startSequence: 0,
        activity: .idle
    )
    var collection = ConversationPaneCollection(root: root)

    collection.stopDescendant(sessionID: "child")
    collection.startDescendant(pane("child", parent: "root", sequence: 1))

    #expect(collection.descendants.isEmpty)
    #expect(!collection.usesSplitLayout)
}

@Test
func needsInputWinsAggregationAndRoutesFocusToFirstPane() {
    let root = RuntimePane(
        id: "root",
        kind: .root,
        launch: launch("root"),
        startSequence: 0,
        activity: .working
    )
    var collection = ConversationPaneCollection(root: root)
    collection.startDescendant(
        pane("child", parent: "root", sequence: 1, activity: .needsInput)
    )
    collection.startDescendant(
        pane("grandchild", parent: "child", sequence: 2, activity: .working)
    )

    #expect(collection.aggregateActivity == .needsInput)
    #expect(collection.attentionPaneID == "child")
}

@Test
func activityAggregationIsStableAcrossOrdering() {
    let permutations: [[RuntimeActivity]] = [
        [.working, .failed],
        [.failed, .working],
        [.idle, .failed, .working],
        [.working, .idle, .failed],
    ]
    for values in permutations {
        #expect(RuntimeActivity.aggregate(values) == .working)
    }
    #expect(
        RuntimeActivity.aggregate([.failed, .needsInput, .working])
            == .needsInput
    )
    #expect(RuntimeActivity.aggregate([.idle, .failed]) == .failed)
}

@Test
func grokRosterActivityMapsToRuntimePriorityStates() {
    #expect(RuntimeActivity(grokActivity: .working) == .working)
    #expect(RuntimeActivity(grokActivity: .needsInput) == .needsInput)
    #expect(RuntimeActivity(grokActivity: .dead) == .failed)
    #expect(RuntimeActivity(grokActivity: .completed) == .idle)
    #expect(RuntimeActivity(grokActivity: .dormant) == .idle)
    #expect(RuntimeActivity(grokActivity: .unknown("future")) == .idle)
}

@Test
func unarchivingCancelsAPendingRuntimeUnload() {
    var policy = RuntimeArchiveUnloadPolicy()

    policy.markArchived()
    #expect(policy.shouldUnload(activity: .working) == false)
    #expect(policy.shouldUnload(activity: .idle))

    policy.cancel()
    #expect(policy.shouldUnload(activity: .idle) == false)
    #expect(policy.isPending == false)
}
