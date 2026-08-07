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
        executable: Set<String> = [],
        data: [String: Data] = [:]
    ) -> StartupFileProbe {
        StartupFileProbe(
            exists: { existing.contains($0.path) || executable.contains($0.path) },
            isExecutable: { executable.contains($0.path) },
            readData: { data[$0.path] }
        )
    }

    private func everythingPresent(in paths: StartupPaths) -> StartupFileProbe {
        let relay = Data("relay".utf8)
        return probe(
            existing: [
                paths.ghosttyShellIntegration.path,
                paths.ghosttyTerminfo.path,
                paths.hookRegistration.path,
                paths.leaderSocket.path,
            ],
            executable: [
                paths.grokExecutable.path,
                paths.hookRelay.path,
                paths.bundledHookRelay.path,
            ],
            data: [
                paths.hookRegistration.path: validHookRegistration(paths: paths),
                paths.hookRelay.path: relay,
                paths.bundledHookRelay.path: relay,
            ]
        )
    }

    private func validHookRegistration(paths: StartupPaths) -> Data {
        let handler: [String: Any] = [
            "type": "command",
            "command": paths.hookRelay.path,
            "timeout": 2,
            "env": [
                "COINOR_HOOK_SOCKET": paths.leaderSocket
                    .deletingLastPathComponent()
                    .appendingPathComponent("hook.sock")
                    .path,
                "COINOR_HOOK_TIMEOUT_MS": "150",
            ],
        ]
        let document: [String: Any] = [
            "_coinor": [
                "schemaVersion": 1,
                "purpose": "Coinor lifecycle relay",
            ],
            "hooks": Dictionary(
                uniqueKeysWithValues: HookInstallationValidator.events.map {
                    ($0, [["hooks": [handler]]])
                }
            ),
        ]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    private func checks(_ probe: StartupFileProbe) async -> [StartupCheck.Kind: StartupCheck] {
        let reported = await EnvironmentStartupDiagnostics(paths: paths, probe: probe).runStartupChecks()
        return Dictionary(uniqueKeysWithValues: reported.map { ($0.kind, $0) })
    }

    // MARK: - Startup check contract

    func testStartupCheckKindsAreStableAndOrdered() {
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(\.rawValue),
            ["grokExecutable", "ghosttyRuntime", "hookRegistration", "leaderSocket"]
        )
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(\.title),
            ["Grok Executable", "Ghostty Runtime", "Hook Registration", "Leader Socket"]
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
        XCTAssertEqual(reported[.hookRegistration]?.detail, "~/.grok/hooks")
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

    func testPartialHookInstallationWarnsInsteadOfFailing() async {
        let handlerOnly = await checks(probe(existing: [paths.hookRegistration.path]))
        XCTAssertEqual(handlerOnly[.hookRegistration]?.status, .warning)
        XCTAssertEqual(handlerOnly[.hookRegistration]?.detail, "Relay missing in ~/.grok/hooks")

        let relayOnly = await checks(probe(existing: [paths.hookRelay.path]))
        XCTAssertEqual(relayOnly[.hookRegistration]?.status, .warning)
        XCTAssertEqual(relayOnly[.hookRegistration]?.detail, "Handler missing in ~/.grok/hooks")
    }

    func testUnregisteredHookFails() async {
        let reported = await checks(probe(existing: []))

        XCTAssertEqual(reported[.hookRegistration]?.status, .failed)
        XCTAssertEqual(reported[.hookRegistration]?.detail, "Not registered in ~/.grok/hooks")
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
            StartupCheck(kind: .hookRegistration, status: .passed, detail: "~/.grok/hooks"),
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
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Coinor")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "13.0")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String, "en")
    }

    func testAccessibilityIdentifiersMatchTheStringsUsedByUITests() {
        XCTAssertEqual(AppShellIdentifier.sidebar, "AppShellSidebar")
        XCTAssertEqual(AppShellIdentifier.pinnedSection, "AppShellSidebarPinned")
        XCTAssertEqual(AppShellIdentifier.projectsSection, "AppShellSidebarProjects")
        XCTAssertEqual(AppShellIdentifier.terminalRegion, "AppShellTerminalRegion")
        XCTAssertEqual(AppShellIdentifier.startupDiagnostics, "AppShellStartupDiagnostics")
        XCTAssertEqual(AppShellIdentifier.refreshStartupChecks, "AppShellRefreshStartupChecks")
        XCTAssertEqual(
            StartupCheck.Kind.allCases.map(AppShellIdentifier.startupCheckRow),
            [
                "AppShellStartupCheck.grokExecutable",
                "AppShellStartupCheck.ghosttyRuntime",
                "AppShellStartupCheck.hookRegistration",
                "AppShellStartupCheck.leaderSocket",
            ]
        )
    }
}

private struct StubDiagnostics: StartupDiagnosticsProviding {
    let checks: [StartupCheck]

    func runStartupChecks() async -> [StartupCheck] {
        checks
    }
}
