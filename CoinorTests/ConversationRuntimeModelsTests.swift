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
        environment: [
            TerminalControlContract.EnvironmentVariable.tabID:
                "managed-id",
        ],
        bootstrapPath: "/tmp/bootstrap script.zsh"
    )

    #expect(request.mode == .managedShell)
    #expect(request.explicitCommand == "/bin/zsh -il")
    #expect(
        request.environment[
            TerminalControlContract.EnvironmentVariable.tabID
        ] == "managed-id"
    )
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
func liveDescendantActivityKeepsTheConversationWorkingUntilItFinishes() {
    let childID = "child"
    let childActivity = [childID: RuntimeActivity.descendantSeed]

    let whileChildIsLive = RuntimeActivity.aggregate(
        root: .idle,
        liveDescendantIDs: [childID],
        descendantActivity: childActivity
    )
    #expect(whileChildIsLive == .working)
    #expect(
        ConversationIndicator.resolve(
            activity: whileChildIsLive,
            attention: nil
        ) == .working
    )

    #expect(
        RuntimeActivity.aggregate(
            root: .idle,
            liveDescendantIDs: [],
            descendantActivity: childActivity
        ) == .idle
    )
    #expect(
        RuntimeActivity.aggregate(
            root: .working,
            liveDescendantIDs: [],
            descendantActivity: childActivity
        ) == .working
    )
    #expect(
        RuntimeActivity.aggregate(
            root: .needsInput,
            liveDescendantIDs: [childID],
            descendantActivity: childActivity
        ) == .needsInput
    )
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


@Suite
struct SurfaceStartupFailureTests {
    private func remote() -> RemoteExecution {
        RemoteExecution(
            alias: RemoteHostAlias(rawValue: "studio")!,
            controlPath: "/tmp/studio.sock"
        )
    }

    @Test
    func aLocalConversationInAMissingDirectoryReportsIt() {
        let launch = TerminalLaunchRequest(
            sessionID: "s",
            workingDirectory: "/nonexistent/coinor/project",
            grokExecutable: "/bin/grok",
            leaderSocket: "/tmp/leader.sock",
            mode: .resume
        )

        #expect(launch.surfaceStartupFailure()?.contains("unavailable") == true)
    }

    @Test
    func aLocalConversationInARealDirectoryStarts() {
        let launch = TerminalLaunchRequest(
            sessionID: "s",
            workingDirectory: NSHomeDirectory(),
            grokExecutable: "/bin/grok",
            leaderSocket: "/tmp/leader.sock",
            mode: .resume
        )

        #expect(launch.surfaceStartupFailure() == nil)
    }

    @Test
    func aRemoteConversationIsNeverCheckedAgainstThisFileSystem() {
        // This path exists on the other computer only. Checking it here is
        // what reported every remote conversation as unavailable.
        let launch = TerminalLaunchRequest(
            sessionID: "s",
            workingDirectory: "/Users/someone-else/projects/repo",
            grokExecutable: "/Users/someone-else/bin/grok",
            leaderSocket: "/Users/someone-else/leader.sock",
            mode: .resume,
            remote: remote()
        )

        #expect(launch.surfaceStartupFailure() == nil)
    }

    @Test
    func anUnresolvedDirectoryIsStillReported() {
        let local = TerminalLaunchRequest(shellTabID: "a", workingDirectory: "")
        let remoteTab = TerminalLaunchRequest(
            shellTabID: "b",
            workingDirectory: "",
            remote: remote()
        )

        #expect(local.surfaceStartupFailure() != nil)
        #expect(remoteTab.surfaceStartupFailure() != nil)
    }
}
