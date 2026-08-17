import Foundation
import Testing

@testable import Coinor

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test
func missingFileBootstrapsToEmptyDocument() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument

    #expect(document == .empty)
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func relaunchRestoresPersistedState() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        let store = try MetadataStore(directoryURL: directory)
        try await store.update { document in
            document.pin("session-a")
            document.registerProject(
                "project-a",
                checkoutPath: "/tmp/Project A"
            )
            document.setProjectExpanded("project-a", expanded: true)
            document.setProjectDisplayName(
                "project-a",
                displayName: "Customer Portal"
            )
            document.setProjectIconName(
                "project-a",
                iconName: "terminal"
            )
            document.setProjectIconColorName(
                "project-a",
                iconColorName: "green"
            )
            document.reorderProjects(
                to: ["project-b", "project-a"]
            )
            document.reorderVisibleConversations(
                in: "project-a",
                to: ["session-b", "session-a"],
                allKnownSessionIDs: ["session-a", "session-b"]
            )
            var tabs = ConversationTabMetadata.initial
            _ = tabs.appendShell(id: "shell-a")
            tabs.rename(tabID: "shell-a", to: "server")
            document.setConversationTabs("session-a", tabs: tabs)
            document.setLastVisibleSession("session-a")
        }
    }

    let relaunched = try MetadataStore(directoryURL: directory)
    let document = await relaunched.currentDocument

    #expect(document.pinnedSessionIDs == ["session-a"])
    #expect(document.isProjectManuallyRegistered("project-a"))
    #expect(document.isProjectExpanded("project-a"))
    #expect(document.projectCheckoutPath("project-a") == "/tmp/Project A")
    #expect(document.projectDisplayName("project-a") == "Customer Portal")
    #expect(document.projectIconName("project-a") == "terminal")
    #expect(document.projectIconColorName("project-a") == "green")
    #expect(document.projectOrder == ["project-b", "project-a"])
    #expect(
        document.projectConversationOrder("project-a")
            == ["session-b", "session-a"]
    )
    #expect(
        document.conversationTabs("session-a").shellTabs
            == [ShellTabMetadata(id: "shell-a", name: "server")]
    )
    #expect(
        document.conversationTabs("session-a").selectedTabID
            == "shell-a"
    )
    #expect(document.lastVisibleSessionID == "session-a")
}

@Test
func clearingProjectPresentationPrunesAnOtherwiseEmptyOverride() {
    var document = MetadataDocument.empty

    document.setProjectDisplayName(
        "project-a",
        displayName: "Customer Portal"
    )
    document.setProjectIconName(
        "project-a",
        iconName: "terminal"
    )
    document.setProjectIconColorName(
        "project-a",
        iconColorName: "blue"
    )
    #expect(document.projects["project-a"] != nil)

    document.setProjectDisplayName("project-a", displayName: nil)
    document.setProjectIconName("project-a", iconName: nil)
    document.setProjectIconColorName("project-a", iconColorName: nil)
    #expect(document.projects["project-a"] == nil)
}

@Test
func reorderingVisibleProjectsPreservesArchivedSlots() {
    var document = MetadataDocument.empty
    document.reorderProjects(
        to: ["project-a", "project-b", "project-c"]
    )
    document.setProjectArchived("project-b", archived: true)

    document.reorderVisibleProjects(
        to: ["project-c", "project-a"],
        allKnownProjectIDs: [
            "project-a",
            "project-b",
            "project-c",
        ]
    )

    #expect(
        document.projectOrder
            == ["project-c", "project-b", "project-a"]
    )
}

@Test
func projectOrderRoundTripsWithCurrentSchema() throws {
    var document = MetadataDocument.empty
    document.reorderProjects(to: ["project-b", "project-a"])

    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(
        MetadataDocument.self,
        from: encoded
    )

    #expect(decoded.schemaVersion == MetadataSchema.currentVersion)
    #expect(decoded.projectOrder == ["project-b", "project-a"])
}

@Test
func registeringRemoteHostIsIdempotent() throws {
    let alias = try #require(
        RemoteHostAlias(rawValue: "studio-mac")
    )
    var document = MetadataDocument.empty

    document.registerRemoteHost(alias)
    document.registerRemoteHost(alias)

    #expect(document.remoteHostAliases == [alias])
}

@Test
func unregisteringRemoteHostRemovesIt() throws {
    let firstAlias = try #require(
        RemoteHostAlias(rawValue: "studio-mac")
    )
    let secondAlias = try #require(
        RemoteHostAlias(rawValue: "laptop")
    )
    var document = MetadataDocument.empty
    document.registerRemoteHost(firstAlias)
    document.registerRemoteHost(secondAlias)

    document.unregisterRemoteHost(firstAlias)

    #expect(document.remoteHostAliases == [secondAlias])
}

@Test
func remoteHostAliasesRoundTripThroughStore() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstAlias = try #require(
        RemoteHostAlias(rawValue: "studio-mac")
    )
    let secondAlias = try #require(
        RemoteHostAlias(rawValue: "laptop")
    )

    do {
        let store = try MetadataStore(directoryURL: directory)
        try await store.update { document in
            document.registerRemoteHost(firstAlias)
            document.registerRemoteHost(secondAlias)
        }
    }

    let relaunched = try MetadataStore(directoryURL: directory)
    let document = await relaunched.currentDocument

    #expect(document.remoteHostAliases == [firstAlias, secondAlias])
}

@Test
func versionThreeDocumentMigratesWithNoRemoteHosts() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let versionThreeBytes = Data(
        #"""
        {
          "schemaVersion": 3,
          "sessions": {},
          "projects": {},
          "pinnedSessionIDs": [],
          "projectOrder": []
        }
        """#.utf8
    )
    try versionThreeBytes.write(to: fileURL)

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument

    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.remoteHostAliases.isEmpty)
    #expect(!document.remoteProjectsHidden)
}

@Test
func invalidAndDuplicateRemoteHostAliasesAreDroppedWhileDecoding() throws {
    let json = """
    {
      "schemaVersion": 4,
      "remoteHostAliases": [
        "studio-mac",
        "not a host",
        "studio-mac",
        "laptop"
      ]
    }
    """
    let firstAlias = try #require(
        RemoteHostAlias(rawValue: "studio-mac")
    )
    let secondAlias = try #require(
        RemoteHostAlias(rawValue: "laptop")
    )

    let decoded = try JSONDecoder().decode(
        MetadataDocument.self,
        from: Data(json.utf8)
    )

    #expect(decoded.remoteHostAliases == [firstAlias, secondAlias])
}

@Test
func projectMetadataWithoutConversationOrderStillDecodes() throws {
    let json = """
    {
      "schemaVersion": 2,
      "sessions": {},
      "projects": {
        "project-a": {
          "manuallyRegistered": true,
          "archived": false,
          "expanded": true
        }
      },
      "pinnedSessionIDs": [],
      "projectOrder": ["project-a"]
    }
    """

    let decoded = try JSONDecoder().decode(
        MetadataDocument.self,
        from: Data(json.utf8)
    )

    #expect(decoded.schemaVersion == 2)
    #expect(decoded.projectConversationOrder("project-a").isEmpty)
}

@Test
func projectMetadataWithMissingFlagsStillDecodes() throws {
    let json = """
    {
      "schemaVersion": 3,
      "sessions": { "session-a": {} },
      "projects": {
        "project-a": { "archived": true },
        "project-b": {}
      },
      "pinnedSessionIDs": [],
      "projectOrder": ["project-a", "project-b"]
    }
    """

    let decoded = try JSONDecoder().decode(
        MetadataDocument.self,
        from: Data(json.utf8)
    )

    #expect(decoded.isProjectArchived("project-a"))
    #expect(decoded.isProjectManuallyRegistered("project-a") == false)
    #expect(decoded.isProjectExpanded("project-b") == false)
    #expect(decoded.isSessionArchived("session-a") == false)
}

@Test
func reorderingVisibleConversationsPreservesHiddenSlots() {
    var document = MetadataDocument.empty
    document.reorderVisibleConversations(
        in: "project-a",
        to: [
            "session-a",
            "hidden-pinned",
            "session-b",
            "hidden-archived",
            "session-c",
        ],
        allKnownSessionIDs: [
            "session-a",
            "hidden-pinned",
            "session-b",
            "hidden-archived",
            "session-c",
        ]
    )
    document.pin("hidden-pinned")
    document.setSessionArchived("hidden-archived", archived: true)

    document.reorderVisibleConversations(
        in: "project-a",
        to: ["session-c", "session-a", "session-b"],
        allKnownSessionIDs: [
            "session-a",
            "hidden-pinned",
            "session-b",
            "hidden-archived",
            "session-c",
        ]
    )

    #expect(
        document.projectConversationOrder("project-a")
            == [
                "session-c",
                "hidden-pinned",
                "session-a",
                "hidden-archived",
                "session-b",
            ]
    )
}

@Test
func reorderingVisiblePinnedSessionsPreservesHiddenPinnedSlots() {
    var document = MetadataDocument.empty
    document.pin("hidden")
    document.pin("first")
    document.pin("second")

    document.reorderVisiblePinnedSessions(
        to: ["second", "first"]
    )

    #expect(
        document.pinnedSessionIDs
            == ["second", "first", "hidden"]
    )
}

@Test
func pinningTwiceDoesNotDuplicate() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MetadataStore(directoryURL: directory)

    try await store.update { $0.pin("session-a") }
    try await store.update { $0.pin("session-a") }

    let document = await store.currentDocument
    #expect(document.pinnedSessionIDs == ["session-a"])
}

@Test
func unarchivingPrunesTheSparseOverride() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MetadataStore(directoryURL: directory)

    try await store.update { $0.setSessionArchived("session-a", archived: true) }
    var document = await store.currentDocument
    #expect(document.sessions["session-a"] != nil)

    try await store.update { $0.setSessionArchived("session-a", archived: false) }
    document = await store.currentDocument
    #expect(document.sessions["session-a"] == nil)
}

@Test
func atomicWriteLeavesOnlyTheFinalFileBehind() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MetadataStore(directoryURL: directory)

    try await store.update { document in
        document.pin("session-a")
        document.setSessionArchived("session-b", archived: true)
    }

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == [MetadataStore.fileName])

    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let data = try Data(contentsOf: fileURL)
    let decoded = try JSONDecoder().decode(MetadataDocument.self, from: data)
    let document = await store.currentDocument
    #expect(decoded == document)
}

@Test
func corruptFileFailsLoudlyWithoutBeingDestroyed() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let corruptBytes = Data("not valid json {".utf8)
    try corruptBytes.write(to: fileURL)

    var caughtCorrupt = false
    do {
        _ = try MetadataStore(directoryURL: directory)
    } catch MetadataStoreError.corrupt {
        caughtCorrupt = true
    }
    #expect(caughtCorrupt)

    let survivingBytes = try Data(contentsOf: fileURL)
    #expect(survivingBytes == corruptBytes)
}

@Test
func futureSchemaVersionFailsLoudlyWithoutBeingDestroyed() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let futureBytes = Data(#"{"schemaVersion": 999}"#.utf8)
    try futureBytes.write(to: fileURL)

    var caughtUnsupported = false
    do {
        _ = try MetadataStore(directoryURL: directory)
    } catch MetadataStoreError.unsupportedSchemaVersion {
        caughtUnsupported = true
    }
    #expect(caughtUnsupported)

    let survivingBytes = try Data(contentsOf: fileURL)
    #expect(survivingBytes == futureBytes)
}

@Test
func negativeSchemaVersionFailsLoudlyWithoutBeingDestroyed() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let negativeBytes = Data(#"{"schemaVersion": -1}"#.utf8)
    try negativeBytes.write(to: fileURL)

    var caughtUnsupported = false
    do {
        _ = try MetadataStore(directoryURL: directory)
    } catch MetadataStoreError.unsupportedSchemaVersion {
        caughtUnsupported = true
    }
    #expect(caughtUnsupported)

    let survivingBytes = try Data(contentsOf: fileURL)
    #expect(survivingBytes == negativeBytes)
}

@Test
func legacyDocumentMigratesForwardAndPreservesKnownData() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let legacyBytes = Data(#"{"pinnedSessionIDs": ["legacy-session"]}"#.utf8)
    try legacyBytes.write(to: fileURL)

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument

    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.pinnedSessionIDs == ["legacy-session"])
    #expect(document.sessions.isEmpty)
    #expect(document.projects.isEmpty)
}

@Test
func versionOneProjectMetadataMigratesWithoutAStoredCheckout() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let versionOneBytes = Data(
        #"""
        {
          "schemaVersion": 1,
          "projects": {
            "project-a": {
              "manuallyRegistered": true,
              "archived": false,
              "expanded": true
            }
          }
        }
        """#.utf8
    )
    try versionOneBytes.write(to: fileURL)

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument

    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.isProjectManuallyRegistered("project-a"))
    #expect(document.isProjectExpanded("project-a"))
    #expect(document.projectCheckoutPath("project-a") == nil)
}

@Test
func versionTwoSessionMetadataDefaultsToMainTab() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent(MetadataStore.fileName)
    let versionTwoBytes = Data(
        #"""
        {
          "schemaVersion": 2,
          "sessions": {
            "session-a": {
              "archived": true
            }
          }
        }
        """#.utf8
    )
    try versionTwoBytes.write(to: fileURL)

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument

    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.isSessionArchived("session-a"))
    #expect(document.conversationTabs("session-a") == .initial)
}
