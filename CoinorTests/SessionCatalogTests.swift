import Testing

@testable import Coinor

private func session(_ id: String, project: String, title: String = "Untitled") -> SessionSummary {
    SessionSummary(id: id, projectID: project, title: title)
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
func pinnedOrderMatchesMetadataOrder() {
    var metadata = MetadataDocument.empty
    metadata.pin("session-b")
    metadata.pin("session-a")

    let sessions = [
        session("session-a", project: "project-a"),
        session("session-b", project: "project-a"),
    ]

    let catalog = SessionCatalog.build(sessions: sessions, metadata: metadata)

    #expect(catalog.pinned.map(\.id) == ["session-b", "session-a"])
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

    #expect(catalog.pinned.map(\.id) == ["session-a", "session-b"])
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
