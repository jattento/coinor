import Foundation
import Testing

@testable import Coinor

// MARK: - Classification

@Test
func upstreamCommitsAreDetectedByBotAuthor() {
    #expect(GitHubGrokChangelogLoader.isUpstream("grokkybara[bot]") == true)
    #expect(GitHubGrokChangelogLoader.isUpstream("grokkybara") == true)
    #expect(GitHubGrokChangelogLoader.isUpstream("Jose") == false)
    #expect(GitHubGrokChangelogLoader.isUpstream("") == false)
}

// MARK: - Fork summary (release notes minus validation boilerplate)

@Test
func forkSummaryKeepsFeatureBulletsAndDropsValidation() {
    let notes = """
    # Grok Build v1.0.3-overlay.5

    Proactive image handling for no-vision ("NV") models.

    ## No-vision model image handling

    A model Grok's picker marks "(NV)" used to receive an image anyway.

    ## Commit

    `b656afc80fe7c8d4d1c0a94b4ada9f96cce6d507` (the annotated tag).

    ## Validation

    - `cargo test -p overlay-core`: passed (365 tests).
    - `overlay/scripts/overlay-diff.sh`: passed (Gates 1-3).
    - `gitleaks detect`: no leaks found.
    - Release build used explicit `GROK_VERSION=1.0.3-overlay.5`.
    """
    let bullets = GitHubGrokChangelogLoader.forkSummary(notes: notes)
    // No feature bullets in the body, so the first descriptive paragraph is
    // returned instead of the validation boilerplate.
    #expect(bullets == ["Proactive image handling for no-vision (\"NV\") models."])
}

@Test
func forkSummaryKeepsOnlyRealFeatureBullets() {
    let notes = """
    # Grok Build v0.2.117-overlay.5

    Provider-aware subagent failover and unrestricted scout execution.

    ## Changes

    - Scout and explore routing use unrestricted `general-purpose` capability.
    - Transient provider failures can retry one representative model from each remaining provider.
    - Failover reuses the same subagent and child-session identity.

    ## Verification

    - `cargo test -p overlay-subagent-router`: 29 passed.
    """
    let bullets = GitHubGrokChangelogLoader.forkSummary(notes: notes)
    #expect(bullets == [
        "Scout and explore routing use unrestricted `general-purpose` capability.",
        "Transient provider failures can retry one representative model from each remaining provider.",
        "Failover reuses the same subagent and child-session identity.",
    ])
}

// MARK: - Upstream summary (Synced from monorepo bodies)

@Test
func upstreamSummaryReadsTheChangesBulletList() {
    let commits: [(author: String, message: String)] = [
        (
            "grokkybara[bot]",
            """
            Synced from monorepo

            Changes:
            - Pager: re-run a command status line on a timer via refresh_interval
            - Gate /goal verification on objective-named CI oracles
            """
        ),
        (
            "Jose",
            "overlay: proactively substitute images for no-vision models"
        ),
    ]
    let bullets = GitHubGrokChangelogLoader.upstreamSummary(commits: commits)
    #expect(bullets == [
        "Pager: re-run a command status line on a timer via refresh_interval",
        "Gate /goal verification on objective-named CI oracles",
    ])
}

// MARK: - Bundle loader

@Test
func bundledLoaderReadsTheCookedChangelogFromTheBundle() async throws {
    // Unit tests run hosted inside the application, so the default loader
    // reads the cooked resource straight from the app bundle.
    let loader = BundledGrokChangelogLoader()

    let entries = try await loader.load()

    #expect(!entries.isEmpty)
    #expect(entries.allSatisfy { !$0.tag.isEmpty })
    #expect(entries.allSatisfy { !$0.publishedAt.isEmpty })
    // The newest release comes first.
    let dates = entries.map(\.publishedAt)
    #expect(dates == dates.sorted(by: >))
}

@Test
func bundledLoaderThrowsWhenTheResourceIsMissing() async {
    let loader = BundledGrokChangelogLoader(resourceURL: nil)

    await #expect(throws: URLError.self) {
        try await loader.load()
    }
}

// MARK: - Shell model integration

@MainActor
@Test
func shellModelExposesTheChangelogLoaderFromTheEnvironment() async throws {
    struct StubLoader: GrokChangelogLoading {
        let entries: [GrokReleaseEntry]

        func load() async throws -> [GrokReleaseEntry] {
            entries
        }
    }

    let entries = [
        GrokReleaseEntry(
            tag: "v1.0.3-overlay.5",
            publishedAt: "2026-08-22",
            forkSummary: ["Adds no-vision image handling."],
            upstreamSummary: []
        ),
    ]
    let model = AppShellModel(
        environment: AppEnvironment(
            startupDiagnostics: StubChangelogDiagnostics(),
            grokChangelogLoader: StubLoader(entries: entries)
        )
    )

    #expect(model.changelogLoader is StubLoader)
    let loaded = try await model.changelogLoader.load()
    #expect(loaded == entries)
}

private struct StubChangelogDiagnostics: StartupDiagnosticsProviding {
    func runStartupChecks() async -> [StartupCheck] {
        StartupCheck.allPending
    }
}