import Testing
import UniformTypeIdentifiers

@testable import Coinor

@Suite
struct ProjectDropOrderTests {
    @Test
    func projectPayloadAdvertisesOnlyThePrivateProjectType() {
        let provider = SidebarReorderPayload.provider(
            scope: .projects,
            itemID: "project-b"
        )

        #expect(
            provider.hasItemConformingToTypeIdentifier(
                UTType.coinorProjectReorder.identifier
            )
        )
        #expect(
            !provider.hasItemConformingToTypeIdentifier(
                UTType.plainText.identifier
            )
        )
    }

    @Test
    func projectDropMovesUpwardBeforeTarget() {
        let reordered = SidebarReorderOrder.reorderedIDs(
            ["a", "b", "c", "d"],
            moving: "d",
            relativeTo: "b",
            dropY: 2,
            targetHeight: 20
        )

        #expect(reordered == ["a", "d", "b", "c"])
    }

    @Test
    func projectDropMovesDownwardAfterTarget() {
        let reordered = SidebarReorderOrder.reorderedIDs(
            ["a", "b", "c", "d"],
            moving: "a",
            relativeTo: "c",
            dropY: 18,
            targetHeight: 20
        )

        #expect(reordered == ["b", "c", "a", "d"])
    }

    @Test
    func projectDropLeavesAnEquivalentOrderUnchanged() {
        let projectIDs = ["a", "b", "c", "d"]

        let alreadyBeforeTarget = SidebarReorderOrder.reorderedIDs(
            projectIDs,
            moving: "b",
            relativeTo: "c",
            dropY: 2,
            targetHeight: 20
        )
        let sameTarget = SidebarReorderOrder.reorderedIDs(
            projectIDs,
            moving: "b",
            relativeTo: "b",
            dropY: 18,
            targetHeight: 20
        )

        #expect(alreadyBeforeTarget == projectIDs)
        #expect(sameTarget == projectIDs)
    }
}
