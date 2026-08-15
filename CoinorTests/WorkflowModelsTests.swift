import Foundation
import Testing

@testable import Coinor

private enum WorkflowFixture {
    static func json(_ name: String) throws -> GrokJSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Grok/\(name).json")
        return try GrokJSONValue.decode(Data(contentsOf: url))
    }
}

private let updatedSessionID = "00000000-0000-7000-8000-000000000001"

private func minimalRunPayload(runID: String = "wf-run-min", status: String = "active") -> GrokJSONValue {
    ["run_id": .string(runID), "name": "minimal", "status": .string(status)]
}

// MARK: - GrokWorkflowDefinition

@Test
func parsesEveryFieldOfEachWorkflowDefinitionKind() throws {
    let payload = try WorkflowFixture.json("workflows-list")
    let rows = try #require(payload["result"]?["workflows"]?.arrayValue)
    let definitions = try rows.map { try GrokWorkflowDefinition(raw: $0) }

    let builtin = try #require(definitions.first { $0.name == "review-changes" })
    #expect(builtin.id == "review-changes")
    #expect(builtin.description == "Fan out a diff review across independent reviewer subagents and merge findings.")
    #expect(builtin.whenToUse == "Use before opening a pull request to catch correctness and style issues in parallel.")
    #expect(builtin.source == .builtin)
    #expect(builtin.path == nil)

    let project = try #require(definitions.first { $0.name == "release-checklist" })
    #expect(project.source == .project)
    #expect(project.path == ".grok/workflows/release-checklist.rhai")

    let user = try #require(definitions.first { $0.name == "personal-notes-triage" })
    #expect(user.source == .user)
    #expect(user.whenToUse == nil)

    let unknownSource = try #require(definitions.first { $0.name == "experimental-fork-only" })
    #expect(unknownSource.source == .unknown("downstream_fork"))
}

@Test
func rejectsAWorkflowDefinitionWithoutAName() {
    #expect(throws: GrokControlError.malformedPayload(
        method: "x.ai/workflows/list",
        detail: "a workflow definition has no name"
    )) {
        _ = try GrokWorkflowDefinition(raw: ["description": "no name"])
    }
}

@Test
func acceptsAWorkflowDefinitionWithUnmodeledAdditiveFields() throws {
    let definition = try GrokWorkflowDefinition(raw: [
        "name": "future-workflow",
        "description": "d",
        "source": "builtin",
        "future_field": "ignored",
    ])
    #expect(definition.name == "future-workflow")
    #expect(definition.raw["future_field"]?.stringValue == "ignored")
}

// MARK: - GrokWorkflowStatus

@Test(arguments: [
    ("active", false, true, false, false, false),
    ("user_paused", false, false, true, false, false),
    ("back_off_paused", false, false, true, false, false),
    ("no_progress_paused", false, false, true, false, false),
    ("infra_paused", false, false, true, false, false),
    ("blocked", false, false, true, false, false),
    ("budget_limited", false, false, false, true, false),
    ("interrupted", true, false, false, false, false),
    ("complete", true, false, false, false, false),
    ("failed", true, false, true, false, false),
    ("cancelled", true, false, false, false, false),
] as [(String, Bool, Bool, Bool, Bool, Bool)])
func statusMatrixMatchesTheGrokTrackerContract(
    _ arguments: (
        wireValue: String,
        isTerminal: Bool,
        canPause: Bool,
        canResumeNormally: Bool,
        requiresHigherBudgetToResume: Bool,
        unused: Bool
    )
) {
    let status = GrokWorkflowStatus(wireValue: arguments.wireValue)
    #expect(status.isTerminal == arguments.isTerminal)
    #expect(status.canPause == arguments.canPause)
    #expect(status.canResumeNormally == arguments.canResumeNormally)
    #expect(status.requiresHigherBudgetToResume == arguments.requiresHigherBudgetToResume)
    // canStop is the inverse of terminal for every known status.
    #expect(status.canStop == !arguments.isTerminal)
}

@Test
func statusDisplayNamesAreEnglishAndUnknownFallsBackToTheWireValue() {
    #expect(GrokWorkflowStatus(wireValue: "active").displayName == "Active")
    #expect(GrokWorkflowStatus(wireValue: "budget_limited").displayName == "Budget limited")
    #expect(GrokWorkflowStatus(wireValue: "some_future_status").displayName == "some_future_status")
    #expect(GrokWorkflowStatus(wireValue: nil).displayName == "Unknown")
}

@Test
func unknownStatusIsNotTerminalAndCannotBeControlled() {
    let status = GrokWorkflowStatus(wireValue: "some_future_status")
    #expect(status.isTerminal == false)
    #expect(status.canPause == false)
    #expect(status.canStop == true)
    #expect(status.canResumeNormally == false)
    #expect(status.requiresHigherBudgetToResume == false)
}

// MARK: - GrokWorkflowRun

@Test
func parsesEveryFieldOfAFullWorkflowRun() throws {
    let envelope = try WorkflowFixture.json("workflow-updated")
    let params = try #require(envelope["params"])
    let update = try #require(params["update"])
    let run = try GrokWorkflowRun(sessionID: updatedSessionID, raw: update)

    #expect(run.sessionID == updatedSessionID)
    #expect(run.runID == "wf-run-4f2c9a")
    #expect(run.id == "wf-run-4f2c9a")
    #expect(run.revision == 7)
    #expect(run.name == "review-changes")
    #expect(run.objective.hasPrefix("Review the outstanding diff"))
    #expect(run.status == .active)
    #expect(run.phases == [
        GrokWorkflowPhase(title: "Plan", state: "complete"),
        GrokWorkflowPhase(title: "Review", state: "active"),
        GrokWorkflowPhase(title: "Summarize", state: "pending"),
    ])
    #expect(run.currentPhase == "Review")
    #expect(run.agentBudget == 128)
    #expect(run.agentsUsed == 3)
    #expect(run.agentsReserved == 1)
    #expect(run.agentsRemaining == 124)
    #expect(run.agentUsageIncomplete == false)
    #expect(run.elapsedMilliseconds == 42150)
    #expect(run.activeAgents == 2)
    #expect(run.currentAgentLabel == "reviewer-2")
    #expect(run.agents.count == 3)
    let reviewer2 = try #require(run.agents.first { $0.id == "agent-2" })
    #expect(reviewer2.label == "reviewer-2")
    #expect(reviewer2.phase == "Review")
    #expect(reviewer2.model == "grok-4")
    #expect(reviewer2.state == "running")
    #expect(reviewer2.tokensUsed == 9021)
    #expect(reviewer2.durationMilliseconds == 8890)
    let testRunner = try #require(run.agents.first { $0.id == "agent-3" })
    #expect(testRunner.model == nil)
    #expect(run.lastEvent == "agent_started")
    #expect(run.lastEventDetail == "reviewer-2 started reviewing Coinor/Domain/WorkflowModels.swift")
    #expect(run.lastEventTimestamp == "2026-08-05T18:21:55.482Z")
    #expect(run.pauseMessage == nil)
    #expect(run.resultSummary == nil)
    #expect(run.raw == update)
}

@Test
func parsesAMinimalWorkflowRunWithEveryOptionalFieldOmitted() throws {
    let run = try GrokWorkflowRun(sessionID: "s1", raw: minimalRunPayload())

    #expect(run.revision == 0)
    #expect(run.objective == "")
    #expect(run.phases.isEmpty)
    #expect(run.currentPhase == nil)
    #expect(run.agentBudget == nil)
    #expect(run.agentsUsed == 0)
    #expect(run.agentsReserved == 0)
    #expect(run.agentsRemaining == nil)
    #expect(run.agentUsageIncomplete == false)
    #expect(run.elapsedMilliseconds == 0)
    #expect(run.activeAgents == 0)
    #expect(run.currentAgentLabel == nil)
    #expect(run.agents.isEmpty)
    #expect(run.lastEvent == nil)
    #expect(run.lastEventDetail == nil)
    #expect(run.lastEventTimestamp == nil)
    #expect(run.pauseMessage == nil)
    #expect(run.resultSummary == nil)
}

@Test
func acceptsAWorkflowRunWithUnmodeledAdditiveFields() throws {
    var payload = minimalRunPayload().objectValue ?? [:]
    payload["future_field"] = "ignored"
    payload["foreground"] = true
    let run = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(run.raw["future_field"]?.stringValue == "ignored")
}

@Test
func dropsAgentAndPhaseRowsMissingRequiredFields() throws {
    var payload = minimalRunPayload().objectValue ?? [:]
    payload["phases"] = [
        ["title": "Plan", "state": "complete"],
        ["title": "Missing state"],
    ]
    payload["agents"] = [
        ["agent_id": "a1", "label": "one", "state": "running"],
        ["agent_id": "a2", "state": "running"],
    ]
    let run = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(run.phases == [GrokWorkflowPhase(title: "Plan", state: "complete")])
    #expect(run.agents.map(\.id) == ["a1"])
}

@Test
func rejectsAWorkflowRunWithoutARunID() {
    #expect(throws: GrokControlError.malformedPayload(
        method: "workflow_updated",
        detail: "a workflow run has no run_id"
    )) {
        _ = try GrokWorkflowRun(sessionID: "s1", raw: ["name": "n", "status": "active"])
    }
}

@Test
func rejectsAWorkflowRunWithoutAName() {
    #expect(throws: GrokControlError.malformedPayload(
        method: "workflow_updated",
        detail: "workflow run wf-1 has no name"
    )) {
        _ = try GrokWorkflowRun(sessionID: "s1", raw: ["run_id": "wf-1", "status": "active"])
    }
}

@Test
func rejectsAWorkflowRunWithoutAStatus() {
    #expect(throws: GrokControlError.malformedPayload(
        method: "workflow_updated",
        detail: "workflow run wf-1 has no status"
    )) {
        _ = try GrokWorkflowRun(sessionID: "s1", raw: ["run_id": "wf-1", "name": "n"])
    }
}

// MARK: - parseNotification / parseSnapshotRow shared parser

@Test
func parsesAWorkflowUpdatedSessionNotification() throws {
    let envelope = try WorkflowFixture.json("workflow-updated")
    let method = try #require(envelope["method"]?.stringValue)
    let params = try #require(envelope["params"])
    let normalized = GrokMethod.normalize(wireMethod: method, params: params)

    let run = try #require(GrokWorkflowRun.parseNotification(method: normalized.method, params: normalized.params))
    #expect(run.runID == "wf-run-4f2c9a")
    #expect(run.sessionID == updatedSessionID)
}

@Test
func parsesAWorkflowUpdatedSessionUpdateXaiWireMethod() throws {
    let params: GrokJSONValue = [
        "session_id": .string(updatedSessionID),
        "update": minimalRunPayloadWithDiscriminator(),
    ]
    let run = try #require(GrokWorkflowRun.parseNotification(method: "x.ai/session/update", params: params))
    #expect(run.runID == "wf-run-min")
    #expect(run.sessionID == updatedSessionID)
}

@Test
func parsesAWorkflowUpdatedPlainSessionUpdateWireMethod() throws {
    let params: GrokJSONValue = [
        "sessionId": .string(updatedSessionID),
        "update": minimalRunPayloadWithDiscriminator(),
    ]
    let run = try #require(GrokWorkflowRun.parseNotification(method: "session/update", params: params))
    #expect(run.runID == "wf-run-min")
}

@Test
func returnsNilForANotificationWithAnUnsupportedMethod() {
    let params: GrokJSONValue = [
        "sessionId": .string(updatedSessionID),
        "update": minimalRunPayloadWithDiscriminator(),
    ]
    #expect(GrokWorkflowRun.parseNotification(method: "x.ai/leader_reconnected", params: params) == nil)
}

@Test
func returnsNilForANonWorkflowSessionUpdate() {
    let params: GrokJSONValue = [
        "sessionId": .string(updatedSessionID),
        "update": ["sessionUpdate": "turn_ended"],
    ]
    #expect(GrokWorkflowRun.parseNotification(method: "x.ai/session_notification", params: params) == nil)
}

@Test
func returnsNilForANotificationWithoutASessionID() {
    let params: GrokJSONValue = ["update": minimalRunPayloadWithDiscriminator()]
    #expect(GrokWorkflowRun.parseNotification(method: "x.ai/session_notification", params: params) == nil)
}

@Test
func returnsNilForANotificationWithAMalformedRunPayload() {
    let params: GrokJSONValue = [
        "sessionId": .string(updatedSessionID),
        "update": ["sessionUpdate": "workflow_updated", "name": "n", "status": "active"],
    ]
    #expect(GrokWorkflowRun.parseNotification(method: "x.ai/session_notification", params: params) == nil)
}

@Test
func parseSnapshotRowSharesTheSameRunPayloadParserAsNotifications() throws {
    let payload = try WorkflowFixture.json("workflows-snapshot")
    let sessionID = try #require(payload["result"]?["sessionId"]?.stringValue)
    let rows = try #require(payload["result"]?["runs"]?.arrayValue)

    let runs = try rows.map { try GrokWorkflowRun.parseSnapshotRow(sessionID: sessionID, raw: $0) }
    #expect(runs.count == 3)

    let completed = try #require(runs.first { $0.runID == "wf-run-4f2c9a" })
    #expect(completed.status == .complete)
    #expect(completed.resultSummary == "No blocking issues found; two style nits filed as follow-ups.")

    let budgetLimited = try #require(runs.first { $0.runID == "wf-run-9b71ee" })
    #expect(budgetLimited.status == .budgetLimited)
    #expect(budgetLimited.status.requiresHigherBudgetToResume)
    #expect(budgetLimited.agentBudget == 1024)
    #expect(budgetLimited.agentsUsed == 1024)
    #expect(budgetLimited.agentsRemaining == 0)
    #expect(budgetLimited.agentUsageIncomplete)
    #expect(budgetLimited.pauseMessage == "Resume with a higher agentBudget to continue.")

    let minimal = try #require(runs.first { $0.runID == "wf-run-legacy-minimal" })
    #expect(minimal.status == .failed)
    #expect(minimal.status.canResumeNormally)
    #expect(minimal.agents.isEmpty)
}

@Test
func parseSnapshotRowThrowsOnAMalformedRow() {
    #expect(throws: GrokControlError.malformedPayload(
        method: "workflow_updated",
        detail: "a workflow run has no run_id"
    )) {
        _ = try GrokWorkflowRun.parseSnapshotRow(sessionID: "s1", raw: ["name": "n", "status": "active"])
    }
}

private func minimalRunPayloadWithDiscriminator() -> GrokJSONValue {
    ["sessionUpdate": "workflow_updated", "run_id": "wf-run-min", "name": "minimal", "status": "active"]
}

// MARK: - GrokWorkflowRunStore

@Test
func applyStoresTheFirstRevisionOfANewRun() throws {
    var store = GrokWorkflowRunStore()
    let run = try GrokWorkflowRun(sessionID: "s1", raw: minimalRunPayload())
    #expect(store.apply(run) == true)
    #expect(store.runsByID["wf-run-min"] == run)
}

@Test
func applyAcceptsAStrictlyNewerRevisionAndRejectsStaleOrEqualRevisions() throws {
    var store = GrokWorkflowRunStore()
    var payload = minimalRunPayload().objectValue ?? [:]
    payload["revision"] = 5
    let revision5 = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(store.apply(revision5) == true)

    payload["revision"] = 5
    payload["status"] = "complete"
    let equalRevision = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(store.apply(equalRevision) == false)
    #expect(store.runsByID["wf-run-min"]?.status == .active)

    payload["revision"] = 3
    let staleRevision = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(store.apply(staleRevision) == false)
    #expect(store.runsByID["wf-run-min"]?.status == .active)

    payload["revision"] = 6
    let newerRevision = try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
    #expect(store.apply(newerRevision) == true)
    #expect(store.runsByID["wf-run-min"]?.status == .complete)
}

@Test
func runsForSessionAreSortedByNewestEventThenRunID() throws {
    var store = GrokWorkflowRunStore()
    for (runID, revision, timestamp, sessionID) in [
        ("wf-b", 30, "2026-08-15T10:00:00.000Z", "s1"),
        ("wf-a", 3, "2026-08-15T10:00:00.000Z", "s1"),
        ("wf-c", 1, "2026-08-15T11:00:00.000Z", "s1"),
        ("wf-other-session", 100, "2026-08-15T12:00:00.000Z", "s2"),
    ] {
        var payload = minimalRunPayload(runID: runID).objectValue ?? [:]
        payload["revision"] = .int(revision)
        payload["last_event_timestamp"] = .string(timestamp)
        store.apply(try GrokWorkflowRun(sessionID: sessionID, raw: .object(payload)))
    }

    let ordered = store.runs(sessionID: "s1").map(\.runID)
    #expect(ordered == ["wf-c", "wf-a", "wf-b"])
    #expect(store.runs(sessionID: "s2").map(\.runID) == ["wf-other-session"])
    #expect(store.runs(sessionID: "unknown").isEmpty)
}
