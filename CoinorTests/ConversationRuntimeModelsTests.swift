import Foundation
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
func shellLaunchLeavesCommandSelectionToGhostty() {
    let request = TerminalLaunchRequest(
        shellTabID: "shell-id",
        workingDirectory: "/tmp/project"
    )

    #expect(request.mode == .shell)
    #expect(request.explicitCommand == nil)
    #expect(request.arguments.isEmpty)
    #expect(request.surfaceContext == .tab)
    #expect(request.waitsAfterCommand == false)
}

@Test
func commandLaunchUsesTheRequestedProgramInsideASplitSurface() {
    let request = TerminalLaunchRequest(
        commandID: "conversation.ide.fresh",
        workingDirectory: "/tmp/project",
        command: "fresh ."
    )

    #expect(request.mode == .command("fresh ."))
    #expect(request.explicitCommand == "fresh .")
    #expect(request.arguments.isEmpty)
    #expect(request.surfaceContext == .split)
    #expect(request.waitsAfterCommand)
}

@Test
func managedShellLaunchUsesFixedZshEnvironmentAndBootstrap() {
    let request = TerminalLaunchRequest(
        managedTabID: "managed-id",
        workingDirectory: "/tmp/project",
        environment: ["CONAN_CODE_TAB_ID": "managed-id"],
        bootstrapPath: "/tmp/bootstrap script.zsh"
    )

    #expect(request.mode == .managedShell)
    #expect(request.explicitCommand == "/bin/zsh -il")
    #expect(request.environment["CONAN_CODE_TAB_ID"] == "managed-id")
    #expect(
        request.initialInput
            == "source '/tmp/bootstrap script.zsh'\r"
    )
    #expect(request.surfaceContext == .tab)
    #expect(request.waitsAfterCommand == false)
}

@Test
func remoteLaunchRunsSSHLocallyAndComposesGrokRemotely() throws {
    let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
    let request = TerminalLaunchRequest(
        sessionID: "remote-session",
        workingDirectory: "/remote/Project With Space",
        grokExecutable: "/remote/bin/grok",
        leaderSocket: "/remote/leader.sock",
        mode: .resume,
        environment: ["REMOTE_VALUE": "two words"],
        remote: RemoteExecution(
            alias: alias,
            controlPath: "/tmp/coinor ssh/control.sock"
        )
    )

    #expect(request.shellCommand.hasPrefix("'/usr/bin/ssh' "))
    #expect(request.shellCommand.contains("/remote/bin/grok"))
    #expect(request.shellCommand.contains("--resume"))
    #expect(request.shellCommand.contains("remote-session"))
    #expect(request.surfaceWorkingDirectory == NSHomeDirectory())
    #expect(request.surfaceEnvironment.isEmpty)
    #expect(request.explicitCommand == request.shellCommand)
}

@Test
func remoteShellLaunchAlwaysSuppliesAnExplicitSSHCommand() throws {
    let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
    let request = TerminalLaunchRequest(
        shellTabID: "remote-shell",
        workingDirectory: "/remote/project",
        remote: RemoteExecution(
            alias: alias,
            controlPath: "/tmp/control.sock"
        )
    )

    #expect(request.mode == .shell)
    #expect(request.explicitCommand == request.shellCommand)
    #expect(request.explicitCommand != nil)
    #expect(request.surfaceWorkingDirectory == NSHomeDirectory())
    #expect(request.surfaceEnvironment.isEmpty)
}

@Test
func localLaunchPreservesTheExactPreRemoteBehavior() {
    let request = TerminalLaunchRequest(
        sessionID: "local-session",
        workingDirectory: "/tmp/Project With Space",
        grokExecutable: "/Users/example/bin/grok",
        leaderSocket: "/tmp/coinor leader.sock",
        mode: .resume,
        environment: ["LOCAL_VALUE": "unchanged"]
    )
    let expectedCommand = "'/Users/example/bin/grok' "
        + "'--leader-socket' '/tmp/coinor leader.sock' '--leader' "
        + "'--cwd' '/tmp/Project With Space' '--resume' 'local-session'"

    #expect(request.shellCommand == expectedCommand)
    #expect(request.explicitCommand == expectedCommand)
    #expect(request.surfaceWorkingDirectory == "/tmp/Project With Space")
    #expect(request.surfaceEnvironment == ["LOCAL_VALUE": "unchanged"])
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
    #expect(RuntimeActivity.aggregate([.dormant, .completed]) == .completed)
    #expect(RuntimeActivity.aggregate([.dormant, .idle]) == .idle)
    #expect(RuntimeActivity.aggregate([RuntimeActivity]()) == .idle)
}

@Test
func grokRosterActivityMapsToRuntimePriorityStates() {
    #expect(RuntimeActivity(grokActivity: .working) == .working)
    #expect(RuntimeActivity(grokActivity: .needsInput) == .needsInput)
    #expect(RuntimeActivity(grokActivity: .dead) == .failed)
    #expect(RuntimeActivity(grokActivity: .completed) == .completed)
    #expect(RuntimeActivity(grokActivity: .dormant) == .dormant)
    #expect(RuntimeActivity(grokActivity: .unknown("future")) == .idle)
}

@Test
func aFinishedRunRaisesAttentionEvenWithoutNeedsInput() {
    #expect(
        ConversationAttention.transition(from: .working, to: .idle)
            == .raised(.finished)
    )
    #expect(
        ConversationAttention.transition(from: .working, to: .completed)
            == .raised(.finished)
    )
    #expect(
        ConversationAttention.transition(from: .working, to: .needsInput)
            == .raised(.question)
    )
    #expect(
        ConversationAttention.transition(from: .idle, to: .needsInput)
            == .raised(.question)
    )
}

@Test
func attentionSettlesWhileWorkingAndHoldsOtherwise() {
    #expect(
        ConversationAttention.transition(from: .idle, to: .working)
            == .settled
    )
    #expect(
        ConversationAttention.transition(from: .needsInput, to: .working)
            == .settled
    )
    #expect(
        ConversationAttention.transition(from: .needsInput, to: .needsInput)
            == .unchanged
    )
    #expect(
        ConversationAttention.transition(from: .idle, to: .idle) == .unchanged
    )
    #expect(
        ConversationAttention.transition(from: nil, to: .idle) == .unchanged
    )
    #expect(
        ConversationAttention.transition(from: .working, to: .failed)
            == .unchanged
    )
}

@Test
func everyActivityAndAttentionPairHasItsOwnIndicator() {
    #expect(
        ConversationIndicator.resolve(activity: .working, attention: nil)
            == .working
    )
    #expect(
        ConversationIndicator.resolve(activity: .idle, attention: nil) == .none
    )
    #expect(
        ConversationIndicator.resolve(activity: .needsInput, attention: nil)
            == .none
    )
    #expect(
        ConversationIndicator.resolve(activity: .dormant, attention: nil)
            == .dormant
    )
    #expect(
        ConversationIndicator.resolve(activity: .completed, attention: nil)
            == .completed
    )
    #expect(
        ConversationIndicator.resolve(activity: .idle, attention: .question)
            == .waiting
    )
    #expect(
        ConversationIndicator.resolve(activity: .idle, attention: .finished)
            == .finished
    )
    // A broken conversation outranks anything it was asking for.
    #expect(
        ConversationIndicator.resolve(activity: .failed, attention: .finished)
            == .failed
    )
}

@Test
func projectIndicatorsShowTheMostDemandingConversation() {
    #expect(
        ConversationIndicator.aggregate([.dormant, .working, .finished])
            == .finished
    )
    #expect(
        ConversationIndicator.aggregate([.finished, .failed]) == .failed
    )
    #expect(
        ConversationIndicator.aggregate([.finished, .waiting]) == .waiting
    )
    #expect(
        ConversationIndicator.aggregate([.none, .dormant]) == .dormant
    )
    #expect(ConversationIndicator.aggregate([ConversationIndicator]()) == .none)
}

@Suite
struct ProjectIndicatorPropagationTests {
    @Test
    func aProjectNeverInheritsPerConversationLifecycleStates() {
        // A project is a grouping: it cannot be dormant or closed.
        #expect(!ConversationIndicator.dormant.propagatesToProject)
        #expect(!ConversationIndicator.completed.propagatesToProject)
        #expect(!ConversationIndicator.none.propagatesToProject)
    }

    @Test
    func aProjectStillSurfacesAttentionAndWork() {
        #expect(ConversationIndicator.failed.propagatesToProject)
        #expect(ConversationIndicator.waiting.propagatesToProject)
        #expect(ConversationIndicator.working.propagatesToProject)
        #expect(ConversationIndicator.finished.propagatesToProject)
    }

    @Test
    func aProjectWhoseConversationsAreAllDormantShowsNothing() {
        let indicators: [ConversationIndicator] = [.dormant, .completed, .none]

        let aggregated = ConversationIndicator.aggregate(
            indicators.filter(\.propagatesToProject)
        )

        #expect(aggregated == .none)
    }

    @Test
    func oneWorkingConversationStillMarksItsProject() {
        let indicators: [ConversationIndicator] = [.dormant, .working, .completed]

        let aggregated = ConversationIndicator.aggregate(
            indicators.filter(\.propagatesToProject)
        )

        #expect(aggregated == .working)
    }
}
