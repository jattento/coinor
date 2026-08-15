import Foundation
import Testing

@testable import Coinor

private func run(
    runID: String = "wf-run-1",
    status: String = "active",
    agentBudget: Int? = nil,
    agentsUsed: Int = 0
) throws -> GrokWorkflowRun {
    var payload: [String: GrokJSONValue] = [
        "run_id": .string(runID),
        "name": "n",
        "status": .string(status),
        "agents_used": .int(agentsUsed),
    ]
    if let agentBudget {
        payload["agent_budget"] = .int(agentBudget)
    }
    return try GrokWorkflowRun(sessionID: "s1", raw: .object(payload))
}

// MARK: - WorkflowLaunchArgumentRow

@Test
func launchArgumentRowDefaultsToAnEmptyKeyAndValueWithAStableIdentity() {
    let row = WorkflowLaunchArgumentRow()
    #expect(row.key.isEmpty)
    #expect(row.value.isEmpty)

    var mutableRow = row
    mutableRow.key = "k"
    #expect(mutableRow.id == row.id)
    #expect(mutableRow != row)
}

// MARK: - WorkflowLaunchDraft: rows

@Test
func draftDefaultsToOneEmptyFieldsRow() {
    let draft = WorkflowLaunchDraft()
    #expect(draft.mode == .fields)
    #expect(draft.rows.count == 1)
    #expect(draft.rows[0].key.isEmpty)
    #expect(draft.rawJSON == "{}")
    #expect(draft.agentBudget == 128)
    #expect(WorkflowLaunchDraft.budgetPresets == [64, 128, 256, 512, 1024])
}

@Test
func addRowAppendsAndRemoveRowDropsByID() {
    var draft = WorkflowLaunchDraft()
    let firstID = draft.rows[0].id
    draft.addRow()
    #expect(draft.rows.count == 2)

    draft.removeRow(id: firstID)
    #expect(draft.rows.count == 1)
    #expect(draft.rows[0].id != firstID)
}

// MARK: - WorkflowLaunchDraft: resolvedArguments, fields mode

@Test
func resolvedArgumentsIgnoresEntirelyEmptyRows() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [WorkflowLaunchArgumentRow(), WorkflowLaunchArgumentRow(key: "  ", value: "  ")]

    let result = draft.resolvedArguments()
    #expect(result == .success(nil))
}

@Test
func resolvedArgumentsFailsWhenAValueHasNoKey() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [WorkflowLaunchArgumentRow(key: "", value: "orphan")]

    #expect(draft.resolvedArguments() == .failure(.missingKey(rowValue: "orphan")))
}

@Test
func resolvedArgumentsFailsOnCaseSensitiveDuplicateKeys() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [
        WorkflowLaunchArgumentRow(key: "target", value: "a"),
        WorkflowLaunchArgumentRow(key: "target", value: "b"),
    ]

    #expect(draft.resolvedArguments() == .failure(.duplicateKey("target")))
}

@Test
func resolvedArgumentsAllowsDuplicateKeysThatDifferOnlyByCase() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [
        WorkflowLaunchArgumentRow(key: "Target", value: "a"),
        WorkflowLaunchArgumentRow(key: "target", value: "b"),
    ]

    let result = draft.resolvedArguments()
    #expect(result == .success(.object(["Target": "a", "target": "b"])))
}

@Test
func resolvedArgumentsTrimsKeysAndPreservesPlainStringValues() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [WorkflowLaunchArgumentRow(key: "  target  ", value: "release-checklist")]

    let result = draft.resolvedArguments()
    #expect(result == .success(.object(["target": "release-checklist"])))
}

@Test
func resolvedArgumentsParsesEveryJSONScalarAndCompositeType() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [
        WorkflowLaunchArgumentRow(key: "n", value: "42"),
        WorkflowLaunchArgumentRow(key: "f", value: "3.5"),
        WorkflowLaunchArgumentRow(key: "t", value: "true"),
        WorkflowLaunchArgumentRow(key: "fls", value: "false"),
        WorkflowLaunchArgumentRow(key: "nul", value: "null"),
        WorkflowLaunchArgumentRow(key: "s", value: "\"quoted\""),
        WorkflowLaunchArgumentRow(key: "arr", value: "[1, 2]"),
        WorkflowLaunchArgumentRow(key: "obj", value: "{\"a\": 1}"),
    ]

    let result = draft.resolvedArguments()
    #expect(result == .success(.object([
        "n": .int(42),
        "f": .double(3.5),
        "t": .bool(true),
        "fls": .bool(false),
        "nul": .null,
        "s": .string("quoted"),
        "arr": .array([.int(1), .int(2)]),
        "obj": .object(["a": .int(1)]),
    ])))
}

@Test
func resolvedArgumentsPreservesNonJSONTextAsAPlainString() {
    var draft = WorkflowLaunchDraft()
    draft.rows = [WorkflowLaunchArgumentRow(key: "note", value: "not-quite json, yeah?")]

    let result = draft.resolvedArguments()
    #expect(result == .success(.object(["note": .string("not-quite json, yeah?")])))
}

// MARK: - WorkflowLaunchDraft: resolvedArguments, raw JSON mode

@Test
func resolvedArgumentsInRawJSONModeReturnsNilForWhitespaceOnlyInput() {
    var draft = WorkflowLaunchDraft()
    draft.mode = .rawJSON
    draft.rawJSON = "   \n  "

    #expect(draft.resolvedArguments() == .success(nil))
}

@Test
func resolvedArgumentsInRawJSONModeAcceptsAnyValidJSONValue() {
    var draft = WorkflowLaunchDraft()
    draft.mode = .rawJSON
    draft.rawJSON = #"{"target": "release-checklist", "count": 3, "tags": ["a", "b"]}"#

    let result = draft.resolvedArguments()
    #expect(result == .success(.object([
        "target": "release-checklist",
        "count": .int(3),
        "tags": .array(["a", "b"]),
    ])))
}

@Test
func resolvedArgumentsInRawJSONModeRejectsInvalidJSONWithAClearMessage() {
    var draft = WorkflowLaunchDraft()
    draft.mode = .rawJSON
    draft.rawJSON = "{not json}"

    guard case let .failure(error) = draft.resolvedArguments() else {
        Issue.record("expected a failure")
        return
    }
    guard case .invalidRawJSON = error else {
        Issue.record("expected .invalidRawJSON, got \(error)")
        return
    }
    #expect(error.errorDescription?.hasPrefix("Raw JSON is invalid:") == true)
}

// MARK: - WorkflowLaunchDraft: agent budget validation

@Test
func validatedAgentBudgetAcceptsEveryPresetAndTheFullRange() {
    for preset in WorkflowLaunchDraft.budgetPresets {
        var draft = WorkflowLaunchDraft()
        draft.agentBudget = preset
        #expect(draft.validatedAgentBudget() == .success(preset))
    }

    var draft = WorkflowLaunchDraft()
    draft.agentBudget = 1
    #expect(draft.validatedAgentBudget() == .success(1))
    draft.agentBudget = 1024
    #expect(draft.validatedAgentBudget() == .success(1024))
}

@Test
func validatedAgentBudgetRejectsOutOfRangeValues() {
    var draft = WorkflowLaunchDraft()
    draft.agentBudget = 0
    #expect(draft.validatedAgentBudget() == .failure(.invalidAgentBudget(0)))

    draft.agentBudget = 1025
    #expect(draft.validatedAgentBudget() == .failure(.invalidAgentBudget(1025)))

    draft.agentBudget = -5
    #expect(draft.validatedAgentBudget() == .failure(.invalidAgentBudget(-5)))
}

// MARK: - WorkflowControlPresentation: suggestedHigherBudget

@Test
func suggestedHigherBudgetIsNilForANonBudgetLimitedRun() throws {
    let activeRun = try run(status: "active", agentBudget: 128, agentsUsed: 3)
    #expect(WorkflowControlPresentation.suggestedHigherBudget(for: activeRun) == nil)
}

@Test
func suggestedHigherBudgetAddsHeadroomAboveTheCurrentBudgetWhenFarFromTheCap() throws {
    let limitedRun = try run(status: "budget_limited", agentBudget: 128, agentsUsed: 128)
    #expect(WorkflowControlPresentation.suggestedHigherBudget(for: limitedRun) == 192)
}

@Test
func suggestedHigherBudgetTracksAgentsUsedWhenItExceedsTheDeclaredBudget() throws {
    let limitedRun = try run(status: "budget_limited", agentBudget: 128, agentsUsed: 300)
    #expect(WorkflowControlPresentation.suggestedHigherBudget(for: limitedRun) == 364)
}

@Test
func suggestedHigherBudgetClampsToTheMaximumNearTheCap() throws {
    let nearCapRun = try run(status: "budget_limited", agentBudget: 1000, agentsUsed: 1000)
    #expect(WorkflowControlPresentation.suggestedHigherBudget(for: nearCapRun) == 1024)
}

@Test
func suggestedHigherBudgetIsNilWhenAgentsUsedIsAlreadyAtTheCap() throws {
    let cappedRun = try run(status: "budget_limited", agentBudget: 1024, agentsUsed: 1024)
    #expect(WorkflowControlPresentation.suggestedHigherBudget(for: cappedRun) == nil)
}

// MARK: - WorkflowControlPresentation: budgetResumeExplanation

@Test
func budgetResumeExplanationDescribesTheSuggestedBudgetWhenResumable() throws {
    let limitedRun = try run(status: "budget_limited", agentBudget: 128, agentsUsed: 128)
    let explanation = try #require(WorkflowControlPresentation.budgetResumeExplanation(for: limitedRun))
    #expect(explanation.contains("192"))
}

@Test
func budgetResumeExplanationDescribesTheHardCapWhenNoHigherBudgetIsPossible() throws {
    let cappedRun = try run(status: "budget_limited", agentBudget: 1024, agentsUsed: 1024)
    let explanation = try #require(WorkflowControlPresentation.budgetResumeExplanation(for: cappedRun))
    #expect(explanation.contains("1024"))
}

@Test
func budgetResumeExplanationCoversNormallyResumableRuns() throws {
    let pausedRun = try run(status: "user_paused")
    #expect(WorkflowControlPresentation.budgetResumeExplanation(for: pausedRun) != nil)
}

@Test
func budgetResumeExplanationIsNilForARunThatCannotResumeAtAll() throws {
    let activeRun = try run(status: "active")
    #expect(WorkflowControlPresentation.budgetResumeExplanation(for: activeRun) == nil)
}
