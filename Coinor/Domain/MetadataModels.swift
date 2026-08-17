import Foundation

/// The current Coinor metadata schema version. Bump this whenever
/// `MetadataDocument`'s persisted shape changes in a way older decoders
/// cannot already tolerate, and add the matching step to `MetadataMigrator`.
enum MetadataSchema {
    static let currentVersion = 6
}

struct ShellTabMetadata: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
}

struct ConversationTabMetadata: Equatable, Sendable {
    static let mainID = "main"
    static let ideID = "ide"

    var mainName: String
    var shellTabs: [ShellTabMetadata]
    var selectedTabID: String
    var nextTabNumber: Int

    static let initial = ConversationTabMetadata(
        mainName: "main",
        shellTabs: [],
        selectedTabID: mainID,
        nextTabNumber: 1
    )

    var orderedTabIDs: [String] {
        [Self.mainID, Self.ideID] + shellTabs.map(\.id)
    }

    func contains(tabID: String) -> Bool {
        tabID == Self.mainID
            || tabID == Self.ideID
            || shellTabs.contains { $0.id == tabID }
    }

    mutating func appendShell(id: String) -> ShellTabMetadata {
        let tab = ShellTabMetadata(
            id: id,
            name: "Tab \(nextTabNumber)"
        )
        nextTabNumber += 1
        shellTabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    mutating func select(tabID: String) {
        guard contains(tabID: tabID) else { return }
        selectedTabID = tabID
    }

    mutating func rename(tabID: String, to name: String) {
        if tabID == Self.mainID {
            mainName = name
            return
        }
        guard tabID != Self.ideID else { return }
        guard let index = shellTabs.firstIndex(where: { $0.id == tabID })
        else {
            return
        }
        shellTabs[index].name = name
    }

    mutating func closeShell(tabID: String) {
        guard let shellIndex = shellTabs.firstIndex(where: {
            $0.id == tabID
        }) else {
            return
        }
        let orderedIndex = shellIndex + 2
        shellTabs.remove(at: shellIndex)
        if selectedTabID == tabID {
            selectedTabID = orderedTabIDs[
                min(orderedIndex - 1, orderedTabIDs.count - 1)
            ]
        }
    }

    mutating func moveShell(tabID: String, toFinalIndex: Int) {
        guard let sourceIndex = shellTabs.firstIndex(where: {
            $0.id == tabID
        }) else {
            return
        }
        let tab = shellTabs.remove(at: sourceIndex)
        let boundedIndex = min(
            max(toFinalIndex, 0),
            shellTabs.count
        )
        shellTabs.insert(tab, at: boundedIndex)
    }

    func normalized() -> ConversationTabMetadata {
        var seen = Set([Self.mainID, Self.ideID])
        let shells = shellTabs.filter {
            seen.insert($0.id).inserted
        }
        let validIDs = Set([Self.mainID, Self.ideID] + shells.map(\.id))
        return ConversationTabMetadata(
            mainName: mainName,
            shellTabs: shells,
            selectedTabID: validIDs.contains(selectedTabID)
                ? selectedTabID
                : Self.mainID,
            nextTabNumber: max(nextTabNumber, 1)
        )
    }
}

extension ConversationTabMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case mainName, shellTabs, selectedTabID, nextTabNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainName = try container.decodeIfPresent(
            String.self,
            forKey: .mainName
        ) ?? Self.initial.mainName
        shellTabs = try container.decodeIfPresent(
            [ShellTabMetadata].self,
            forKey: .shellTabs
        ) ?? []
        selectedTabID = try container.decodeIfPresent(
            String.self,
            forKey: .selectedTabID
        ) ?? Self.mainID
        nextTabNumber = try container.decodeIfPresent(
            Int.self,
            forKey: .nextTabNumber
        ) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mainName, forKey: .mainName)
        try container.encode(shellTabs, forKey: .shellTabs)
        try container.encode(selectedTabID, forKey: .selectedTabID)
        try container.encode(nextTabNumber, forKey: .nextTabNumber)
    }
}

/// Coinor's local, versioned organization state for one Grok session.
///
/// Never carries a title or transcript alias: Grok remains the only source
/// of display text for a conversation.
struct SessionMetadata: Equatable, Sendable {
    var archived: Bool = false
    var tabs: ConversationTabMetadata? = nil
}

extension SessionMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case archived, tabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archived = try container.decodeIfPresent(
            Bool.self,
            forKey: .archived
        ) ?? false
        tabs = try container.decodeIfPresent(
            ConversationTabMetadata.self,
            forKey: .tabs
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(archived, forKey: .archived)
        try container.encodeIfPresent(tabs, forKey: .tabs)
    }
}

/// Coinor's local, versioned organization state for one project (a local Git
/// repository identity, including any of its worktrees).
struct ProjectMetadata: Equatable, Sendable {
    var manuallyRegistered: Bool = false
    var archived: Bool = false
    var expanded: Bool = false
    var checkoutPath: String?
    var displayName: String?
    var iconName: String?
    var iconColorName: String?
    var conversationOrder: [String]?
}

extension ProjectMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case manuallyRegistered, archived, expanded, checkoutPath
        case displayName, iconName, iconColorName, conversationOrder
    }

    /// Decodes leniently so a document written by an older schema, or edited
    /// by hand, parses instead of failing the whole app launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manuallyRegistered = try container.decodeIfPresent(
            Bool.self,
            forKey: .manuallyRegistered
        ) ?? false
        archived = try container.decodeIfPresent(
            Bool.self,
            forKey: .archived
        ) ?? false
        expanded = try container.decodeIfPresent(
            Bool.self,
            forKey: .expanded
        ) ?? false
        checkoutPath = try container.decodeIfPresent(
            String.self,
            forKey: .checkoutPath
        )
        displayName = try container.decodeIfPresent(
            String.self,
            forKey: .displayName
        )
        iconName = try container.decodeIfPresent(
            String.self,
            forKey: .iconName
        )
        iconColorName = try container.decodeIfPresent(
            String.self,
            forKey: .iconColorName
        )
        conversationOrder = try container.decodeIfPresent(
            [String].self,
            forKey: .conversationOrder
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manuallyRegistered, forKey: .manuallyRegistered)
        try container.encode(archived, forKey: .archived)
        try container.encode(expanded, forKey: .expanded)
        try container.encodeIfPresent(checkoutPath, forKey: .checkoutPath)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encodeIfPresent(iconColorName, forKey: .iconColorName)
        try container.encodeIfPresent(
            conversationOrder,
            forKey: .conversationOrder
        )
    }
}

/// The single JSON document Coinor persists.
///
/// Grok owns everything else -- session identity, titles, transcripts, and
/// activity -- so this document only ever carries organization and UI
/// metadata, keyed by the stable session and project identities Grok and Git
/// already provide.
struct TelegramMetadata: Equatable, Sendable {
    var pairedUserID: TelegramUserID?
    var pairedChatID: TelegramChatID?
    var threadIDBySessionID: [String: Int]
    var pendingPairingCode: String?

    static let empty = TelegramMetadata(
        pairedUserID: nil,
        pairedChatID: nil,
        threadIDBySessionID: [:],
        pendingPairingCode: nil
    )

    var sessionIDByThreadID: [Int: String] {
        Dictionary(uniqueKeysWithValues: threadIDBySessionID.map { ($0.value, $0.key) })
    }
}

extension TelegramMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case pairedUserID, pairedChatID, threadIDBySessionID, pendingPairingCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(Int64.self, forKey: .pairedUserID) {
            pairedUserID = TelegramUserID(raw)
        } else {
            pairedUserID = nil
        }
        if let raw = try container.decodeIfPresent(Int64.self, forKey: .pairedChatID) {
            pairedChatID = TelegramChatID(raw)
        } else {
            pairedChatID = nil
        }
        threadIDBySessionID = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .threadIDBySessionID
        ) ?? [:]
        pendingPairingCode = try container.decodeIfPresent(
            String.self,
            forKey: .pendingPairingCode
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pairedUserID?.rawValue, forKey: .pairedUserID)
        try container.encodeIfPresent(pairedChatID?.rawValue, forKey: .pairedChatID)
        try container.encode(threadIDBySessionID, forKey: .threadIDBySessionID)
        try container.encodeIfPresent(pendingPairingCode, forKey: .pendingPairingCode)
    }
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
    var remoteHostAliases: [RemoteHostAlias]
    /// Hides every remote project without unregistering its computer, so a
    /// machine that is asleep or irrelevant right now stops crowding the
    /// sidebar.
    var remoteProjectsHidden: Bool
    var pinnedSessionIDs: [String]
    var projectOrder: [String]
    var lastVisibleSessionID: String?
    var telegram: TelegramMetadata

    static let empty = MetadataDocument(
        schemaVersion: MetadataSchema.currentVersion,
        sessions: [:],
        projects: [:],
        remoteHostAliases: [],
        remoteProjectsHidden: false,
        pinnedSessionIDs: [],
        projectOrder: [],
        lastVisibleSessionID: nil,
        telegram: .empty
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

    func conversationTabs(_ sessionID: String) -> ConversationTabMetadata {
        sessions[sessionID]?.tabs?.normalized()
            ?? ConversationTabMetadata.initial
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
    /// Pins a session at the top of the section. Order is significant and
    /// preserved; pinning an already-pinned session is a no-op rather than
    /// moving it again.
    mutating func pin(_ sessionID: String) {
        guard !pinnedSessionIDs.contains(sessionID) else { return }
        pinnedSessionIDs.insert(sessionID, at: 0)
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

    mutating func setConversationTabs(
        _ sessionID: String,
        tabs: ConversationTabMetadata
    ) {
        var value = sessions[sessionID] ?? SessionMetadata()
        let normalized = tabs.normalized()
        value.tabs = normalized == .initial ? nil : normalized
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

    /// Registers a host while preserving the user's order. Registering an
    /// existing alias is a no-op rather than moving it to the end.
    mutating func registerRemoteHost(_ alias: RemoteHostAlias) {
        guard !remoteHostAliases.contains(alias) else { return }
        remoteHostAliases.append(alias)
    }

    mutating func unregisterRemoteHost(_ alias: RemoteHostAlias) {
        remoteHostAliases.removeAll { $0 == alias }
    }

    mutating func setRemoteProjectsHidden(_ hidden: Bool) {
        remoteProjectsHidden = hidden
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
        case remoteHostAliases
        case remoteProjectsHidden
        case pinnedSessionIDs
        case projectOrder
        case lastVisibleSessionID
        case telegram
    }

    /// Decodes leniently: every key is optional with a safe default, so a
    /// document from any prior schema version parses without throwing.
    /// `MetadataMigrator` is what actually normalizes it to the current shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        sessions = try container.decodeIfPresent([String: SessionMetadata].self, forKey: .sessions) ?? [:]
        projects = try container.decodeIfPresent([String: ProjectMetadata].self, forKey: .projects) ?? [:]
        let rawRemoteHostAliases = try container.decodeIfPresent(
            [String].self,
            forKey: .remoteHostAliases
        ) ?? []
        var seenRemoteHostAliases: Set<RemoteHostAlias> = []
        remoteHostAliases = rawRemoteHostAliases.compactMap {
            guard let alias = RemoteHostAlias(rawValue: $0),
                  seenRemoteHostAliases.insert(alias).inserted else {
                return nil
            }
            return alias
        }
        remoteProjectsHidden = try container.decodeIfPresent(
            Bool.self,
            forKey: .remoteProjectsHidden
        ) ?? false
        pinnedSessionIDs = try container.decodeIfPresent([String].self, forKey: .pinnedSessionIDs) ?? []
        projectOrder = try container.decodeIfPresent([String].self, forKey: .projectOrder) ?? []
        lastVisibleSessionID = try container.decodeIfPresent(String.self, forKey: .lastVisibleSessionID)
        telegram = try container.decodeIfPresent(
            TelegramMetadata.self,
            forKey: .telegram
        ) ?? .empty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(projects, forKey: .projects)
        try container.encode(remoteHostAliases, forKey: .remoteHostAliases)
        try container.encode(remoteProjectsHidden, forKey: .remoteProjectsHidden)
        try container.encode(pinnedSessionIDs, forKey: .pinnedSessionIDs)
        try container.encode(projectOrder, forKey: .projectOrder)
        try container.encodeIfPresent(lastVisibleSessionID, forKey: .lastVisibleSessionID)
        if telegram != .empty {
            try container.encode(telegram, forKey: .telegram)
        }
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
