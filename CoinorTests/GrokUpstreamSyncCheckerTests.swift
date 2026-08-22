import Foundation
import Testing

@testable import Coinor

// Field semantics, verified against the live GitHub compare endpoint for
// `jattento/grok-build main...xai-org:main`: `ahead_by` is how many commits
// `head` (upstream `xai-org/main`) has that `base` (fork `main`) does not —
// i.e. the fork's missing commits. `behind_by` is the reverse (the fork's own
// overlay-only commits) and is not what this checker reports.

@Test
func upstreamSyncCheckerReportsMissingCommitsWhenForkTrailsUpstream() async throws {
    let compareData = Data(
        #"""
        {
          "status": "behind",
          "ahead_by": 5,
          "behind_by": 0,
          "total_commits": 5,
          "html_url": "https://github.com/jattento/grok-build/compare/main...xai-org:main"
        }
        """#.utf8
    )
    let checker = GitHubGrokUpstreamSyncChecker(fetchCompare: { compareData })

    let status = try await checker.missingUpstreamCommits()

    #expect(status?.missingCommitCount == 5)
    #expect(
        status?.url
            == URL(
                string: "https://github.com/jattento/grok-build/compare/main...xai-org:main"
            )
    )
}

@Test
func upstreamSyncCheckerReturnsNilWhenForkIsCaughtUp() async throws {
    let compareData = Data(
        #"""
        {
          "status": "diverged",
          "ahead_by": 0,
          "behind_by": 51,
          "total_commits": 0,
          "html_url": "https://github.com/jattento/grok-build/compare/main...xai-org:main"
        }
        """#.utf8
    )
    let checker = GitHubGrokUpstreamSyncChecker(fetchCompare: { compareData })

    #expect(try await checker.missingUpstreamCommits() == nil)
}

@MainActor
@Test
func shellModelSurfacesMissingUpstreamCommitsFromTheRealChecker() async throws {
    let compareData = Data(
        #"""
        {
          "ahead_by": 3,
          "behind_by": 51,
          "html_url": "https://github.com/jattento/grok-build/compare/main...xai-org:main"
        }
        """#.utf8
    )
    let model = AppShellModel(
        environment: AppEnvironment(
            startupDiagnostics: StubUpstreamSyncDiagnostics(),
            grokUpstreamSyncChecker: GitHubGrokUpstreamSyncChecker(
                fetchCompare: { compareData }
            )
        )
    )

    await model.checkForMissingUpstreamGrokCommits()

    #expect(model.missingUpstreamGrokCommits?.missingCommitCount == 3)
}

private struct StubUpstreamSyncDiagnostics: StartupDiagnosticsProviding {
    func runStartupChecks() async -> [StartupCheck] {
        StartupCheck.allPending
    }
}
