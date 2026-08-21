import Foundation
import Testing

@testable import Coinor

@Test
func visibleCadenceAlwaysWinsRegardlessOfActivity() {
    let cadence = BrowserMirrorPoller.cadence(
        isVisible: true,
        lastActivityAt: Date(timeIntervalSince1970: 0),
        now: Date(timeIntervalSince1970: 100_000)
    )

    #expect(cadence == .visible)
}

@Test
func backgroundedCadenceAppliesWithRecentActivity() {
    let now = Date()
    let cadence = BrowserMirrorPoller.cadence(
        isVisible: false,
        lastActivityAt: now.addingTimeInterval(-30),
        now: now
    )

    #expect(cadence == .backgrounded)
}

@Test
func idleCadenceAppliesPastTheIdleThreshold() {
    let now = Date()
    let cadence = BrowserMirrorPoller.cadence(
        isVisible: false,
        lastActivityAt: now.addingTimeInterval(
            -BrowserMirrorPoller.idleThreshold - 1
        ),
        now: now
    )

    #expect(cadence == .idle)
}

@Test
@MainActor
func startWithAnUnresolvableLocatorReportsUnavailableWithoutSpawningAnything() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    let locator = EgoBrowserLocator(
        environment: ["PATH": "/usr/bin:/bin"],
        homeDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    )

    BrowserMirrorPoller.start(
        for: tab,
        locator: locator,
        isVisible: { true }
    )

    guard case .unavailable(let reason) = tab.state else {
        Issue.record("expected .unavailable, got \(tab.state)")
        return
    }
    #expect(reason.contains("not found"))
}

/// Drives the real poll loop against a real, stubbed `ego-browser`
/// subprocess (the shipped `EgoBrowserScreenshotClient`, not a
/// reimplementation), asserting the tab's published image/state becomes
/// populated and keeps refreshing at the visible cadence, then that
/// cancellation actually stops it.
@Test
@MainActor
func startDrivesRealPollsAgainstAStubbedCLIAndCancelsCleanly() async throws {
    let invocations = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let stub = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ego-browser-poller-stub-\(UUID().uuidString)"
        )
    // A minimal valid 1x1 PNG, so `NSImage(data:)` really decodes it — the
    // poller applies the frame through the real image-decoding path, unlike
    // the screenshot-client-level tests that only check byte equality.
    let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    try """
        #!/bin/sh
        cat > /dev/null
        printf 'x' >> "\(invocations.path)"
        printf '{"ok":true,"jpeg":"\(onePixelPNGBase64)","url":"https://example.com","title":"t"}\\n'
        """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: stub.path
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    let client = EgoBrowserScreenshotClient(
        executablePath: stub.path,
        timeout: .seconds(5)
    )

    BrowserMirrorPoller.start(
        for: tab,
        client: client,
        isVisible: { true }
    )

    let deadline = Date().addingTimeInterval(10)
    while tab.state != .live, Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(tab.state == .live)
    #expect(tab.image != nil)
    #expect(tab.pageURL == "https://example.com")

    // Let the fast (1s) visible cadence fire at least once more.
    try await Task.sleep(for: .seconds(1.3))
    let callsAfterTwoRounds = (try? String(
        contentsOf: invocations,
        encoding: .utf8
    ))?.count ?? 0
    #expect(callsAfterTwoRounds >= 2)

    tab.cancelPolling()
    try await Task.sleep(for: .milliseconds(300))
    let callsAtCancel = (try? String(
        contentsOf: invocations,
        encoding: .utf8
    ))?.count ?? 0
    try await Task.sleep(for: .seconds(1.2))
    let callsAfterCancel = (try? String(
        contentsOf: invocations,
        encoding: .utf8
    ))?.count ?? 0

    #expect(callsAfterCancel == callsAtCancel)
}

/// Drives the real poller against the real, locally installed `ego-browser`
/// CLI and a real ego lite Task Space end to end — the same verification
/// path validated manually during the Phase 0 spike, now as a durable,
/// repeatable test. Gated behind an env var, the same convention already
/// used for `liveInstalledGrokFinderListsOpensPinsAndCleansWorkspaces()`,
/// since it depends on third-party software this repository does not
/// install or control.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "COINOR_RUN_LIVE_EGO_BROWSER"
        ] == "1"
    ),
    .timeLimit(.minutes(2))
)
@MainActor
func liveEgoBrowserPollerPopulatesARealFrame() async throws {
    let locator = EgoBrowserLocator()
    try #require(
        locator.resolve() != nil,
        "ego-browser must be installed to run this live test"
    )

    let tab = BrowserMirrorTab(
        ownerSessionID: "live-verification-session",
        taskSpaceName: "coinor live poller verification"
    )

    BrowserMirrorPoller.start(
        for: tab,
        locator: locator,
        isVisible: { true }
    )

    let deadline = Date().addingTimeInterval(30)
    while tab.state != .live, Date() < deadline {
        try await Task.sleep(for: .milliseconds(200))
    }
    tab.cancelPolling()

    #expect(tab.state == .live)
    #expect(tab.image != nil)

    // Leave no Task Space behind in ego lite.
    await closeLiveVerificationTaskSpace(executablePath: try #require(locator.resolve()))
}

private func closeLiveVerificationTaskSpace(executablePath: String) async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["nodejs"]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return }
    let script = """
        await completeTaskSpace('coinor live poller verification', { keep: false })
        cliLog('closed')
        """
    stdin.fileHandleForWriting.write(Data(script.utf8))
    try? stdin.fileHandleForWriting.close()
    process.waitUntilExit()
}
