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
