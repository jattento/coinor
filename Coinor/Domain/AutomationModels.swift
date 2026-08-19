import Foundation

/// A single configured automation: a cron schedule, a project, a model and a
/// prompt that each firing turns into a brand-new Grok session.
///
/// Conan Code owns this configuration; launchd owns the schedule (one job per
/// automation) and `grok` owns the execution and the resulting session.
struct Automation: Identifiable, Equatable, Sendable, Codable {
    /// Stable identity, also used as the suffix of the launchd job label.
    var id: String
    var name: String
    /// Five-field cron expression (see `CronSchedule`), compiled into launchd
    /// calendar intervals when the job is installed.
    var schedule: String
    /// The checkout the run executes in. Empty means the automation has not
    /// picked a project yet and is therefore not scheduled.
    var workingDirectory: String
    var prompt: String
    /// The Grok model this automation runs on. `nil` uses Grok's configured
    /// default, so an automation created before the field existed keeps
    /// working unchanged.
    var model: String?
    /// How hard the model is asked to think. `nil` leaves Grok's own default
    /// for the model, which is what every automation used before the field
    /// existed.
    var reasoningEffort: AutomationReasoningEffort?
    /// A paused automation keeps its configuration but its launchd job is
    /// unloaded, so it neither fires on schedule nor catches up on wake.
    var isPaused: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        schedule: String,
        workingDirectory: String = "",
        prompt: String = "",
        model: String? = nil,
        reasoningEffort: AutomationReasoningEffort? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.isPaused = isPaused
    }
}

/// The reasoning effort levels `grok --reasoning-effort` accepts.
///
/// Grok owns which levels a given model honours; Conan Code only offers the
/// documented set and passes the choice through unchanged.
enum AutomationReasoningEffort: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Maximum"
        }
    }
}

/// The lifecycle outcome of one automation run.
enum AutomationRunStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
}

/// How a run was started, for display in the run list.
enum AutomationTrigger: String, Codable, Equatable, Sendable {
    case scheduled
    case forced
}

/// One execution of an automation: an independent, brand-new Grok session.
///
/// The conversation itself lives in Grok. This record is the local bookkeeping
/// that ties that session back to the automation which spawned it, and it is
/// reconstructed from the append-only run log the launchd jobs write.
struct AutomationRun: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var automationID: String
    /// The Grok session the run created, so the UI can open the conversation
    /// and the sidebar can badge it as an automation run.
    var sessionID: String?
    var trigger: AutomationTrigger
    var status: AutomationRunStatus
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?

    init(
        id: String = UUID().uuidString,
        automationID: String,
        sessionID: String? = nil,
        trigger: AutomationTrigger = .scheduled,
        status: AutomationRunStatus = .running,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.sessionID = sessionID
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }
}

/// The single instruction appended to every automation's prompt, so one
/// editable preamble explains "you are part of an automation: do not ask the
/// user for clarification".
struct AutomationSettings: Equatable, Sendable, Codable {
    var systemPrompt: String

    static let `default` = AutomationSettings(
        systemPrompt: """
        You are running as part of an automated workflow managed by Conan Code.
        Work autonomously: do not ask the user for clarification at any point.
        Make reasonable assumptions and proceed. When you need to make a
        choice, pick the safest default and note it. Run to completion and
        report what you did concisely before finishing.
        """
    )
}

/// The automation slice of the metadata document.
///
/// Only configuration lives here. Run history is reconstructed from the run
/// log the launchd jobs append to, and the schedule itself lives in launchd.
struct AutomationState: Equatable, Sendable, Codable {
    var settings: AutomationSettings?
    var automations: [String: Automation]
    /// Runs whose Grok session has already been titled after its automation.
    ///
    /// Titling happens once per run so a conversation the user renamed by hand
    /// is never overwritten on the next refresh. Oldest entries are pruned.
    var titledRunIDs: [String]

    static let empty = AutomationState(
        settings: nil,
        automations: [:],
        titledRunIDs: []
    )

    /// Keeps the persisted list bounded; runs age out long before this.
    static let titledRunHistoryLimit = 400
}

extension AutomationState {
    private enum CodingKeys: String, CodingKey {
        case settings, automations, titledRunIDs
    }

    /// Decodes leniently so a document written before run titling existed
    /// still parses.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decodeIfPresent(
            AutomationSettings.self,
            forKey: .settings
        )
        automations = try container.decodeIfPresent(
            [String: Automation].self,
            forKey: .automations
        ) ?? [:]
        titledRunIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .titledRunIDs
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encode(automations, forKey: .automations)
        if !titledRunIDs.isEmpty {
            try container.encode(titledRunIDs, forKey: .titledRunIDs)
        }
    }
}
