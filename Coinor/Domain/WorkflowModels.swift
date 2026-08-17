import Foundation

/// The wire method Coinor reads workflow run updates from. `x.ai/workflows/list`
/// (the definition catalog) is not modeled here because these types cover
/// launched runs, not the catalog of scripts a run can be started from.
private enum GrokWorkflowWireMethod {
    static let sessionNotification = "x.ai/session_notification"
    static let sessionUpdateXai = "x.ai/session/update"
    static let sessionUpdatePlain = "session/update"
}

struct GrokWorkflowLaunchResult: Sendable, Equatable {
    let runID: String
    let name: String
}

enum GrokWorkflowControlOperation: String, Sendable {
    case pause
    case resume
    case stop
}

/// One entry from Grok's workflow catalog, `x.ai/workflows/list`.
///
/// A definition is a launchable script, not a running instance; `GrokWorkflowRun`
/// is the live/finished execution of one.
///
/// The wire protocol to Grok only ever carries the plain `name`
/// (`GrokControlClient.launchWorkflow`); the composite `id` is Coinor-local
/// selection identity so two same-named definitions from different origins
/// stay separately selectable, and it never feeds a Grok request.
struct GrokWorkflowDefinition: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case project
        case user
        case builtin
        case unknown(String)

        init(wireValue: String?) {
            switch wireValue {
            case "project": self = .project
            case "user": self = .user
            case "builtin": self = .builtin
            case let other?: self = .unknown(other)
            case nil: self = .unknown("")
            }
        }

        /// The stable origin prefix of a definition's composite identity.
        var identityPrefix: String {
            switch self {
            case .project: return "project"
            case .user: return "user"
            case .builtin: return "builtin"
            case .unknown(let value): return "unknown-\(value.isEmpty ? "unspecified" : value)"
            }
        }
    }

    /// Coinor-local selection identity: origin + path, falling back to
    /// origin + name when the definition has no path. Distinct from `name`,
    /// which is what launching sends to Grok, so same-named definitions from
    /// different origins remain separately selectable.
    var id: String {
        let location = path.flatMap { $0.isEmpty ? nil : $0 } ?? name
        return "\(source.identityPrefix):\(location) (\(name))"
    }

    let name: String
    let description: String?
    let whenToUse: String?
    let source: Source
    let path: String?
    let raw: GrokJSONValue

    init(raw: GrokJSONValue) throws {
        guard let name = raw["name"]?.stringValue, !name.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: "x.ai/workflows/list",
                detail: "a workflow definition has no name"
            )
        }
        self.name = name
        description = raw["description"]?.stringValue
        whenToUse = raw["when_to_use"]?.stringValue ?? raw["whenToUse"]?.stringValue
        source = Source(wireValue: raw["source"]?.stringValue)
        path = raw["path"]?.stringValue
        self.raw = raw
    }
}

/// The lifecycle status of one workflow run, as Grok's tracker reports it.
///
/// Mirrors `WorkflowRunStatus` in the local Grok fork
/// (`session/workflow/tracker.rs`) exactly; `.unknown` absorbs any future
/// value so an additive status never fails decoding.
enum GrokWorkflowStatus: Sendable, Equatable {
    case active
    case userPaused
    case backOffPaused
    case noProgressPaused
    case infraPaused
    case blocked
    case budgetLimited
    case interrupted
    case complete
    case failed
    case cancelled
    case unknown(String)

    init(wireValue: String?) {
        switch wireValue {
        case "active": self = .active
        case "user_paused": self = .userPaused
        case "back_off_paused": self = .backOffPaused
        case "no_progress_paused": self = .noProgressPaused
        case "infra_paused": self = .infraPaused
        case "blocked": self = .blocked
        case "budget_limited": self = .budgetLimited
        case "interrupted": self = .interrupted
        case "complete": self = .complete
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    /// English label suitable for direct display in the UI.
    var displayName: String {
        switch self {
        case .active: return "Active"
        case .userPaused: return "Paused"
        case .backOffPaused: return "Paused (backing off)"
        case .noProgressPaused: return "Paused (no progress)"
        case .infraPaused: return "Paused (infrastructure)"
        case .blocked: return "Blocked"
        case .budgetLimited: return "Budget limited"
        case .interrupted: return "Interrupted"
        case .complete: return "Complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case let .unknown(value): return value.isEmpty ? "Unknown" : value
        }
    }

    /// Whether the run has finished and will never change state again.
    ///
    /// Matches `WorkflowRunStatus::is_terminal` in the fork: budget-limited
    /// is a pause, not a terminal state, because a raised budget can resume it.
    var isTerminal: Bool {
        switch self {
        case .interrupted, .complete, .failed, .cancelled: return true
        default: return false
        }
    }

    /// Whether a pause control is currently valid for this run.
    var canPause: Bool { self == .active }

    /// Whether a stop control is currently valid for this run.
    var canStop: Bool { !isTerminal }

    /// Whether resume is available without also raising the agent budget.
    ///
    /// Mirrors `WorkflowRunStatus::is_resumable` (`is_paused() || Failed`) in
    /// the fork, minus budget-limited: that pause always requires a raised
    /// budget, tracked separately by `requiresHigherBudgetToResume`.
    var canResumeNormally: Bool {
        switch self {
        case .userPaused, .backOffPaused, .noProgressPaused, .infraPaused, .blocked, .failed:
            return true
        default:
            return false
        }
    }

    /// Whether resume requires a higher agent budget than the run already used.
    var requiresHigherBudgetToResume: Bool { self == .budgetLimited }
}

/// One phase of a workflow run's declared plan.
struct GrokWorkflowPhase: Sendable, Equatable {
    let title: String
    let state: String
}

/// One child agent a workflow run has spawned or is tracking.
struct GrokWorkflowAgent: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let phase: String?
    let model: String?
    let state: String
    let tokensUsed: Int
    let durationMilliseconds: Int
}

/// One workflow run, as reported by a `workflow_updated` session update or a
/// structured snapshot row built from the same payload.
struct GrokWorkflowRun: Identifiable, Sendable, Equatable {
    let sessionID: String
    let runID: String
    var id: String { runID }
    let revision: Int
    let name: String
    let objective: String
    let status: GrokWorkflowStatus
    let phases: [GrokWorkflowPhase]
    let currentPhase: String?
    let agentBudget: Int?
    let agentsUsed: Int
    let agentsReserved: Int
    let agentsRemaining: Int?
    let agentUsageIncomplete: Bool
    let elapsedMilliseconds: Int
    let activeAgents: Int
    let currentAgentLabel: String?
    let agents: [GrokWorkflowAgent]
    let lastEvent: String?
    let lastEventDetail: String?
    let lastEventTimestamp: String?
    let pauseMessage: String?
    let resultSummary: String?
    let raw: GrokJSONValue

    init(sessionID: String, raw: GrokJSONValue) throws {
        guard let runID = raw["run_id"]?.stringValue, !runID.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: "workflow_updated",
                detail: "a workflow run has no run_id"
            )
        }
        guard let name = raw["name"]?.stringValue, !name.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: "workflow_updated",
                detail: "workflow run \(runID) has no name"
            )
        }
        guard let statusWireValue = raw["status"]?.stringValue, !statusWireValue.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: "workflow_updated",
                detail: "workflow run \(runID) has no status"
            )
        }

        self.sessionID = sessionID
        self.runID = runID
        revision = raw["revision"]?.intValue ?? 0
        self.name = name
        objective = raw["objective"]?.stringValue ?? ""
        status = GrokWorkflowStatus(wireValue: statusWireValue)
        phases = (raw["phases"]?.arrayValue ?? []).compactMap { phase in
            guard let title = phase["title"]?.stringValue,
                  let state = phase["state"]?.stringValue else { return nil }
            return GrokWorkflowPhase(title: title, state: state)
        }
        currentPhase = raw["current_phase"]?.stringValue
        agentBudget = raw["agent_budget"]?.intValue
        agentsUsed = raw["agents_used"]?.intValue ?? 0
        agentsReserved = raw["agents_reserved"]?.intValue ?? 0
        agentsRemaining = raw["agents_remaining"]?.intValue
        agentUsageIncomplete = raw["agent_usage_incomplete"]?.boolValue ?? false
        elapsedMilliseconds = raw["elapsed_ms"]?.intValue ?? 0
        activeAgents = raw["active_agents"]?.intValue ?? 0
        currentAgentLabel = raw["current_agent_label"]?.stringValue
        agents = (raw["agents"]?.arrayValue ?? []).compactMap { agent in
            guard let agentID = agent["agent_id"]?.stringValue,
                  let label = agent["label"]?.stringValue,
                  let state = agent["state"]?.stringValue else { return nil }
            return GrokWorkflowAgent(
                id: agentID,
                label: label,
                phase: agent["phase"]?.stringValue,
                model: agent["model"]?.stringValue,
                state: state,
                tokensUsed: agent["tokens_used"]?.intValue ?? 0,
                durationMilliseconds: agent["duration_ms"]?.intValue ?? 0
            )
        }
        lastEvent = raw["last_event"]?.stringValue
        lastEventDetail = raw["last_event_detail"]?.stringValue
        lastEventTimestamp = raw["last_event_timestamp"]?.stringValue
        pauseMessage = raw["pause_message"]?.stringValue
        resultSummary = raw["result_summary"]?.stringValue
        self.raw = raw
    }

    /// Parses a `workflow_updated` session update, arriving either as
    /// `x.ai/session_notification`, `x.ai/session/update`, or the plain ACP
    /// `session/update` (already unwrapped from the extension envelope).
    static func parseNotification(
        method: String,
        params: GrokJSONValue
    ) -> GrokWorkflowRun? {
        guard method == GrokWorkflowWireMethod.sessionNotification
                || method == GrokWorkflowWireMethod.sessionUpdateXai
                || method == GrokWorkflowWireMethod.sessionUpdatePlain else {
            return nil
        }
        guard let sessionID = firstString(in: params, keys: ["sessionId", "session_id"]),
              !sessionID.isEmpty else {
            return nil
        }
        let update = params["update"] ?? params
        guard update["sessionUpdate"]?.stringValue == "workflow_updated" else {
            return nil
        }
        return try? GrokWorkflowRun(sessionID: sessionID, raw: update)
    }

    /// Parses one row of a structured workflow snapshot (`workflow_snapshot`
    /// style responses), which is the same run payload minus the live
    /// notification's `sessionUpdate` discriminator.
    static func parseSnapshotRow(sessionID: String, raw: GrokJSONValue) throws -> GrokWorkflowRun {
        try GrokWorkflowRun(sessionID: sessionID, raw: raw)
    }

    private static func firstString(in value: GrokJSONValue, keys: [String]) -> String? {
        keys.lazy.compactMap { value[$0]?.stringValue }.first
    }
}

/// A revision-gated store of workflow runs.
///
/// Grok's `workflow_updated` notifications carry a monotonically increasing
/// `revision` per run; an update at or below the currently stored revision is
/// a stale replay (e.g. a duplicate broadcast) and must not overwrite newer
/// state.
struct GrokWorkflowRunStore: Sendable, Equatable {
    private(set) var runsByID: [String: GrokWorkflowRun] = [:]

    init() {}

    /// Applies a run update if its revision is newer than (or the first
    /// revision for) the stored run. Returns whether the store changed.
    @discardableResult
    mutating func apply(_ run: GrokWorkflowRun) -> Bool {
        if let existing = runsByID[run.runID], run.revision <= existing.revision {
            return false
        }
        runsByID[run.runID] = run
        return true
    }

    /// Runs belonging to one session, newest event first. Revisions are only
    /// comparable within one run, so run ID breaks missing/equal timestamp
    /// ties for a stable order.
    func runs(sessionID: String) -> [GrokWorkflowRun] {
        runsByID.values
            .filter { $0.sessionID == sessionID }
            .sorted { lhs, rhs in
                switch (lhs.lastEventTimestamp, rhs.lastEventTimestamp) {
                case let (lhsTimestamp?, rhsTimestamp?) where lhsTimestamp != rhsTimestamp:
                    return lhsTimestamp > rhsTimestamp
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.runID < rhs.runID
                }
            }
    }
}
