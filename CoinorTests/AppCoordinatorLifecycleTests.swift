import Foundation
import Testing

@testable import Coinor

@Suite
struct RemoteHostConnectionMachineTests {
    private let studio = RemoteHostAlias(rawValue: "studio-mac")!
    private let office = RemoteHostAlias(rawValue: "office-mac")!

    @Test
    func explicitlyStoppedHostIsNeverAutoReconnected() {
        let stopped = RemoteHostConnectionMachine.apply(nil, .stop)

        #expect(stopped == .stopped)
        #expect(
            !RemoteHostConnectionMachine.shouldAutoReconnect(stopped)
        )
        #expect(
            RemoteHostConnectionMachine.apply(stopped, .connect) == .stopped
        )
        #expect(
            RemoteHostConnectionMachine.aliasesEligibleForAutoConnect(
                registered: [studio, office],
                states: [studio: .stopped]
            ) == [office]
        )
    }

    @Test
    func failedRegistrationLeavesNoRuntimeListenerOrEventTask() {
        let connecting = RemoteHostConnectionMachine.apply(nil, .connect)
        let residue = RemoteHostConnectionMachine.artifacts(
            after: .fail,
            current: connecting
        )

        #expect(connecting == .connecting)
        #expect(residue.state == .failed)
        #expect(!residue.hasRuntime)
        #expect(!residue.hasEventTask)
        #expect(residue == RemoteHostConnectionArtifacts(
            state: .failed,
            hasRuntime: false,
            hasEventTask: false
        ))
    }

    @Test
    func lateSuccessAfterStopDoesNotPublishResidue() {
        let stopped = RemoteHostConnectionMachine.apply(.connecting, .stop)
        let residue = RemoteHostConnectionMachine.artifacts(
            after: .succeed,
            current: stopped
        )

        #expect(stopped == .stopped)
        #expect(residue.state == .stopped)
        #expect(!residue.hasRuntime)
        #expect(!residue.hasEventTask)
    }

    @Test
    func shutdownCancelsEventTasksAndDropsTheRuntime() {
        let residue = RemoteHostConnectionMachine.artifacts(
            after: .shutdown,
            current: .connected
        )

        #expect(residue == .empty)
        #expect(residue.state == nil)
        #expect(!residue.hasRuntime)
        #expect(!residue.hasEventTask)
    }

    @Test
    func restartPreservesStoppedAndDropsEveryOtherHost() {
        #expect(
            RemoteHostConnectionMachine.apply(.stopped, .restart) == .stopped
        )
        #expect(
            RemoteHostConnectionMachine.apply(.connected, .restart) == nil
        )
        #expect(
            RemoteHostConnectionMachine.apply(.failed, .restart) == nil
        )
        #expect(
            RemoteHostConnectionMachine.apply(.connecting, .restart) == nil
        )
    }

    @Test
    func explicitRetryLeavesStoppedAndReconnects() {
        #expect(
            RemoteHostConnectionMachine.apply(.stopped, .retry) == .connecting
        )
        #expect(
            RemoteHostConnectionMachine.artifacts(
                after: .succeed,
                current: .connecting
            ) == RemoteHostConnectionArtifacts(
                state: .connected,
                hasRuntime: true,
                hasEventTask: true
            )
        )
    }

    @Test
    func removeDropsStateEntirely() {
        #expect(RemoteHostConnectionMachine.apply(.stopped, .remove) == nil)
        #expect(RemoteHostConnectionMachine.apply(.connected, .remove) == nil)
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(nil)
        )
    }

    @Test
    func connectionConcurrencyBoundIsFour() {
        #expect(
            RemoteHostConnectionMachine.connectionConcurrencyLimit == 4
        )
    }

    @Test
    func absenceOfARuntimeIsNotEnoughToReconnectAStoppedHost() {
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(.stopped) == false
        )
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(.connecting) == false
        )
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(.connected) == false
        )
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(.failed)
        )
        #expect(
            RemoteHostConnectionMachine.shouldAutoReconnect(nil)
        )
    }
}

@Suite
struct CatalogStateMergeTests {
    @Test
    func localRefreshDoesNotDuplicateRemoteEntries() throws {
        let local = try CatalogStateMerge.Slice(
            sessions: [persistedSession(id: "local-1")],
            roster: [:],
            projectIDs: ["local-1": "local-project"],
            checkouts: ["local-project": "/local"]
        )
        let remote = try CatalogStateMerge.Slice(
            sessions: [persistedSession(id: "remote-1")],
            roster: [:],
            projectIDs: ["remote-1": "remote-project"],
            checkouts: ["remote-project": "/remote"]
        )

        let merged = CatalogStateMerge.merge(local: local, remotes: [remote])
        #expect(merged.sessions.map(\.id.rawValue) == ["local-1", "remote-1"])
        #expect(merged.projectIDs == [
            "local-1": "local-project",
            "remote-1": "remote-project",
        ])
        #expect(merged.checkouts == [
            "local-project": "/local",
            "remote-project": "/remote",
        ])

        let refreshedLocal = try CatalogStateMerge.Slice(
            sessions: [persistedSession(id: "local-1")],
            roster: [:],
            projectIDs: ["local-1": "local-project"],
            checkouts: ["local-project": "/local"]
        )
        let afterRefresh = CatalogStateMerge.merge(
            local: refreshedLocal,
            remotes: [remote]
        )
        #expect(
            afterRefresh.sessions.map(\.id.rawValue) == ["local-1", "remote-1"]
        )

        let polluted = CatalogStateMerge.merge(
            local: merged,
            remotes: [remote]
        )
        #expect(
            polluted.sessions.map(\.id.rawValue)
                == ["local-1", "remote-1", "remote-1"]
        )
    }

    @Test
    func worktreeCheckoutWritesTheLocalSliceNotTheMergedMap() {
        var local = CatalogStateMerge.Slice(
            checkouts: ["project": "/main"]
        )
        let remote = CatalogStateMerge.Slice(
            checkouts: ["remote-project": "/remote"]
        )
        local.checkouts["project"] = "/main/.worktrees/feature"

        let merged = CatalogStateMerge.merge(local: local, remotes: [remote])
        #expect(merged.checkouts["project"] == "/main/.worktrees/feature")
        #expect(merged.checkouts["remote-project"] == "/remote")
    }
}

@Suite
struct CoordinatorMutationGateTests {
    @Test
    func worktreeTaskDoesNotMutateAfterGenerationChange() {
        #expect(
            CoordinatorMutationGate.allowsMutation(
                capturedGeneration: 1,
                currentGeneration: 1,
                isCancelled: false
            )
        )
        #expect(
            !CoordinatorMutationGate.allowsMutation(
                capturedGeneration: 1,
                currentGeneration: 2,
                isCancelled: false
            )
        )
    }

    @Test
    func cancelledWorktreeTaskDoesNotMutateEvenOnTheSameGeneration() {
        #expect(
            !CoordinatorMutationGate.allowsMutation(
                capturedGeneration: 3,
                currentGeneration: 3,
                isCancelled: true
            )
        )
    }

    @Test
    func detachIncrementsGenerationThenCancelsSoBothChecksFail() {
        let captured = 4
        let afterDetach = captured + 1
        #expect(
            !CoordinatorMutationGate.allowsMutation(
                capturedGeneration: captured,
                currentGeneration: afterDetach,
                isCancelled: true
            )
        )
    }
}

@Suite
struct AvailableRemoteHostAliasesTests {
    @Test
    func cacheFiltersRegisteredAliasesWithoutReadingDisk() {
        let cached = [
            RemoteHostAlias(rawValue: "studio-mac")!,
            RemoteHostAlias(rawValue: "office-mac")!,
        ]
        let registered = [RemoteHostAlias(rawValue: "studio-mac")!]

        #expect(
            AvailableRemoteHostAliases.fromCache(
                cached,
                registered: registered
            ).map(\.rawValue) == ["office-mac"]
        )
    }
}

private func persistedSession(id: String) throws -> GrokPersistedSession {
    try GrokPersistedSession(
        raw: .object([
            "sessionId": .string(id),
            "cwd": .string("/tmp/\(id)"),
        ])
    )
}
