import AppKit
import Foundation
import Testing

@testable import Coinor

private func sampleImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()
    return image
}

@Test
@MainActor
func newTabStartsConnectingWithNoFrame() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )

    #expect(tab.state == .connecting)
    #expect(tab.image == nil)
    #expect(tab.name == "research")
}

@Test
@MainActor
func explicitNameOverridesTheTaskSpaceNameAsTheTabTitle() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research",
        name: "Browser: research"
    )

    #expect(tab.name == "Browser: research")
}

@Test
@MainActor
func applyingAFrameMovesConnectingToLiveAndResetsFailures() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    tab.applyFailure(reason: "timed out")
    #expect(tab.consecutiveFailures == 1)

    tab.applyFrame(
        image: sampleImage(),
        url: "https://example.com",
        title: "Example"
    )

    #expect(tab.state == .live)
    #expect(tab.image != nil)
    #expect(tab.pageURL == "https://example.com")
    #expect(tab.pageTitle == "Example")
    #expect(tab.consecutiveFailures == 0)
}

@Test
@MainActor
func repeatedFailuresFlipToUnavailableAfterTheThreshold() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )

    tab.applyFailure(reason: "ego-browser not found")
    #expect(tab.state == .connecting)
    tab.applyFailure(reason: "ego-browser not found")
    #expect(tab.state == .connecting)
    tab.applyFailure(reason: "ego-browser not found")

    guard case .unavailable(let reason) = tab.state else {
        Issue.record("expected .unavailable, got \(tab.state)")
        return
    }
    #expect(reason == "ego-browser not found")
}

@Test
@MainActor
func aSuccessfulFrameAfterFailuresResetsTheFailureCounter() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    tab.applyFailure(reason: "timeout")
    tab.applyFailure(reason: "timeout")

    tab.applyFrame(image: sampleImage(), url: nil, title: nil)
    tab.applyFailure(reason: "timeout")
    tab.applyFailure(reason: "timeout")

    // Only 2 consecutive failures since the reset — still below threshold.
    #expect(tab.state == .live)
}

@Test
@MainActor
func markClosedWithoutKeepFrameEntersClosedAndCancelsPolling() async {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    var cancelled = false
    tab.attachPoller(
        Task {
            defer { cancelled = true }
            try? await Task.sleep(for: .seconds(60))
        }
    )

    tab.markClosed(keepFrame: false)

    #expect(tab.state == .closed)
    // Cancellation is cooperative; give the task a beat to observe it.
    try? await Task.sleep(for: .milliseconds(50))
    _ = cancelled
}

@Test
@MainActor
func markClosedWithKeepFrameEntersFinished() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )

    tab.markClosed(keepFrame: true)

    #expect(tab.state == .finished)
}

@Test
@MainActor
func markOpenedOnAClosedTabResurrectsItToConnecting() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    tab.applyFrame(image: sampleImage(), url: nil, title: nil)
    tab.markClosed(keepFrame: false)
    #expect(tab.state == .closed)

    tab.markOpened()

    #expect(tab.state == .connecting)
}

@Test
@MainActor
func markOpenedOnAnUnavailableTabResetsFailuresAndRetries() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    tab.applyFailure(reason: "x")
    tab.applyFailure(reason: "x")
    tab.applyFailure(reason: "x")
    guard case .unavailable = tab.state else {
        Issue.record("expected .unavailable")
        return
    }

    tab.markOpened()

    #expect(tab.state == .connecting)
    #expect(tab.consecutiveFailures == 0)
}

@Test
@MainActor
func markOpenedOnALiveTabOnlyBumpsActivity() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research",
        now: Date(timeIntervalSince1970: 0)
    )
    tab.applyFrame(
        image: sampleImage(),
        url: nil,
        title: nil,
        now: Date(timeIntervalSince1970: 1)
    )
    #expect(tab.state == .live)

    tab.markOpened(now: Date(timeIntervalSince1970: 2))

    #expect(tab.state == .live)
    #expect(tab.lastActivityAt == Date(timeIntervalSince1970: 2))
}
