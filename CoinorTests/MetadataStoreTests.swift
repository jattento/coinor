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
            document.setLastVisibleSession("session-a")
        }
    }

    let relaunched = try MetadataStore(directoryURL: directory)
    let document = await relaunched.currentDocument

    #expect(document.pinnedSessionIDs == ["session-a"])
    #expect(document.isProjectManuallyRegistered("project-a"))
    #expect(document.isProjectExpanded("project-a"))
    #expect(document.projectCheckoutPath("project-a") == "/tmp/Project A")
    #expect(document.lastVisibleSessionID == "session-a")
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
