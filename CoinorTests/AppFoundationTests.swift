import AppKit
import XCTest
@testable import Coinor

final class AppFoundationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private let bundleResources = URL(fileURLWithPath: "/Applications/Coinor.app/Contents/Resources", isDirectory: true)

    private var paths: StartupPaths {
        StartupPaths.live(homeDirectory: home, bundleResources: bundleResources)
    }

    private func probe(
        existing: Set<String>,
        executable: Set<String> = []
    ) -> StartupFileProbe {
        StartupFileProbe(
            exists: { existing.contains($0.path) || executable.contains($0.path) },
            isExecutable: { executable.contains($0.path) }
        )
    }

    private func everythingPresent(in paths: StartupPaths) -> StartupFileProbe {
        return probe(
            existing: [
                paths.ghosttyShellIntegration.path,
                paths.ghosttyTerminfo.path,
                paths.leaderSocket.path,
            ],
            executable: [
                paths.grokExecutable.path,
            ]
        )
    }

    private func checks(_ probe: StartupFileProbe) async -> [StartupCheck.Kind: StartupCheck] {
        let reported = await EnvironmentStartupDiagnostics(paths: paths, probe: probe).runStartupChecks()
        return Dictionary(uniqueKeysWithValues: reported.map { ($0.kind, $0) })
    }

    // MARK: - Startup check contract

    func testStartupCheckKindsAreStableAndOrdered() {
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(\.rawValue),
            ["grokExecutable", "ghosttyRuntime", "leaderSocket"]
        )
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(\.title),
            ["Grok Executable", "Ghostty Runtime", "Leader Socket"]
        )
    }

    func testEveryCheckStartsPending() {
        XCTAssertEqual(StartupCheck.allPending.map(\.kind), StartupCheck.Kind.allCases)
        XCTAssertTrue(StartupCheck.allPending.allSatisfy { $0.status == .pending })
    }

    func testDiagnosticsReportOneResultPerKindInDeclaredOrder() async {
        let reported = await EnvironmentStartupDiagnostics(
            paths: paths,
            probe: everythingPresent(in: paths)
        ).runStartupChecks()

        XCTAssertEqual(reported.map(\.kind), StartupCheck.Kind.allCases)
    }

    // MARK: - Environment probing

    func testCompleteEnvironmentPassesEveryCheck() async {
        let reported = await checks(everythingPresent(in: paths))

        XCTAssertEqual(reported.values.filter { $0.status != .passed }, [])
        XCTAssertEqual(reported[.grokExecutable]?.detail, "~/bin/grok")
        XCTAssertEqual(
            reported[.leaderSocket]?.detail,
            "~/Library/Application Support/Coinor/grok-leader.sock"
        )
    }

    func testMissingGrokExecutableFails() async {
        let reported = await checks(probe(existing: []))

        XCTAssertEqual(reported[.grokExecutable]?.status, .failed)
        XCTAssertEqual(reported[.grokExecutable]?.detail, "Missing at ~/bin/grok")
    }

    func testPresentButNonExecutableGrokFails() async {
        let reported = await checks(probe(existing: [paths.grokExecutable.path]))

        XCTAssertEqual(reported[.grokExecutable]?.status, .failed)
        XCTAssertEqual(reported[.grokExecutable]?.detail, "Not executable at ~/bin/grok")
    }

    func testMissingBundledGhosttyResourcesFail() async {
        let reported = await checks(probe(existing: []))

        XCTAssertEqual(reported[.ghosttyRuntime]?.status, .failed)
        XCTAssertEqual(reported[.ghosttyRuntime]?.detail, "Bundled resources missing")
    }

    func testAbsentLeaderSocketWarnsBecauseItStartsOnDemand() async {
        let reported = await checks(probe(existing: []))

        XCTAssertEqual(reported[.leaderSocket]?.status, .warning)
        XCTAssertEqual(
            reported[.leaderSocket]?.detail,
            "Not running at ~/Library/Application Support/Coinor/grok-leader.sock"
        )
    }

    func testDisplayPathOnlyAbbreviatesTheHomeDirectory() {
        XCTAssertEqual(paths.display(home), "~")
        XCTAssertEqual(paths.display(URL(fileURLWithPath: "/Users/tester/bin")), "~/bin")
        XCTAssertEqual(paths.display(URL(fileURLWithPath: "/Users/testerly/bin")), "/Users/testerly/bin")
        XCTAssertEqual(paths.display(URL(fileURLWithPath: "/usr/local/bin")), "/usr/local/bin")
    }

    // MARK: - Shell model

    @MainActor
    func testShellModelStartsPendingAndPublishesProviderResults() async {
        let provided = [
            StartupCheck(kind: .grokExecutable, status: .passed, detail: "~/bin/grok"),
            StartupCheck(kind: .ghosttyRuntime, status: .failed, detail: "Bundled resources missing"),
            StartupCheck(kind: .leaderSocket, status: .warning, detail: "Not running"),
        ]
        let model = AppShellModel(environment: AppEnvironment(startupDiagnostics: StubDiagnostics(checks: provided)))

        XCTAssertEqual(model.startupChecks, StartupCheck.allPending)
        XCTAssertFalse(model.isRunningStartupChecks)

        await model.runStartupChecks()

        XCTAssertEqual(model.startupChecks, provided)
        XCTAssertFalse(model.isRunningStartupChecks)
        XCTAssertEqual(model.unresolvedStartupCheckCount, 2)
    }

    // MARK: - Bundle and identifiers

    func testApplicationBundleMatchesTheDeclaredIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.coinor.Coinor")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            "Conan Code"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "Conan Code"
        )
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "13.0")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String, "en")
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "NSMicrophoneUsageDescription"
            ) as? String,
            "Conan Code uses the microphone only when you start Voice to transcribe speech into your Grok prompt."
        )
    }

    func testApplicationBundleContainsTerminalControlResources() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let expectedFiles = [
            "coinorctl",
            "conan-code-long-running-SKILL.md",
            "conan-code-terminal.sh",
            "managed-terminal-bootstrap.zsh",
        ]

        for filename in expectedFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: resources
                        .appendingPathComponent(filename)
                        .path
                ),
                "Missing bundled terminal-control resource: \(filename)"
            )
        }
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: resources
                    .appendingPathComponent("coinorctl")
                    .path
            )
        )
    }

    func testLongRunningSkillRequiresAutomaticUseAndCleanup() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let skillURL = resources.appendingPathComponent(
            "conan-code-long-running-SKILL.md"
        )
        let skill = try String(contentsOf: skillURL, encoding: .utf8)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let requiredPolicy = [
            "automatically create and control visible conan code terminal tabs",
            "even when the user does not mention tabs or this skill",
            "development server",
            "database",
            "docker compose stack",
            "do not ask the user whether to open a tab",
            "does not by itself mean to leave it running after the task",
            "before sending the final response",
            "close every managed tab you created",
            "even when the command or wider task failed",
        ]

        for policy in requiredPolicy {
            XCTAssertTrue(
                skill.contains(policy),
                "Missing long-running skill policy: \(policy)"
            )
        }
    }

    func testRuntimeEnvironmentCanIsolateApplicationSupport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coinor-Isolated", isDirectory: true)

        let resolved = try CoinorRuntimeEnvironment
            .applicationSupportDirectory(
                environment: [
                    CoinorRuntimeEnvironment
                        .applicationSupportDirectoryKey: directory.path,
                ]
            )

        XCTAssertEqual(resolved, directory.standardizedFileURL)
        XCTAssertEqual(
            try GrokLeaderSocket.coinorDefault(
                supportDirectory: resolved
            ).path,
            directory
                .appendingPathComponent("grok-leader.sock")
                .path
        )
    }

    func testAccessibilityIdentifiersMatchTheStringsUsedByUITests() {
        XCTAssertEqual(AppShellIdentifier.sidebar, "AppShellSidebar")
        XCTAssertEqual(AppShellIdentifier.pinnedSection, "AppShellSidebarPinned")
        XCTAssertEqual(AppShellIdentifier.projectsSection, "AppShellSidebarProjects")
        XCTAssertEqual(
            AppShellIdentifier.conversationSearchField,
            "AppShellConversationSearch"
        )
        XCTAssertEqual(
            AppShellIdentifier.searchResultsSection,
            "AppShellSearchResults"
        )
        XCTAssertEqual(
            AppShellIdentifier.searchEmptyState,
            "AppShellSearchEmptyState"
        )
        XCTAssertEqual(
            AppShellIdentifier.grokUpdateButton,
            "AppShellGrokUpdate"
        )
        XCTAssertEqual(
            AppShellIdentifier.grokUpstreamSyncButton,
            "AppShellGrokUpstreamSync"
        )
        XCTAssertEqual(AppShellIdentifier.settingsButton, "AppShellSettings")
        XCTAssertEqual(AppShellIdentifier.settingsPanel, "AppShellSettingsPanel")
        XCTAssertEqual(AppShellIdentifier.settingsClose, "AppShellSettingsClose")
        XCTAssertEqual(
            AppShellIdentifier.settingsTab("grokAgents"),
            "AppShellSettingsTab.grokAgents"
        )
        XCTAssertEqual(
            AppShellIdentifier.settingsTerminal("grokAgents"),
            "AppShellSettingsTerminal.grokAgents"
        )
        XCTAssertEqual(AppShellIdentifier.terminalRegion, "AppShellTerminalRegion")
        XCTAssertEqual(AppShellIdentifier.startupDiagnostics, "AppShellStartupDiagnostics")
        XCTAssertEqual(AppShellIdentifier.refreshStartupChecks, "AppShellRefreshStartupChecks")
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(AppShellIdentifier.startupCheckRow),
            [
                "AppShellStartupCheck.grokExecutable",
                "AppShellStartupCheck.ghosttyRuntime",
                "AppShellStartupCheck.leaderSocket",
            ]
        )
    }

    func testProjectAppearanceCatalogIsCompleteAndRenderable() {
        XCTAssertEqual(ProjectIconChoice.allCases.count, 30)
        XCTAssertEqual(ProjectIconColorChoice.allCases.count, 8)
        XCTAssertTrue(
            ProjectIconChoice.allCases.allSatisfy {
                NSImage(
                    systemSymbolName: $0.systemName,
                    accessibilityDescription: nil
                ) != nil
            }
        )
        XCTAssertEqual(
            ProjectIconChoice.choice(for: "server.rack"),
            .terminal
        )
        XCTAssertEqual(
            ProjectIconChoice.choice(
                for: "wrench.and.screwdriver"
            ),
            .tools
        )
    }
}

private struct StubDiagnostics: StartupDiagnosticsProviding {
    let checks: [StartupCheck]

    func runStartupChecks() async -> [StartupCheck] {
        checks
    }
}
