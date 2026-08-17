import Foundation

/// A local conversation that can have a Telegram topic.
struct TelegramCatalogConversation: Equatable, Sendable {
    var sessionID: String
    var title: String
    var lastActivityAt: Date?
    var isArchived: Bool
}

/// Chooses which Mac conversations get Telegram topics, newest Grok
/// activity first. Telegram has no bot API to reorder topics; last-message
/// order is what the client shows, so we create the newest ones first.
enum TelegramTopicCatalog {
    static let topicLimit = 40

    static func publish(
        _ conversations: [TelegramCatalogConversation]
    ) -> [TelegramCatalogConversation] {
        conversations
            .filter { !$0.isArchived && !$0.sessionID.isEmpty }
            .sorted(by: moreRecentlyUsed)
            .prefix(topicLimit)
            .map { item in
                var copy = item
                copy.title = displayTitle(item.title)
                return copy
            }
    }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Conversation" : trimmed
        if base.count <= 128 {
            return base
        }
        return String(base.prefix(128))
    }

    private static func moreRecentlyUsed(
        _ lhs: TelegramCatalogConversation,
        _ rhs: TelegramCatalogConversation
    ) -> Bool {
        let lhsDate = lhs.lastActivityAt ?? .distantPast
        let rhsDate = rhs.lastActivityAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.sessionID < rhs.sessionID
    }
}
