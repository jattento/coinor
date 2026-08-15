import Foundation

/// One key/value pair a user is editing to build the launch `args` object.
struct WorkflowLaunchArgumentRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// The reason a `WorkflowLaunchDraft` cannot be resolved into launch
/// arguments or an agent budget.
enum WorkflowLaunchDraftError: Equatable, LocalizedError {
    case missingKey(rowValue: String)
    case duplicateKey(String)
    case invalidRawJSON(String)
    case invalidAgentBudget(Int)

    var errorDescription: String? {
        switch self {
        case let .missingKey(rowValue):
            return "Argument value \"\(rowValue)\" needs a key."
        case let .duplicateKey(key):
            return "Argument key \"\(key)\" is used more than once."
        case let .invalidRawJSON(detail):
            return "Raw JSON is invalid: \(detail)"
        case let .invalidAgentBudget(value):
            return "Agent budget \(value) must be between 1 and 1024."
        }
    }
}

/// Draft state for launching a workflow: the pending argument editor plus
/// the agent budget, before it is sent to Grok.
struct WorkflowLaunchDraft: Equatable {
    enum Mode: Equatable {
        case fields
        case rawJSON
    }

    static let budgetPresets = [64, 128, 256, 512, 1024]

    var mode: Mode = .fields
    var rows: [WorkflowLaunchArgumentRow] = [WorkflowLaunchArgumentRow()]
    var rawJSON: String = "{}"
    var agentBudget: Int = 128

    mutating func addRow() {
        rows.append(WorkflowLaunchArgumentRow())
    }

    mutating func removeRow(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Resolves the current mode's input into the `args` value that would be
    /// sent to Grok. `nil` means no `args` should be sent at all.
    func resolvedArguments() -> Result<GrokJSONValue?, WorkflowLaunchDraftError> {
        switch mode {
        case .fields:
            return resolvedFieldArguments()
        case .rawJSON:
            return resolvedRawJSONArguments()
        }
    }

    private func resolvedFieldArguments() -> Result<GrokJSONValue?, WorkflowLaunchDraftError> {
        var members: [String: GrokJSONValue] = [:]
        var orderedKeys: [String] = []

        for row in rows {
            let trimmedKey = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = row.value.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedKey.isEmpty && trimmedValue.isEmpty {
                continue
            }
            if trimmedKey.isEmpty {
                return .failure(.missingKey(rowValue: row.value))
            }
            if orderedKeys.contains(trimmedKey) {
                return .failure(.duplicateKey(trimmedKey))
            }
            orderedKeys.append(trimmedKey)
            members[trimmedKey] = Self.parseFieldValue(trimmedValue, original: row.value)
        }

        if members.isEmpty {
            return .success(nil)
        }
        return .success(.object(members))
    }

    /// Parses a field's value as JSON only when the entire trimmed string is
    /// a valid JSON scalar, array, or object; otherwise the original string
    /// is preserved as-is.
    private static func parseFieldValue(_ trimmedValue: String, original: String) -> GrokJSONValue {
        guard !trimmedValue.isEmpty, let data = trimmedValue.data(using: .utf8) else {
            return .string(original)
        }
        guard let decoded = try? GrokJSONValue.decode(data) else {
            return .string(original)
        }
        return decoded
    }

    private func resolvedRawJSONArguments() -> Result<GrokJSONValue?, WorkflowLaunchDraftError> {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .success(nil)
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.invalidRawJSON("the text could not be read as UTF-8."))
        }
        do {
            return .success(try GrokJSONValue.decode(data))
        } catch {
            return .failure(.invalidRawJSON(error.localizedDescription))
        }
    }

    /// Validates `agentBudget` against the accepted range for a workflow
    /// launch, independent of whether it matches one of `budgetPresets`.
    func validatedAgentBudget() -> Result<Int, WorkflowLaunchDraftError> {
        guard (1...1024).contains(agentBudget) else {
            return .failure(.invalidAgentBudget(agentBudget))
        }
        return .success(agentBudget)
    }
}

/// Pure presentation helpers for the workflow run control surface (pause /
/// resume / stop / raise budget), independent of any view or view model.
enum WorkflowControlPresentation {
    /// The agent budget suggested to resume a budget-limited run, or `nil`
    /// when the run is not eligible for a budget raise or is already at the
    /// maximum allowed budget.
    static func suggestedHigherBudget(for run: GrokWorkflowRun) -> Int? {
        guard run.status == .budgetLimited, run.agentsUsed < 1024 else {
            return nil
        }
        let currentBudget = run.agentBudget ?? run.agentsUsed
        let floor = max(currentBudget, run.agentsUsed)
        let suggested = min(1024, max(currentBudget + 64, run.agentsUsed + 64))
        guard suggested > floor else {
            return nil
        }
        return suggested
    }

    /// English copy explaining what resuming this run will do, for the
    /// resumable and budget-capped cases.
    static func budgetResumeExplanation(for run: GrokWorkflowRun) -> String? {
        if run.status.requiresHigherBudgetToResume {
            guard let suggestion = suggestedHigherBudget(for: run) else {
                return "This run has used its maximum agent budget of 1024 and cannot resume with a higher budget."
            }
            return "This run stopped after using its agent budget. Resume with a higher budget (suggested \(suggestion)) to continue."
        }
        if run.status.canResumeNormally {
            return "Resume this run to continue from where it paused."
        }
        return nil
    }
}
