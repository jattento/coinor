import AppKit
import SwiftUI
import Testing

@testable import Coinor

/// A landscape screenshot, the shape `ego lite` actually captures.
private func landscapeFrame() -> NSImage {
    let image = NSImage(size: NSSize(width: 1_500, height: 1_000))
    image.lockFocus()
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 1_500, height: 1_000).fill()
    image.unlockFocus()
    return image
}

/// A pane that is taller than the 3:2 capture, which is what a full-height
/// conversation column on a normal window is.
private let pane = CGSize(width: 400, height: 600)

@MainActor
private func measure(_ view: some View, in proposal: CGSize) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: proposal)
}

/// `.aspectRatio(contentMode: .fill)` reports the size needed to cover the
/// offered space — for a 3:2 capture in a 400×600 pane that is 900 points
/// wide. When the screenshot was a `ZStack` sibling, that inflated width
/// travelled up through the tab stack and the detail column until the
/// window's content was wider than the window, and the hosting view centred
/// the overflow: the sidebar was pushed off the left window edge and the
/// terminal ran past the right one.
@Test
@MainActor
func aLiveBrowserMirrorFrameNeverWidensItsTab() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )
    tab.applyFrame(
        image: landscapeFrame(),
        url: "https://example.com",
        title: "Example"
    )

    let measured = measure(BrowserMirrorView(tab: tab), in: pane)

    #expect(measured.width == pane.width)
    #expect(measured.height == pane.height)
}

@Test
@MainActor
func aBrowserMirrorStillWaitingForItsFirstFrameFillsItsTab() {
    let tab = BrowserMirrorTab(
        ownerSessionID: "session",
        taskSpaceName: "research"
    )

    let measured = measure(BrowserMirrorView(tab: tab), in: pane)

    #expect(measured.width == pane.width)
    #expect(measured.height == pane.height)
}

/// The containment backstop: whatever a child returns, the stack reports the
/// space it was offered. `.frame(maxWidth: .infinity)` does not do this — it
/// reports the child's size whenever the child returns more than proposed.
@Test
@MainActor
func aPinnedStackReportsTheOfferedSizeDespiteAnOversizedChild() {
    let oversized = PinnedStack {
        Image(nsImage: landscapeFrame())
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    let measured = measure(oversized, in: pane)

    #expect(measured.width == pane.width)
    #expect(measured.height == pane.height)
}
