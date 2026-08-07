import Foundation

/// The minimal facts about a Grok session Coinor needs to place it in the
/// sidebar catalog. Everything here is Grok-owned and passed through
/// untouched; Coinor never persists it.
struct SessionSummary: Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let title: String
}

/// A conversation row ready for display. Pin and archive state are expressed
/// by which section of `SessionCatalog` the row appears in, not by fields on
/// the row itself.
struct ConversationRow: Equatable, Identifiable, Sendable {
    let session: SessionSummary

    var id: String { session.id }
}

/// A project and its flat, unpinned, unarchived conversations. Conversations
/// stay flat regardless of whether they came from the main checkout or a
/// worktree; worktree identity is resolved into `projectID` upstream.
struct ProjectRow: Equatable, Identifiable, Sendable {
    let projectID: String
    let conversations: [ConversationRow]
    let isManuallyRegistered: Bool
    let isExpanded: Bool

    var id: String { projectID }
}

/// The sidebar's full read model: pinned conversations above every visible
/// project.
struct SessionCatalog: Equatable, Sendable {
    let pinned: [ConversationRow]
    let projects: [ProjectRow]

    static let empty = SessionCatalog(pinned: [], projects: [])
}

extension SessionCatalog {
    /// Joins Grok's session facts with Coinor's metadata by session ID.
    ///
    /// Rules applied here: pinned sessions are excluded from their project's
    /// row; archived sessions and archived projects are excluded entirely;
    /// a manually registered project is retained even with zero visible
    /// conversations; metadata entries that reference an ID absent from
    /// `sessions` are ignored rather than surfaced or treated as an error.
    static func build(sessions: [SessionSummary], metadata: MetadataDocument) -> SessionCatalog {
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func isVisible(_ session: SessionSummary) -> Bool {
            !metadata.isSessionArchived(session.id) && !metadata.isProjectArchived(session.projectID)
        }

        let pinned: [ConversationRow] = metadata.pinnedSessionIDs.compactMap { sessionID in
            guard let session = sessionsByID[sessionID], isVisible(session) else { return nil }
            return ConversationRow(session: session)
        }
        let pinnedIDs = Set(pinned.map(\.id))

        var conversationsByProject: [String: [ConversationRow]] = [:]
        var projectOrder: [String] = []
        var discoveredProjects: Set<String> = []
        for session in sessions
        where !metadata.isProjectArchived(session.projectID) {
            if discoveredProjects.insert(session.projectID).inserted {
                projectOrder.append(session.projectID)
            }
            guard isVisible(session), !pinnedIDs.contains(session.id) else {
                continue
            }
            conversationsByProject[session.projectID, default: []].append(ConversationRow(session: session))
        }

        let manualOnlyProjectIDs = metadata.projects
            .filter { entry in
                entry.value.manuallyRegistered
                    && !entry.value.archived
                    && !discoveredProjects.contains(entry.key)
            }
            .map(\.key)
            .sorted()

        let projectRows = (projectOrder + manualOnlyProjectIDs).map { projectID in
            ProjectRow(
                projectID: projectID,
                conversations: conversationsByProject[projectID] ?? [],
                isManuallyRegistered: metadata.isProjectManuallyRegistered(projectID),
                isExpanded: metadata.isProjectExpanded(projectID)
            )
        }

        return SessionCatalog(pinned: pinned, projects: projectRows)
    }
}
