import CoreGraphics
import Testing

@testable import Coinor

@Suite
struct ProjectDropOrderTests {
    @Test
    func projectDropPayloadAcceptsOnlyKnownPrefixedProjects() {
        let projectIDs = ["project-a", "project-b"]
        let validPayload = ProjectDropPayload.encoded(
            projectID: "project-b"
        )

        #expect(
            ProjectDropPayload.projectID(
                from: validPayload,
                validProjectIDs: projectIDs
            ) == "project-b"
        )
        #expect(
            ProjectDropPayload.projectID(
                from: "project-b",
                validProjectIDs: projectIDs
            ) == nil
        )
        #expect(
            ProjectDropPayload.projectID(
                from: ProjectDropPayload.encoded(
                    projectID: "unknown"
                ),
                validProjectIDs: projectIDs
            ) == nil
        )
    }

    @Test
    func projectDropMovesUpwardBeforeTarget() {
        let reordered = ProjectDropOrder.reorderedProjectIDs(
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
        let reordered = ProjectDropOrder.reorderedProjectIDs(
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

        let alreadyBeforeTarget = ProjectDropOrder.reorderedProjectIDs(
            projectIDs,
            moving: "b",
            relativeTo: "c",
            dropY: 2,
            targetHeight: 20
        )
        let sameTarget = ProjectDropOrder.reorderedProjectIDs(
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
