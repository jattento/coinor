import Foundation
import Testing

@testable import Coinor

@Test
func telegramTopicCatalogOrdersByGrokActivityAndDropsArchives() {
    let old = TelegramCatalogConversation(
        sessionID: "old",
        title: "Old",
        lastActivityAt: Date(timeIntervalSince1970: 10),
        isArchived: false
    )
    let recent = TelegramCatalogConversation(
        sessionID: "recent",
        title: "Recent",
        lastActivityAt: Date(timeIntervalSince1970: 100),
        isArchived: false
    )
    let archived = TelegramCatalogConversation(
        sessionID: "archived",
        title: "Archived",
        lastActivityAt: Date(timeIntervalSince1970: 200),
        isArchived: true
    )
    let published = TelegramTopicCatalog.publish([old, archived, recent])
    #expect(published.map(\.sessionID) == ["recent", "old"])
}

@Test
func telegramTopicCatalogCapsHowManyTopicsAreCreated() {
    let conversations = (0..<50).map { index in
        TelegramCatalogConversation(
            sessionID: "s-\(index)",
            title: "T\(index)",
            lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isArchived: false
        )
    }
    let published = TelegramTopicCatalog.publish(conversations)
    #expect(published.count == TelegramTopicCatalog.topicLimit)
    #expect(published.first?.sessionID == "s-49")
    #expect(published.last?.sessionID == "s-10")
}

@Test
func telegramTopicCatalogUsesAFallbackTitleAndTruncates() {
    #expect(TelegramTopicCatalog.displayTitle("  ") == "Conversation")
    #expect(TelegramTopicCatalog.displayTitle(String(repeating: "a", count: 200)).count == 128)
}
