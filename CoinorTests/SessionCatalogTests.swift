import Foundation
import Testing

@testable import Coinor

private func session(
    _ id: String,
    project: String,
    title: String = "Untitled",
    lastActivityAt: Date? = nil
) -> SessionSummary {
    SessionSummary(
        id: id,
        projectID: project,
        title: title,
        lastActivityAt: lastActivityAt
    )
}

@Test
func pinnedConversationsAreExcludedFromTheirProjectRow() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-a")

    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
    ]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.map(\.id) == ["session-a"])
    #expect(catalog.projects.map(\.projectID) == ["project-a"])
    #expect(catalog.projects.first?.conversations.map(\.id) == ["session-b"])
}

@Test
func newlyPinnedConversationsAppearAtTheTop() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-b")
    metadata.pin("session-a")

    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
    ]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.map(\.id) == ["session-a", "session-b"])
}

@Test
func explicitPinnedOrderSurvivesLaterPins() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-a")
    metadata.pin("session-b")
    metadata.reorderVisiblePinnedSessions(to: ["session-a", "session-b"])
    metadata.pin("session-c")

    let catalog = SessionCatalog.build(
        sessions: [
            session("session-b", project: "project-a"),
            session("session-c", project: "project-a"),
            session("session-a", project: "project-a"),
        ],
        metadata: metadata
    )

    #expect(catalog.pinned.map(\.id) == ["session-c", "session-a", "session-b"])
}

@Test
func archivedSessionsAndProjectsAreFilteredFromTheActiveCatalog() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("session-a", archived: true)
    metadata.setProjectArchived("project-b", archived: true)
    metadata.pin("session-a")
    metadata.pin("session-c")

    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
        session("session-c", project: "project-b"),
    ]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.isEmpty)
    #expect(catalog.projects.map(\.projectID) == ["project-a"])
    #expect(catalog.projects.first?.conversations.map(\.id) == ["session-b"])
}

@Test
func archivingAProjectCanUnpinAllOfItsConversations() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-a")
    metadata.pin("session-b")
    let projectSessionIDs = ["session-a", "session-b"]

    projectSessionIDs.forEach { metadata.unpin($0) }
    metadata.setProjectArchived("project-a", archived: true)

    #expect(!metadata.isSessionPinned("session-a"))
    #expect(!metadata.isSessionPinned("session-b"))
    #expect(metadata.isProjectArchived("project-a"))
}

@Test
func manuallyRegisteredEmptyProjectIsRetained() {
    var metadata = MetadataDocument.empty
    metadata.registerProject("project-empty")

    let catalog = SessionCatalog.build(sessions: [], metadata: metadata)

    #expect(catalog.projects.map(\.projectID) == ["project-empty"])
    #expect(catalog.projects.first?.conversations.isEmpty == true)
    #expect(catalog.projects.first?.isManuallyRegistered == true)
}

@Test
func discoveredProjectRemainsWhenItsOnlyConversationIsArchived() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("session-a", archived: true)

    let sessions = [session("session-a", project: "project-a")]
    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.projects.map(\.projectID) == ["project-a"])
    #expect(catalog.projects.first?.conversations.isEmpty == true)
}

@Test
func discoveredProjectRemainsWhenEveryConversationIsPinned() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-a")
    metadata.pin("session-b")

    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
    ]
    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.map(\.id) == ["session-b", "session-a"])
    #expect(catalog.projects.map(\.projectID) == ["project-a"])
    #expect(catalog.projects.first?.conversations.isEmpty == true)
}

@Test
func unknownMetadataIdentifiersAreHarmless() {
    var metadata = MetadataDocument.empty
    metadata.pin("ghost-session")
    metadata.setSessionArchived("another-ghost-session", archived: true)
    metadata.setProjectArchived("ghost-project", archived: true)

    let sessions = [session("session-a", project: "project-a")]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.isEmpty)
    #expect(catalog.projects.map(\.projectID) == ["project-a"])
    #expect(catalog.projects.first?.conversations.map(\.id) == ["session-a"])
}

@Test
func expandedStateFlowsFromMetadataIntoTheProjectRow() {
    var metadata = MetadataDocument.empty
    metadata.setProjectExpanded("project-a", expanded: true)

    let sessions = [session("session-a", project: "project-a")]
    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.projects.first?.isExpanded == true)
}

@Test
func sessionsSharingAProjectIdentityStayFlatRegardlessOfOrigin() {
    let sessions = [
        session("main-session", project: "project-a"),
        session("worktree-session", project: "project-a"),
    ]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: .empty)

    #expect(catalog.projects.count == 1)
    #expect(catalog.projects.first?.conversations.map(\.id) == ["main-session", "worktree-session"])
}

@Test
func storedProjectOrderWinsAndNewProjectsAppend() {
    var metadata = MetadataDocument.empty
    metadata.reorderProjects(to: ["project-b", "project-a"])

    let catalog = SessionCatalog.build(
        sessions: [
            session("a", project: "project-a"),
            session("b", project: "project-b"),
            session("c", project: "project-c"),
        ],
        metadata: metadata
    )

    #expect(
        catalog.projects.map(\.projectID)
            == ["project-b", "project-a", "project-c"]
    )
}

@Test
func archivedProjectReturnsToItsCanonicalPosition() {
    var metadata = MetadataDocument.empty
    metadata.reorderProjects(
        to: ["project-c", "project-b", "project-a"]
    )
    metadata.setProjectArchived("project-b", archived: true)
    let sessions = [
        session("a", project: "project-a"),
        session("b", project: "project-b"),
        session("c", project: "project-c"),
    ]

    var catalog = SessionCatalog.build(
        sessions: sessions,
        metadata: metadata
    )
    #expect(
        catalog.projects.map(\.projectID)
            == ["project-c", "project-a"]
    )

    metadata.setProjectArchived("project-b", archived: false)
    catalog = SessionCatalog.build(
        sessions: sessions,
        metadata: metadata
    )
    #expect(
        catalog.projects.map(\.projectID)
            == ["project-c", "project-b", "project-a"]
    )
}

@Test
func unorderedConversationsDefaultToNewestFirst() {
    let catalog = SessionCatalog.build(
        sessions: [
            session(
                "old",
                project: "project-a",
                lastActivityAt: Date(timeIntervalSince1970: 100)
            ),
            session("missing", project: "project-a"),
            session(
                "new",
                project: "project-a",
                lastActivityAt: Date(timeIntervalSince1970: 1_000)
            ),
        ],
        metadata: .empty
    )

    #expect(
        catalog.projects.first?.conversations.map(\.id)
            == ["new", "old", "missing"]
    )
}

@Test
func newlyDiscoveredConversationAppearsAboveExplicitExistingOrder() {
    var metadata = MetadataDocument.empty
    metadata.reorderVisibleConversations(
        in: "project-a",
        to: ["session-a", "session-b"],
        allKnownSessionIDs: ["session-a", "session-b"]
    )

    let catalog = SessionCatalog.build(
        sessions: [
            session(
                "session-a",
                project: "project-a",
                lastActivityAt: Date(timeIntervalSince1970: 100)
            ),
            session(
                "session-new",
                project: "project-a",
                lastActivityAt: Date(timeIntervalSince1970: 1_000)
            ),
            session(
                "session-b",
                project: "project-a",
                lastActivityAt: Date(timeIntervalSince1970: 200)
            ),
        ],
        metadata: metadata
    )

    #expect(
        catalog.projects.first?.conversations.map(\.id)
            == ["session-new", "session-a", "session-b"]
    )
}

@Test
func storedConversationOrderWinsWithinItsProject() {
    var metadata = MetadataDocument.empty
    metadata.reorderVisibleConversations(
        in: "project-a",
        to: ["session-c", "session-a", "session-b"],
        allKnownSessionIDs: ["session-a", "session-b", "session-c"]
    )

    let catalog = SessionCatalog.build(
        sessions: [
            session("session-a", project: "project-a"),
            session("session-b", project: "project-a"),
            session("session-c", project: "project-a"),
        ],
        metadata: metadata
    )

    #expect(
        catalog.projects.first?.conversations.map(\.id)
            == ["session-c", "session-a", "session-b"]
    )
}

@Test
func pinnedAndArchivedConversationsReturnToCanonicalProjectSlots() {
    var metadata = MetadataDocument.empty
    metadata.reorderVisibleConversations(
        in: "project-a",
        to: ["session-c", "session-b", "session-a"],
        allKnownSessionIDs: ["session-a", "session-b", "session-c"]
    )
    metadata.pin("session-b")
    metadata.setSessionArchived("session-c", archived: true)
    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
        session("session-c", project: "project-a"),
    ]

    var catalog = SessionCatalog.build(
        sessions: sessions,
        metadata: metadata
    )
    #expect(
        catalog.projects.first?.conversations.map(\.id)
            == ["session-a"]
    )

    metadata.unpin("session-b")
    metadata.setSessionArchived("session-c", archived: false)
    catalog = SessionCatalog.build(
        sessions: sessions,
        metadata: metadata
    )
    #expect(
        catalog.projects.first?.conversations.map(\.id)
            == ["session-c", "session-b", "session-a"]
    )
}

@Test
func searchRanksTextualClosenessBeforeRecency() {
    let old = Date(timeIntervalSince1970: 100)
    let recent = Date(timeIntervalSince1970: 1_000)
    let sessions = [
        session(
            "exact",
            project: "project",
            title: "Rent Roll",
            lastActivityAt: old
        ),
        session(
            "prefix",
            project: "project",
            title: "Rent Roll Normalizer",
            lastActivityAt: recent
        ),
        session(
            "substring",
            project: "project",
            title: "Debug Rent Roll Import",
            lastActivityAt: recent
        ),
    ]

    let results = ConversationSearch.results(
        query: "rent roll",
        sessions: sessions,
        metadata: .empty
    )

    #expect(
        results.map(\.id)
            == ["exact", "prefix", "substring"]
    )
}

@Test
func fuzzySearchUsesRecencyWithinEqualQuality() {
    let sessions = [
        session(
            "older",
            project: "project",
            title: "Rent Roll Normalizer old",
            lastActivityAt: Date(timeIntervalSince1970: 100)
        ),
        session(
            "newer",
            project: "project",
            title: "Rent Roll Normalizer new",
            lastActivityAt: Date(timeIntervalSince1970: 1_000)
        ),
    ]

    let results = ConversationSearch.results(
        query: "rrn",
        sessions: sessions,
        metadata: .empty
    )

    #expect(results.map(\.id) == ["newer", "older"])
}

@Test
func searchNormalizesCaseAccentsAndPunctuation() {
    let sessions = [
        session(
            "match",
            project: "project",
            title: "Résumé: Rent-Roll"
        ),
    ]

    let results = ConversationSearch.results(
        query: "resume rent roll",
        sessions: sessions,
        metadata: .empty
    )

    #expect(results.map(\.id) == ["match"])
    #expect(!ConversationSearch.hasEffectiveQuery("..."))
}

@Test
func searchExcludesArchivedItemsAndIsDeterministic() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("archived", archived: true)
    metadata.setProjectArchived("hidden-project", archived: true)
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let sessions = [
        session(
            "b",
            project: "project",
            title: "Same",
            lastActivityAt: timestamp
        ),
        session(
            "a",
            project: "project",
            title: "Same",
            lastActivityAt: timestamp
        ),
        session(
            "archived",
            project: "project",
            title: "Same"
        ),
        session(
            "hidden",
            project: "hidden-project",
            title: "Same"
        ),
    ]

    let results = ConversationSearch.results(
        query: "same",
        sessions: sessions,
        metadata: metadata
    )

    #expect(results.map(\.id) == ["a", "b"])
}
