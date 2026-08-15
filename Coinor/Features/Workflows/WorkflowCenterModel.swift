import Foundation

/// View state for the workflow center: the catalog of launchable workflow
/// definitions and the live/finished runs for whichever conversation is the
/// current execution context.
///
/// Grok owns every run's authoritative state; this model only mirrors it for
/// display; nothing here is persisted.
@MainActor
final class WorkflowCenterModel: ObservableObject {
    /// The conversation a workflow would launch into or control against.
    struct Context: Equatable {
        let sessionID: String
        let conversationTitle: String
        let projectTitle: String
        let remoteHostTitle: String?

        var subtitle: String {
            guard let remoteHostTitle, !remoteHostTitle.isEmpty else {
                return projectTitle
            }
            return "\(projectTitle) · \(remoteHostTitle)"
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// One section of the definition catalog, grouped by where the workflow
    /// script came from.
    struct DefinitionGroup: Identifiable, Equatable {
        let source: GrokWorkflowDefinition.Source
        let title: String
        let definitions: [GrokWorkflowDefinition]

        var id: String { title }
    }

    /// The bucket a definition's source sorts into. Every unmodeled
    /// (`unknown`) source shares one trailing group rather than fragmenting
    /// into one group per unrecognized wire string.
    private enum SourceBucket: CaseIterable, Hashable {
        case project
        case user
        case builtin
        case unknown

        var title: String {
            switch self {
            case .project: return "Project"
            case .user: return "Personal"
            case .builtin: return "Built-in"
            case .unknown: return "Other"
            }
        }

        var representativeSource: GrokWorkflowDefinition.Source {
            switch self {
            case .project: return .project
            case .user: return .user
            case .builtin: return .builtin
            case .unknown: return .unknown("")
            }
        }

        init(_ source: GrokWorkflowDefinition.Source) {
            switch source {
            case .project: self = .project
            case .user: self = .user
            case .builtin: self = .builtin
            case .unknown: self = .unknown
            }
        }
    }

    @Published private(set) var context: Context?
    @Published private(set) var definitions: [GrokWorkflowDefinition] = []
    @Published private(set) var runStore = GrokWorkflowRunStore()
    @Published private(set) var catalogState: LoadState = .idle
    @Published private(set) var runsState: LoadState = .idle
    @Published private(set) var actionError: String?
    @Published private(set) var activeAction: String?

    @Published var selectedDefinitionID: String?
    @Published var selectedRunID: String?

    /// Guards every load callback against a stale context: incremented every
    /// time `beginContext`/`enterNoContext` runs, and compared by every
    /// begin/complete/fail call so a slow request from an abandoned
    /// conversation can never overwrite the current one's state.
    private(set) var generation = 0

    // MARK: - Context

    /// Starts a new execution context, clearing the catalog, runs load
    /// states, and selections. The run store is untouched: runs for other
    /// sessions stay available if the user switches back.
    @discardableResult
    func beginContext(
        sessionID: String,
        conversationTitle: String,
        projectTitle: String,
        remoteHostTitle: String?
    ) -> Int {
        generation += 1
        context = Context(
            sessionID: sessionID,
            conversationTitle: conversationTitle,
            projectTitle: projectTitle,
            remoteHostTitle: remoteHostTitle
        )
        resetForNewContext()
        return generation
    }

    /// Enters the no-context state, used while no conversation is selected.
    func enterNoContext() {
        generation += 1
        context = nil
        resetForNewContext()
    }

    private func resetForNewContext() {
        definitions = []
        selectedDefinitionID = nil
        selectedRunID = nil
        catalogState = .idle
        runsState = .idle
        actionError = nil
        activeAction = nil
    }

    private func isCurrent(generation: Int, sessionID: String) -> Bool {
        generation == self.generation && context?.sessionID == sessionID
    }

    // MARK: - Catalog load

    func beginCatalogLoad(generation: Int, sessionID: String) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        catalogState = .loading
    }

    func completeCatalogLoad(
        generation: Int,
        sessionID: String,
        definitions: [GrokWorkflowDefinition]
    ) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        self.definitions = definitions
        catalogState = .loaded
        if let selectedDefinitionID,
           definitions.contains(where: { $0.id == selectedDefinitionID }) {
            return
        }
        selectedDefinitionID = Self.defaultDefinitionID(in: definitions)
    }

    func failCatalogLoad(generation: Int, sessionID: String, error: String) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        catalogState = .failed(error)
    }

    // MARK: - Runs load

    func beginRunsLoad(generation: Int, sessionID: String) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        runsState = .loading
    }

    func completeRunsLoad(
        generation: Int,
        sessionID: String,
        runs: [GrokWorkflowRun]
    ) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        for run in runs {
            runStore.apply(run)
        }
        runsState = .loaded
        let visible = visibleRuns
        if let selectedRunID, visible.contains(where: { $0.id == selectedRunID }) {
            return
        }
        selectedRunID = visible.first?.id
    }

    func failRunsLoad(generation: Int, sessionID: String, error: String) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        runsState = .failed(error)
    }

    // MARK: - Live updates

    /// Applies a run reported outside a snapshot load, e.g. a
    /// `workflow_updated` notification or the run returned by a control call.
    /// Revision-gated by the underlying store; a stale replay is a no-op.
    func ingest(_ run: GrokWorkflowRun) {
        guard runStore.apply(run) else { return }
        if context?.sessionID == run.sessionID, selectedRunID == nil {
            selectedRunID = run.runID
        }
    }

    // MARK: - Actions

    func beginAction(_ id: String, generation: Int, sessionID: String) {
        guard isCurrent(generation: generation, sessionID: sessionID) else { return }
        activeAction = id
        actionError = nil
    }

    func endAction(_ id: String, generation: Int, sessionID: String) {
        guard isCurrent(generation: generation, sessionID: sessionID),
              activeAction == id else { return }
        activeAction = nil
    }

    func failAction(
        _ id: String,
        generation: Int,
        sessionID: String,
        error: String
    ) {
        guard isCurrent(generation: generation, sessionID: sessionID),
              activeAction == id else { return }
        actionError = error
        activeAction = nil
    }

    // MARK: - Derived state

    /// Runs belonging to the current context's session, newest first. Empty
    /// with no context.
    var visibleRuns: [GrokWorkflowRun] {
        guard let context else { return [] }
        return runStore.runs(sessionID: context.sessionID)
    }

    var selectedDefinition: GrokWorkflowDefinition? {
        guard let selectedDefinitionID else { return nil }
        return definitions.first { $0.id == selectedDefinitionID }
    }

    var selectedRun: GrokWorkflowRun? {
        guard let selectedRunID else { return nil }
        return visibleRuns.first { $0.id == selectedRunID }
    }

    /// The catalog grouped by source, in `project, user, builtin, unknown`
    /// order, filtered case-insensitively against name/description/whenToUse.
    /// Empty groups are omitted.
    func definitionGroups(matching query: String) -> [DefinitionGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = trimmed.isEmpty
            ? definitions
            : definitions.filter { Self.matches($0, query: trimmed) }
        let grouped = Dictionary(grouping: matched) { SourceBucket($0.source) }
        return SourceBucket.allCases.compactMap { bucket in
            guard let bucketDefinitions = grouped[bucket], !bucketDefinitions.isEmpty else {
                return nil
            }
            return DefinitionGroup(
                source: bucket.representativeSource,
                title: bucket.title,
                definitions: Self.sortedByName(bucketDefinitions)
            )
        }
    }

    private static func defaultDefinitionID(in definitions: [GrokWorkflowDefinition]) -> String? {
        for bucket: SourceBucket in [.project, .user, .builtin] {
            let candidates = definitions.filter { SourceBucket($0.source) == bucket }
            if let first = sortedByName(candidates).first {
                return first.id
            }
        }
        return nil
    }

    private static func sortedByName(
        _ definitions: [GrokWorkflowDefinition]
    ) -> [GrokWorkflowDefinition] {
        definitions.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func matches(_ definition: GrokWorkflowDefinition, query: String) -> Bool {
        let needle = query.lowercased()
        if definition.name.lowercased().contains(needle) { return true }
        if let description = definition.description, description.lowercased().contains(needle) {
            return true
        }
        if let whenToUse = definition.whenToUse, whenToUse.lowercased().contains(needle) {
            return true
        }
        return false
    }
}
