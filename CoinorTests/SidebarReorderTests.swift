import CoreGraphics
import Testing

@testable import Coinor

@Suite
struct SidebarReorderOrderTests {
    @Test
    func movesThePlaceholderBeforeAndAfterTargets() {
        #expect(
            SidebarReorderOrder.reorderedIDs(
                ["a", "b", "c", "d"],
                moving: "d",
                relativeTo: "b",
                dropY: 2,
                targetHeight: 20
            ) == ["a", "d", "b", "c"]
        )
        #expect(
            SidebarReorderOrder.reorderedIDs(
                ["a", "b", "c", "d"],
                moving: "a",
                relativeTo: "c",
                dropY: 18,
                targetHeight: 20
            ) == ["b", "c", "a", "d"]
        )
    }

    @Test
    func reconciliationDropsVanishedRowsAndAppendsNewRows() {
        #expect(
            SidebarReorderOrder.reconciled(
                previewOrder: ["c", "missing", "a"],
                currentOrder: ["a", "b", "c", "new"]
            ) == ["c", "a", "b", "new"]
        )
    }
}

@MainActor
@Suite
struct SidebarReorderModelTests {
    @Test
    func previewMovesContinuouslyAndCommitsItsCurrentOrder() throws {
        let model = SidebarReorderModel(monitorsMouseButton: false)
        _ = model.begin(
            scope: .projects,
            itemID: "a",
            currentOrder: ["a", "b", "c"]
        )

        #expect(
            model.updatePreview(
                scope: .projects,
                targetID: "c",
                dropY: 20,
                targetHeight: 20,
                currentOrder: ["a", "b", "c"]
            )
        )
        #expect(
            model.displayOrder(
                for: .projects,
                currentOrder: ["a", "b", "c"]
            ) == ["b", "c", "a"]
        )

        let committed = try #require(
            model.commit(
                scope: .projects,
                currentOrder: ["a", "b", "c"]
            )
        )
        #expect(committed == ["b", "c", "a"])
        #expect(!model.isActive)
    }

    @Test
    func aConversationCannotCrossReorderScopes() {
        let model = SidebarReorderModel(monitorsMouseButton: false)
        _ = model.begin(
            scope: .project("project-a"),
            itemID: "session-a",
            currentOrder: ["session-a", "session-b"]
        )

        #expect(!model.canHandle(.pinned))
        #expect(
            !model.updatePreview(
                scope: .project("project-b"),
                targetID: "session-c",
                dropY: 10,
                targetHeight: 24,
                currentOrder: ["session-c"]
            )
        )
        #expect(
            model.displayOrder(
                for: .project("project-a"),
                currentOrder: ["session-a", "session-b"]
            ) == ["session-a", "session-b"]
        )
    }

    @Test
    func cancellationRestoresTheCatalogDrivenOrder() {
        let model = SidebarReorderModel(monitorsMouseButton: false)
        _ = model.begin(
            scope: .pinned,
            itemID: "first",
            currentOrder: ["first", "second"]
        )
        _ = model.updatePreview(
            scope: .pinned,
            targetID: "second",
            dropY: 24,
            targetHeight: 24,
            currentOrder: ["first", "second"]
        )

        model.cancel()

        #expect(
            model.displayOrder(
                for: .pinned,
                currentOrder: ["first", "second"]
            ) == ["first", "second"]
        )
    }
}

@Suite
struct SidebarConversationActivationTests {
    @Test
    func primaryClickActivatesEvenTheAlreadySelectedRow() {
        #expect(
            SidebarConversationActivation.primaryClick(
                conversationID: "session-a",
                isReordering: false
            ) == .activate("session-a")
        )
    }

    @Test
    func primaryClickIsIgnoredWhileAReorderOwnsThePointer() {
        #expect(
            SidebarConversationActivation.primaryClick(
                conversationID: "session-a",
                isReordering: true
            ) == .ignore
        )
    }

    @Test
    func rowControlsFollowHoverAndStayHiddenDuringAReorder() {
        #expect(
            SidebarConversationActivation.showsRowControls(
                isHovered: true,
                isReordering: false
            )
        )
        #expect(
            !SidebarConversationActivation.showsRowControls(
                isHovered: false,
                isReordering: false
            )
        )
        #expect(
            !SidebarConversationActivation.showsRowControls(
                isHovered: true,
                isReordering: true
            )
        )
        #expect(
            !SidebarConversationActivation.showsRowControls(
                isHovered: false,
                isReordering: true
            )
        )
    }
}
