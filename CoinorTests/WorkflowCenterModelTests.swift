import Foundation
import Testing

@testable import Coinor

@MainActor
private enum ModelFixture {
    static func definition(
        name: String,
        source: String,
        description: String? = nil,
        whenToUse: String? = nil
    ) -> GrokWorkflowDefinition {
        var raw: [String: GrokJSONValue] = [
            "name": .string(name),
            "source": .string(source),
        ]
        if let description { raw["description"] = .string(description) }
        if let whenToUse { raw["when_to_use"] = .string(whenToUse) }
        return try! GrokWorkflowDefinition(raw: .object(raw))
    }

    static func run(
        sessionID: String,
        runID: String,
        revision: Int = 0,
        status: String = "active",
        lastEventTimestamp: String? = nil
    ) -> GrokWorkflowRun {
        var raw: [String: GrokJSONValue] = [
            "run_id": .string(runID),
            "name": "review-changes",
            "status": .string(status),
            "revision": .int(revision),
        ]
        if let lastEventTimestamp {
            raw["last_event_timestamp"] = .string(lastEventTimestamp)
        }
        return try! GrokWorkflowRun(sessionID: sessionID, raw: .object(raw))
    }
}

// MARK: - No context

@Test @MainActor
func startsWithNoContext() {
    let model = WorkflowCenterModel()
    #expect(model.context == nil)
    #expect(model.definitions.isEmpty)
    #expect(model.visibleRuns.isEmpty)
    #expect(model.catalogState == .idle)
    #expect(model.runsState == .idle)
}

@Test @MainActor
func enterNoContextClearsAnExistingContextAndSelectionsButKeepsTheRunStore() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "Fix the bug",
        projectTitle: "coinor",
        remoteHostTitle: nil
    )
    model.completeRunsLoad(
        generation: generation,
        sessionID: "s1",
        runs: [ModelFixture.run(sessionID: "s1", runID: "r1")]
    )
    #expect(model.selectedRunID == "r1")

    model.enterNoContext()

    #expect(model.context == nil)
    #expect(model.selectedRunID == nil)
    #expect(model.selectedDefinitionID == nil)
    #expect(model.catalogState == .idle)
    #expect(model.runsState == .idle)
    // The store itself is untouched; only the current context's view of it is
    // cleared, since visibleRuns requires a context.
    #expect(model.runStore.runs(sessionID: "s1").count == 1)
}

// MARK: - Context subtitle

@Test @MainActor
func contextSubtitleOmitsARemoteHostWhenThereIsNone() {
    let model = WorkflowCenterModel()
    _ = model.beginContext(
        sessionID: "s1",
        conversationTitle: "Fix the bug",
        projectTitle: "coinor",
        remoteHostTitle: nil
    )
    #expect(model.context?.subtitle == "coinor")
}

@Test @MainActor
func contextSubtitleIncludesARemoteHostWhenPresent() {
    let model = WorkflowCenterModel()
    _ = model.beginContext(
        sessionID: "s1",
        conversationTitle: "Fix the bug",
        projectTitle: "coinor",
        remoteHostTitle: "build-box"
    )
    #expect(model.context?.subtitle == "coinor · build-box")
}

// MARK: - Grouping and search

@Test @MainActor
func definitionGroupsAreOrderedProjectUserBuiltinUnknownWithStableNameSorting() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    let definitions = [
        ModelFixture.definition(name: "zebra-check", source: "builtin"),
        ModelFixture.definition(name: "apple-check", source: "builtin"),
        ModelFixture.definition(name: "release-checklist", source: "project"),
        ModelFixture.definition(name: "personal-notes", source: "user"),
        ModelFixture.definition(name: "fork-only", source: "downstream_fork"),
    ]
    model.completeCatalogLoad(generation: generation, sessionID: "s1", definitions: definitions)

    let groups = model.definitionGroups(matching: "")
    #expect(groups.map(\.title) == ["Project", "Personal", "Built-in", "Other"])
    let builtin = try! #require(groups.first { $0.title == "Built-in" })
    #expect(builtin.definitions.map(\.name) == ["apple-check", "zebra-check"])
}

@Test @MainActor
func definitionGroupsSearchIsCaseInsensitiveAcrossNameDescriptionAndWhenToUse() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    let definitions = [
        ModelFixture.definition(name: "review-changes", source: "builtin", description: "Fan out a diff review"),
        ModelFixture.definition(name: "release-checklist", source: "project", whenToUse: "Before a Release"),
        ModelFixture.definition(name: "personal-notes-triage", source: "user"),
    ]
    model.completeCatalogLoad(generation: generation, sessionID: "s1", definitions: definitions)

    #expect(model.definitionGroups(matching: "DIFF").flatMap(\.definitions).map(\.name) == ["review-changes"])
    #expect(model.definitionGroups(matching: "release").flatMap(\.definitions).map(\.name) == ["release-checklist"])
    #expect(model.definitionGroups(matching: "nothing-matches").isEmpty)
}

// MARK: - Generation guard

@Test @MainActor
func aStaleGenerationCompletionIsIgnored() {
    let model = WorkflowCenterModel()
    let firstGeneration = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    // Superseded by a second beginContext before the first load answers.
    _ = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )

    model.completeCatalogLoad(
        generation: firstGeneration,
        sessionID: "s1",
        definitions: [ModelFixture.definition(name: "stale", source: "builtin")]
    )

    #expect(model.definitions.isEmpty)
    #expect(model.catalogState == .idle)
}

// MARK: - Session switch

@Test @MainActor
func switchingSessionsFiltersVisibleRunsButPreservesTheStoreForOtherSessions() {
    let model = WorkflowCenterModel()
    let generation1 = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t1",
        projectTitle: "p1",
        remoteHostTitle: nil
    )
    model.completeRunsLoad(
        generation: generation1,
        sessionID: "s1",
        runs: [ModelFixture.run(sessionID: "s1", runID: "r1")]
    )
    #expect(model.visibleRuns.map(\.id) == ["r1"])

    let generation2 = model.beginContext(
        sessionID: "s2",
        conversationTitle: "t2",
        projectTitle: "p2",
        remoteHostTitle: nil
    )
    model.completeRunsLoad(
        generation: generation2,
        sessionID: "s2",
        runs: [ModelFixture.run(sessionID: "s2", runID: "r2")]
    )

    #expect(model.visibleRuns.map(\.id) == ["r2"])
    #expect(model.runStore.runs(sessionID: "s1").map(\.id) == ["r1"])
}

// MARK: - Stale revisions

@Test @MainActor
func ingestIgnoresARunAtOrBelowTheStoredRevision() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.completeRunsLoad(
        generation: generation,
        sessionID: "s1",
        runs: [ModelFixture.run(sessionID: "s1", runID: "r1", revision: 5, status: "active")]
    )
    model.ingest(ModelFixture.run(sessionID: "s1", runID: "r1", revision: 5, status: "complete"))
    #expect(model.visibleRuns.first?.status == .active)

    model.ingest(ModelFixture.run(sessionID: "s1", runID: "r1", revision: 6, status: "complete"))
    #expect(model.visibleRuns.first?.status == .complete)
}

@Test @MainActor
func completeRunsLoadSelectsTheNewestVisibleRunByEventTimestamp() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.completeRunsLoad(
        generation: generation,
        sessionID: "s1",
        runs: [
            ModelFixture.run(
                sessionID: "s1",
                runID: "older-high-revision",
                revision: 40,
                lastEventTimestamp: "2026-08-15T10:00:00.000Z"
            ),
            ModelFixture.run(
                sessionID: "s1",
                runID: "newer-low-revision",
                revision: 1,
                lastEventTimestamp: "2026-08-15T11:00:00.000Z"
            ),
        ]
    )
    #expect(model.visibleRuns.map(\.runID) == [
        "newer-low-revision",
        "older-high-revision",
    ])
    #expect(model.selectedRunID == "newer-low-revision")
}

// MARK: - Defaults

@Test @MainActor
func catalogDefaultSelectionPrefersProjectThenUserThenBuiltin() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.completeCatalogLoad(
        generation: generation,
        sessionID: "s1",
        definitions: [
            ModelFixture.definition(name: "builtin-one", source: "builtin"),
            ModelFixture.definition(name: "user-one", source: "user"),
        ]
    )
    #expect(model.selectedDefinitionID == "user-one")

    let generation2 = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.completeCatalogLoad(
        generation: generation2,
        sessionID: "s1",
        definitions: [
            ModelFixture.definition(name: "builtin-one", source: "builtin"),
            ModelFixture.definition(name: "user-one", source: "user"),
            ModelFixture.definition(name: "project-one", source: "project"),
        ]
    )
    #expect(model.selectedDefinitionID == "project-one")
}

@Test @MainActor
func catalogDefaultSelectionFallsBackToNilWhenOnlyUnknownSourcesExist() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.completeCatalogLoad(
        generation: generation,
        sessionID: "s1",
        definitions: [ModelFixture.definition(name: "fork-only", source: "downstream_fork")]
    )
    #expect(model.selectedDefinitionID == nil)
}

// MARK: - Partial load failure

@Test @MainActor
func aCatalogFailureDoesNotAffectRunsState() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.beginCatalogLoad(generation: generation, sessionID: "s1")
    model.beginRunsLoad(generation: generation, sessionID: "s1")
    model.failCatalogLoad(generation: generation, sessionID: "s1", error: "boom")
    model.completeRunsLoad(
        generation: generation,
        sessionID: "s1",
        runs: [ModelFixture.run(sessionID: "s1", runID: "r1")]
    )

    #expect(model.catalogState == .failed("boom"))
    #expect(model.runsState == .loaded)
    #expect(model.visibleRuns.map(\.id) == ["r1"])
}

// MARK: - Action lifecycle

@Test @MainActor
func beginActionClearsAPreviousErrorAndEndActionOnlyClearsItsOwnAction() {
    let model = WorkflowCenterModel()
    let generation = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t",
        projectTitle: "p",
        remoteHostTitle: nil
    )
    model.beginAction("launch:review-changes", generation: generation, sessionID: "s1")
    model.failAction(
        "launch:review-changes",
        generation: generation,
        sessionID: "s1",
        error: "network down"
    )
    #expect(model.actionError == "network down")
    #expect(model.activeAction == nil)

    model.beginAction("control:r1:pause", generation: generation, sessionID: "s1")
    #expect(model.actionError == nil)
    #expect(model.activeAction == "control:r1:pause")

    model.endAction("control:r1:resume", generation: generation, sessionID: "s1")
    #expect(model.activeAction == "control:r1:pause")

    model.endAction("control:r1:pause", generation: generation, sessionID: "s1")
    #expect(model.activeAction == nil)
}

@Test @MainActor
func staleActionFailureCannotOverwriteANewerActionOrContext() {
    let model = WorkflowCenterModel()
    let generation1 = model.beginContext(
        sessionID: "s1",
        conversationTitle: "t1",
        projectTitle: "p1",
        remoteHostTitle: nil
    )
    model.beginAction("launch:a", generation: generation1, sessionID: "s1")
    model.beginAction("launch:b", generation: generation1, sessionID: "s1")
    model.failAction(
        "launch:a",
        generation: generation1,
        sessionID: "s1",
        error: "superseded action failed"
    )
    #expect(model.actionError == nil)
    #expect(model.activeAction == "launch:b")

    _ = model.beginContext(
        sessionID: "s2",
        conversationTitle: "t2",
        projectTitle: "p2",
        remoteHostTitle: nil
    )
    model.failAction(
        "launch:b",
        generation: generation1,
        sessionID: "s1",
        error: "abandoned context failed"
    )
    #expect(model.actionError == nil)
    #expect(model.activeAction == nil)
}
