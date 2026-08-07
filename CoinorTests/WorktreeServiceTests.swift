import Foundation
import XCTest

@testable import Coinor

final class WorktreeServiceTests: XCTestCase {
    func testRemoteDefaultBranchIsFetchedAndUsedWithoutMutatingPrimaryCheckout() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let remote = try fixture.addOrigin()
        let remoteCommit = try fixture.publishRemoteCommit(remote: remote)
        let headBefore = try fixture.output(["rev-parse", "HEAD"])
        let statusBefore = try fixture.output(["status", "--porcelain=v1"])
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "remote-feature",
            from: fixture.repository
        )

        XCTAssertNil(result.warning)
        XCTAssertEqual(
            result.plan.base,
            .remoteDefault(remote: "origin", branch: "main", commit: remoteCommit)
        )
        XCTAssertEqual(
            result.plan.grokArguments,
            ["--worktree=remote-feature", "--worktree-ref=origin/main"]
        )
        XCTAssertEqual(result.plan.workingDirectory, fixture.repository.resolvingSymlinksInPath())
        XCTAssertEqual(try fixture.output(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(try fixture.output(["status", "--porcelain=v1"]), statusBefore)
    }

    func testRepositoryWithoutRemoteFallsBackToLocalHeadWithEnglishWarning() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let head = try fixture.output(["rev-parse", "HEAD"])
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "local-feature",
            from: fixture.repository
        )

        XCTAssertEqual(result.plan.base, .localHead(commit: head))
        XCTAssertEqual(result.plan.grokArguments, ["--worktree=local-feature"])
        XCTAssertTrue(result.warning?.contains("local HEAD") == true)
        XCTAssertTrue(result.warning?.contains("no remotes") == true)
    }

    func testFetchFailureFallsBackToLocalHeadAndLeavesCheckoutUntouched() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let remote = try fixture.addOrigin()
        let headBefore = try fixture.output(["rev-parse", "HEAD"])
        let statusBefore = try fixture.output(["status", "--porcelain=v1"])
        let service = WorktreeService(
            runner: RemoveRemoteBeforeFetchRunner(
                base: fixture.runner,
                remote: remote
            )
        )

        let result = try service.prepareCreation(
            named: "offline-feature",
            from: fixture.repository
        )

        XCTAssertEqual(result.plan.base, .localHead(commit: headBefore))
        XCTAssertEqual(result.plan.grokArguments, ["--worktree=offline-feature"])
        XCTAssertTrue(result.warning?.contains("local HEAD") == true)
        XCTAssertEqual(try fixture.output(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(try fixture.output(["status", "--porcelain=v1"]), statusBefore)
    }

    func testDetachedHeadFallbackUsesExactLocalCommit() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        try fixture.run(["checkout", "--detach", "HEAD"])
        let detachedCommit = try fixture.output(["rev-parse", "HEAD"])
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "detached-feature",
            from: fixture.repository
        )

        XCTAssertEqual(result.plan.base, .localHead(commit: detachedCommit))
        XCTAssertNotNil(result.warning)
    }

    func testSingleNonOriginRemoteIsSelected() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let remote = try fixture.addOrigin()
        try fixture.run(["remote", "rename", "origin", "upstream"])
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "upstream-feature",
            from: fixture.repository
        )

        guard case let .remoteDefault(selectedRemote, branch, _) = result.plan.base else {
            return XCTFail("Expected the remote default branch.")
        }
        XCTAssertEqual(remote.lastPathComponent, "Remote Repository.git")
        XCTAssertEqual(selectedRemote, "upstream")
        XCTAssertEqual(branch, "main")
        XCTAssertNil(result.warning)
    }

    func testPreferredRemoteWinsWhenSeveralRemotesExist() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let remote = try fixture.addOrigin()
        try fixture.run(["remote", "add", "backup", remote.path])
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "backup-feature",
            from: fixture.repository,
            preferredRemote: "backup"
        )

        guard case let .remoteDefault(selectedRemote, branch, _) = result.plan.base else {
            return XCTFail("Expected the preferred remote default branch.")
        }
        XCTAssertEqual(selectedRemote, "backup")
        XCTAssertEqual(branch, "main")
        XCTAssertNil(result.warning)
    }

    func testWorktreeNameIsRequiredAndRejectsUnsafePathSyntax() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let service = try WorktreeService()

        for name in [
            "",
            " feature",
            "../feature",
            "feature/name",
            ".hidden",
            "-flag",
            "feature.",
            "feature.lock",
            "HEAD",
        ] {
            XCTAssertThrowsError(
                try service.prepareCreation(named: name, from: fixture.repository)
            ) { error in
                XCTAssertEqual(error as? GitServiceError, .invalidWorktreeName(name))
                XCTAssertTrue(error.localizedDescription.contains("worktree name"))
            }
        }
    }

    func testValidWorktreeNameAndRepositoryPathWithSpacesRemainStructuredArguments() throws {
        let fixture = try GitRepositoryFixture(label: #function)
        let service = try WorktreeService()

        let result = try service.prepareCreation(
            named: "feature_2026.08-07",
            from: fixture.repository
        )

        XCTAssertTrue(fixture.repository.path.contains(" "))
        XCTAssertEqual(result.plan.name.rawValue, "feature_2026.08-07")
        XCTAssertEqual(result.plan.workingDirectory, fixture.repository.resolvingSymlinksInPath())
    }
}
