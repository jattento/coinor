import Foundation
import Testing

@testable import Coinor

@Test
func telegramMetadataSurvivesRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TelegramMetadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        let store = try MetadataStore(directoryURL: directory)
        try await store.update { document in
            document.telegram.pairedUserID = TelegramUserID(9)
            document.telegram.pairedChatID = TelegramChatID(9)
            document.telegram.threadIDBySessionID["session-a"] = 44
            document.telegram.pendingPairingCode = "AB23CD45"
        }
    }

    let relaunched = try MetadataStore(directoryURL: directory)
    let document = await relaunched.currentDocument
    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.telegram.pairedUserID == TelegramUserID(9))
    #expect(document.telegram.pairedChatID == TelegramChatID(9))
    #expect(document.telegram.sessionIDByThreadID[44] == "session-a")
    #expect(document.telegram.pendingPairingCode == "AB23CD45")
}