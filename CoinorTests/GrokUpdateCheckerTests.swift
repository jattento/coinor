import Foundation
import Testing

@testable import Coinor

private enum UpdateTestError: Error {
    case failed
}

private actor FlakyUpdateChecker: GrokUpdateChecking {
    private let release: GrokRelease
    private var callCount = 0

    init(release: GrokRelease) {
        self.release = release
    }

    func availableUpdate() async throws -> GrokRelease? {
        callCount += 1
        if callCount == 1 {
            return release
        }
        throw UpdateTestError.failed
    }
}

@Test
func grokForkVersionParsesAndOrdersOverlayBuilds() throws {
    let base = try #require(
        GrokForkVersion(text: "grok 0.2.117")
    )
    let overlayOne = try #require(
        GrokForkVersion(text: "v0.2.117-overlay.1")
    )
    let overlayTwo = try #require(
        GrokForkVersion(text: "grok 0.2.117-overlay.2 (abc123)")
    )
    let newerUpstream = try #require(
        GrokForkVersion(text: "0.2.118")
    )

    #expect(base < overlayOne)
    #expect(overlayOne < overlayTwo)
    #expect(overlayTwo < newerUpstream)
    #expect(GrokForkVersion(text: "not a version") == nil)
}

@Test
func checkerReturnsOnlyStrictlyNewerReleases() async throws {
    let releaseData = Data(
        #"""
        {
          "tag_name": "v0.2.117-overlay.3",
          "html_url": "https://github.com/jattento/grok-build/releases/tag/v0.2.117-overlay.3"
        }
        """#.utf8
    )
    let checker = GitHubGrokUpdateChecker(
        fetchLatestRelease: { releaseData },
        probeInstalledVersion: {
            "grok 0.2.117-overlay.2 (abc123)"
        }
    )

    let release = try await checker.availableUpdate()

    #expect(release?.tagName == "v0.2.117-overlay.3")
}

@Test
func checkerSuppressesEqualOrOlderReleases() async throws {
    let releaseData = Data(
        #"""
        {
          "tag_name": "v0.2.117-overlay.2",
          "html_url": "https://github.com/jattento/grok-build/releases/tag/v0.2.117-overlay.2"
        }
        """#.utf8
    )
    let checker = GitHubGrokUpdateChecker(
        fetchLatestRelease: { releaseData },
        probeInstalledVersion: {
            "grok 0.2.117-overlay.2 (abc123)"
        }
    )

    #expect(try await checker.availableUpdate() == nil)
}

@MainActor
@Test
func shellModelPreservesLastSuccessfulUpdateAfterFailure() async throws {
    let release = GrokRelease(
        tagName: "v0.2.117-overlay.3",
        version: try #require(
            GrokForkVersion(text: "0.2.117-overlay.3")
        ),
        url: try #require(
            URL(
                string: "https://github.com/jattento/grok-build/releases/tag/v0.2.117-overlay.3"
            )
        )
    )
    let checker = FlakyUpdateChecker(release: release)
    let model = AppShellModel(
        environment: AppEnvironment(
            startupDiagnostics: StubUpdateDiagnostics(),
            grokUpdateChecker: checker
        )
    )

    await model.checkForGrokUpdate()
    #expect(model.availableGrokRelease == release)

    await model.checkForGrokUpdate()
    #expect(model.availableGrokRelease == release)
}

private struct StubUpdateDiagnostics: StartupDiagnosticsProviding {
    func runStartupChecks() async -> [StartupCheck] {
        StartupCheck.allPending
    }
}
