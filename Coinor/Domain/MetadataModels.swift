import Foundation

/// The current Coinor metadata schema version. Bump this whenever
/// `MetadataDocument`'s persisted shape changes in a way older decoders
/// cannot already tolerate, and add the matching step to `MetadataMigrator`.
enum MetadataSchema {
    static let currentVersion = 2
}

/// Coinor's local, versioned organization state for one Grok session.
///
/// Never carries a title or transcript alias: Grok remains the only source
/// of display text for a conversation.
struct SessionMetadata: Codable, Equatable, Sendable {
    var archived: Bool = false
}

/// Coinor's local, versioned organization state for one project (a local Git
/// repository identity, including any of its worktrees).
struct ProjectMetadata: Codable, Equatable, Sendable {
    var manuallyRegistered: Bool = false
    var archived: Bool = false
    var expanded: Bool = false
    var checkoutPath: String?
    var displayName: String?
    var iconName: String?
    var iconColorName: String?
    var conversationOrder: [String]?
}

/// The single JSON document Coinor persists.
///
/// Grok owns everything else -- session identity, titles, transcripts, and
/// activity -- so this document only ever carries organization and UI
/// metadata, keyed by the stable session and project identities Grok and Git
/// already provide.
struct MetadataDocument: Equatable, Sendable {
    var schemaVersion: Int
    var sessions: [String: SessionMetadata]
    var projects: [String: ProjectMetadata]
    var pinnedSessionIDs: [String]
    var projectOrder: [String]
    var lastVisibleSessionID: String?

    static let empty = MetadataDocument(
        schemaVersion: MetadataSchema.currentVersion,
        sessions: [:],
        projects: [:],
        pinnedSessionIDs: [],
        projectOrder: [],
        lastVisibleSessionID: nil
    )
}

// MARK: - Queries

extension MetadataDocument {
    func isSessionPinned(_ sessionID: String) -> Bool {
        pinnedSessionIDs.contains(sessionID)
    }

    func isSessionArchived(_ sessionID: String) -> Bool {
        sessions[sessionID]?.archived ?? false
    }

    func isProjectArchived(_ projectID: String) -> Bool {
        projects[projectID]?.archived ?? false
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        projects[projectID]?.expanded ?? false
    }

    func isProjectManuallyRegistered(_ projectID: String) -> Bool {
        projects[projectID]?.manuallyRegistered ?? false
    }

    func projectCheckoutPath(_ projectID: String) -> String? {
        projects[projectID]?.checkoutPath
    }

    func projectDisplayName(_ projectID: String) -> String? {
        projects[projectID]?.displayName
    }

    func projectIconName(_ projectID: String) -> String? {
        projects[projectID]?.iconName
    }

    func projectIconColorName(_ projectID: String) -> String? {
        projects[projectID]?.iconColorName
    }

    func projectConversationOrder(_ projectID: String) -> [String] {
        projects[projectID]?.conversationOrder ?? []
    }
}

// MARK: - Mutations

extension MetadataDocument {
    /// Pins a session. Order is significant and preserved; pinning an
    /// already-pinned session is a no-op rather than moving it to the end.
    mutating func pin(_ sessionID: String) {
        guard !pinnedSessionIDs.contains(sessionID) else { return }
        pinnedSessionIDs.append(sessionID)
    }

    mutating func unpin(_ sessionID: String) {
        pinnedSessionIDs.removeAll { $0 == sessionID }
    }

    /// Applies a full, user-chosen pin order. IDs that are not currently
    /// pinned are ignored instead of silently pinning them.
    mutating func reorderPinnedSessions(to newOrder: [String]) {
        let pinned = Set(pinnedSessionIDs)
        pinnedSessionIDs = newOrder.filter { pinned.contains($0) }
    }

    mutating func reorderVisiblePinnedSessions(
        to visibleOrder: [String]
    ) {
        let visibleIDs = Set(visibleOrder)
        guard visibleIDs.count == visibleOrder.count,
              visibleIDs.isSubset(of: Set(pinnedSessionIDs)) else {
            return
        }

        var replacement = visibleOrder.makeIterator()
        for index in pinnedSessionIDs.indices
        where visibleIDs.contains(pinnedSessionIDs[index]) {
            if let sessionID = replacement.next() {
                pinnedSessionIDs[index] = sessionID
            }
        }
    }

    mutating func reorderProjects(to newOrder: [String]) {
        var seen: Set<String> = []
        projectOrder = newOrder.filter { seen.insert($0).inserted }
    }

    mutating func reorderVisibleProjects(
        to visibleOrder: [String],
        allKnownProjectIDs: [String]
    ) {
        var seen: Set<String> = []
        var canonical = projectOrder.filter {
            seen.insert($0).inserted
        }
        for projectID in allKnownProjectIDs + visibleOrder
        where seen.insert(projectID).inserted {
            canonical.append(projectID)
        }

        let visibleIDs = Set(visibleOrder)
        var replacement = visibleOrder.makeIterator()
        for index in canonical.indices
        where visibleIDs.contains(canonical[index]) {
            if let projectID = replacement.next() {
                canonical[index] = projectID
            }
        }
        while let projectID = replacement.next() {
            canonical.append(projectID)
        }
        projectOrder = canonical
    }

    mutating func setSessionArchived(_ sessionID: String, archived: Bool) {
        var value = sessions[sessionID] ?? SessionMetadata()
        value.archived = archived
        storeSession(sessionID, value)
    }

    mutating func registerProject(
        _ projectID: String,
        checkoutPath: String? = nil
    ) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.manuallyRegistered = true
        if let checkoutPath {
            value.checkoutPath = checkoutPath
        }
        storeProject(projectID, value)
    }

    mutating func unregisterProject(_ projectID: String) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.manuallyRegistered = false
        storeProject(projectID, value)
    }

    mutating func setProjectArchived(_ projectID: String, archived: Bool) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.archived = archived
        storeProject(projectID, value)
    }

    mutating func setProjectExpanded(_ projectID: String, expanded: Bool) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.expanded = expanded
        storeProject(projectID, value)
    }

    mutating func setProjectDisplayName(
        _ projectID: String,
        displayName: String?
    ) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.displayName = displayName
        storeProject(projectID, value)
    }

    mutating func setProjectIconName(
        _ projectID: String,
        iconName: String?
    ) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.iconName = iconName
        storeProject(projectID, value)
    }

    mutating func setProjectIconColorName(
        _ projectID: String,
        iconColorName: String?
    ) {
        var value = projects[projectID] ?? ProjectMetadata()
        value.iconColorName = iconColorName
        storeProject(projectID, value)
    }

    mutating func reorderVisibleConversations(
        in projectID: String,
        to visibleOrder: [String],
        allKnownSessionIDs: [String]
    ) {
        var value = projects[projectID] ?? ProjectMetadata()
        var seen: Set<String> = []
        var canonical = (value.conversationOrder ?? []).filter {
            seen.insert($0).inserted
        }
        for sessionID in allKnownSessionIDs + visibleOrder
        where seen.insert(sessionID).inserted {
            canonical.append(sessionID)
        }

        let visibleIDs = Set(visibleOrder)
        var replacement = visibleOrder.makeIterator()
        for index in canonical.indices
        where visibleIDs.contains(canonical[index]) {
            if let sessionID = replacement.next() {
                canonical[index] = sessionID
            }
        }
        while let sessionID = replacement.next() {
            canonical.append(sessionID)
        }

        value.conversationOrder = canonical
        storeProject(projectID, value)
    }

    mutating func setLastVisibleSession(_ sessionID: String?) {
        lastVisibleSessionID = sessionID
    }

    /// Keeps the document sparse: an entry that has returned to every
    /// default value is removed instead of persisted as an empty override.
    private mutating func storeSession(_ id: String, _ value: SessionMetadata) {
        if value == SessionMetadata() {
            sessions.removeValue(forKey: id)
        } else {
            sessions[id] = value
        }
    }

    private mutating func storeProject(_ id: String, _ value: ProjectMetadata) {
        if value == ProjectMetadata() {
            projects.removeValue(forKey: id)
        } else {
            projects[id] = value
        }
    }
}

// MARK: - Codable

extension MetadataDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessions
        case projects
        case pinnedSessionIDs
        case projectOrder
        case lastVisibleSessionID
    }

    /// Decodes leniently: every key is optional with a safe default, so a
    /// document from any prior schema version parses without throwing.
    /// `MetadataMigrator` is what actually normalizes it to the current shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        sessions = try container.decodeIfPresent([String: SessionMetadata].self, forKey: .sessions) ?? [:]
        projects = try container.decodeIfPresent([String: ProjectMetadata].self, forKey: .projects) ?? [:]
        pinnedSessionIDs = try container.decodeIfPresent([String].self, forKey: .pinnedSessionIDs) ?? []
        projectOrder = try container.decodeIfPresent([String].self, forKey: .projectOrder) ?? []
        lastVisibleSessionID = try container.decodeIfPresent(String.self, forKey: .lastVisibleSessionID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(projects, forKey: .projects)
        try container.encode(pinnedSessionIDs, forKey: .pinnedSessionIDs)
        try container.encode(projectOrder, forKey: .projectOrder)
        try container.encodeIfPresent(lastVisibleSessionID, forKey: .lastVisibleSessionID)
    }
}

// MARK: - Migration

enum MetadataMigrator {
    /// The entry point every load path funnels through before treating a
    /// document as current. Loops one version at a time so each step stays
    /// small and independently testable.
    static func migrate(_ document: MetadataDocument) -> MetadataDocument {
        var migrated = document
        while migrated.schemaVersion < MetadataSchema.currentVersion {
            migrated = migrateStep(migrated)
        }
        return migrated
    }

    /// Upgrades a document by exactly one schema version. `MetadataDocument`
    /// already decodes every field leniently, so version 0 (predating
    /// `schemaVersion` itself) only needs its version stamped forward; add a
    /// case here for any future version that needs real field changes.
    private static func migrateStep(_ document: MetadataDocument) -> MetadataDocument {
        var next = document
        next.schemaVersion = document.schemaVersion + 1
        return next
    }
}
