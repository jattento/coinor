import XCTest

@testable import Coinor

final class GitProjectResolverTests: XCTestCase {
    func testMainCheckoutAndLinkedWorktreeShareCanonicalIdentity() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let linkedWorktree = try fixture.addLinkedWorktree()
        let resolver = try GitProjectResolver()

        let main = try resolver.resolve(checkout: fixture.repository)
        let linked = try resolver.resolve(checkout: linkedWorktree)

        XCTAssertEqual(main.identity, linked.identity)
        XCTAssertEqual(main.commonDirectory, linked.commonDirectory)
        XCTAssertEqual(main.mainCheckout, fixture.repository.resolvingSymlinksInPath())
        XCTAssertEqual(linked.mainCheckout, main.mainCheckout)
    }

    func testIndependentCloneHasDistinctIdentityEvenWithSameSource() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let clone = try fixture.cloneIndependently()
        let resolver = try GitProjectResolver()

        let original = try resolver.resolve(checkout: fixture.repository)
        let independent = try resolver.resolve(checkout: clone)

        XCTAssertNotEqual(original.identity, independent.identity)
        XCTAssertNotEqual(original.commonDirectory, independent.commonDirectory)
        XCTAssertEqual(independent.mainCheckout, clone.resolvingSymlinksInPath())
    }

    func testDetachedHeadStillResolvesProjectAndPrimaryCheckout() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let linkedWorktree = try fixture.addLinkedWorktree(named: "Detached Worktree")
        try fixture.run(["checkout", "--detach", "HEAD"], at: linkedWorktree)
        let resolver = try GitProjectResolver()

        let resolution = try resolver.resolve(checkout: linkedWorktree)

        XCTAssertEqual(
            resolution.mainCheckout,
            fixture.repository.resolvingSymlinksInPath()
        )
        XCTAssertEqual(
            resolution.identity,
            try resolver.resolve(checkout: fixture.repository).identity
        )
    }

    func testPathsWithSpacesArePreservedWithoutShellInterpretation() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let linkedWorktree = try fixture.addLinkedWorktree(named: "A Worktree With Spaces")
        let resolver = try GitProjectResolver()

        let resolution = try resolver.resolve(checkout: linkedWorktree)

        XCTAssertTrue(linkedWorktree.path.contains(" "))
        XCTAssertEqual(
            resolution.mainCheckout,
            fixture.repository.resolvingSymlinksInPath()
        )
    }

    func testSourceWorkspaceWinsOverAStandaloneWorktreeClone() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let standalone = try fixture.cloneIndependently(
            named: "Standalone Grok Worktree"
        )
        let resolver = try GitProjectResolver()
        let session = try persistedSession(
            cwd: standalone.path,
            gitRootDirectory: standalone.path,
            sourceWorkspaceDirectory: fixture.repository.path
        )

        let resolution = try resolver.resolve(projectFor: session)

        XCTAssertEqual(
            resolution.identity,
            try resolver.resolve(checkout: fixture.repository).identity
        )
        XCTAssertEqual(
            resolution.mainCheckout,
            fixture.repository.resolvingSymlinksInPath()
        )
    }

    func testGrokSourceMarkerGroupsAStandaloneWorktreeWithoutCatalogSource()
        throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let standalone = try fixture.cloneIndependently(
            named: "Marker Only Grok Worktree"
        )
        let marker = standalone
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent(
                "grok-worktree-source",
                isDirectory: false
            )
        try Data(fixture.repository.path.utf8).write(to: marker)
        let resolver = try GitProjectResolver()
        let session = try persistedSession(
            cwd: standalone.path,
            gitRootDirectory: standalone.path,
            worktreeLabel: "marker-only"
        )

        let resolution = try resolver.resolve(projectFor: session)

        XCTAssertEqual(
            resolution.identity,
            try resolver.resolve(checkout: fixture.repository).identity
        )
        XCTAssertEqual(
            resolution.mainCheckout,
            fixture.repository.resolvingSymlinksInPath()
        )
    }

    private func persistedSession(
        cwd: String,
        gitRootDirectory: String,
        sourceWorkspaceDirectory: String? = nil,
        worktreeLabel: String? = nil
    ) throws -> GrokPersistedSession {
        var raw: [String: GrokJSONValue] = [
            "sessionId": "00000000-0000-7000-8000-000000000099",
            "cwd": .string(cwd),
            "gitRootDir": .string(gitRootDirectory),
        ]
        if let sourceWorkspaceDirectory {
            raw["sourceWorkspaceDir"] = .string(sourceWorkspaceDirectory)
        }
        if let worktreeLabel {
            raw["worktreeLabel"] = .string(worktreeLabel)
        }
        return try GrokPersistedSession(raw: .object(raw))
    }
}
