import Foundation
import Testing

@testable import Coinor

@Test
func fileTokenStoreRoundTripsAConfigFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("coinor-telegram-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("telegram.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileTelegramTokenStore(fileURL: file)
    #expect(try store.load() == nil)
    try store.save("  123:ABC  ")
    #expect(try store.load() == "123:ABC")

    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = permissions[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)

    let body = try String(contentsOf: file, encoding: .utf8)
    #expect(body.contains("bot_token = \"123:ABC\""))
    #expect(!body.contains("  123:ABC  "))

    try store.delete()
    #expect(try store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test
func fileTokenStoreParsesQuotedUnquotedAndBareTokens() {
    #expect(FileTelegramTokenStore.parse("bot_token = 123:ABC") == "123:ABC")
    #expect(FileTelegramTokenStore.parse("bot_token = \"123:ABC\"") == "123:ABC")
    #expect(FileTelegramTokenStore.parse("bot_token = '123:ABC'") == "123:ABC")
    #expect(FileTelegramTokenStore.parse("# comment\n\n123:ABC\n") == "123:ABC")
    #expect(FileTelegramTokenStore.parse("# only comments\n") == nil)
    #expect(FileTelegramTokenStore.parse("") == nil)
}

@Test
func fileTokenStoreMigratesOnceFromAnotherStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("coinor-telegram-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("telegram.toml")
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacy = MemoryTelegramTokenStore()
    try legacy.save("legacy-token")
    let store = FileTelegramTokenStore(fileURL: file, migrateFrom: legacy)

    #expect(try store.load() == "legacy-token")
    #expect(try legacy.load() == nil)
    #expect(try store.load() == "legacy-token")
}

@Test
func fileTokenStoreRejectsAnEmptyToken() {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("coinor-telegram-empty-\(UUID().uuidString)")
    let store = FileTelegramTokenStore(fileURL: file)
    #expect(throws: TelegramCredentialError.emptyToken) {
        try store.save("   ")
    }
}
