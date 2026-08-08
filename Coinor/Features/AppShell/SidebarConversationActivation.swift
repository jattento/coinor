import Foundation

/// Pure interaction rules for sidebar conversation rows.
///
/// A conversation row carries several competing interaction paths at once:
/// `List` selection, hover-revealed pin and archive controls, a context menu,
/// and drag-and-drop reordering. Keeping the decisions here makes them
/// explicit and testable without rendering any SwiftUI.
enum SidebarConversationActivation {
    /// What a primary click on a conversation row should do.
    enum ClickAction: Equatable {
        case activate(String)
        case ignore
    }

    /// A primary click always activates its conversation, even when that
    /// conversation is already selected, so a click never leaves a row
    /// highlighted without opening it. A drag in flight owns the pointer, so a
    /// click that arrives mid-reorder is ignored.
    static func primaryClick(
        conversationID: String,
        isReordering: Bool
    ) -> ClickAction {
        isReordering ? .ignore : .activate(conversationID)
    }

    /// Trailing row controls stay mounted at all times so hover never changes
    /// row layout under the pointer. They are only visible, hit-testable, and
    /// exposed to accessibility while their own row reports hover outside a
    /// reorder.
    static func showsRowControls(
        isHovered: Bool,
        isReordering: Bool
    ) -> Bool {
        isHovered && !isReordering
    }
}

/// Keyboard navigation follows the conversation rows currently visible in the
/// sidebar rather than the complete catalog.
enum SidebarConversationNavigation {
    enum Direction: Equatable {
        case previous
        case next
    }

    static func target(
        in visibleConversationIDs: [String],
        selectedConversationID: String?,
        direction: Direction
    ) -> String? {
        guard !visibleConversationIDs.isEmpty else { return nil }
        guard let selectedConversationID,
              let selectedIndex = visibleConversationIDs.firstIndex(
                  of: selectedConversationID
              ) else {
            return direction == .previous
                ? visibleConversationIDs.last
                : visibleConversationIDs.first
        }

        switch direction {
        case .previous:
            guard selectedIndex > visibleConversationIDs.startIndex else {
                return nil
            }
            return visibleConversationIDs[
                visibleConversationIDs.index(before: selectedIndex)
            ]
        case .next:
            let nextIndex = visibleConversationIDs.index(after: selectedIndex)
            guard nextIndex < visibleConversationIDs.endIndex else {
                return nil
            }
            return visibleConversationIDs[nextIndex]
        }
    }
}
