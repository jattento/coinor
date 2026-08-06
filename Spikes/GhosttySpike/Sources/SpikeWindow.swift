import AppKit

final class SpikeWindow: NSWindow {
    var spikeLogger: SpikeLogger?
    var rejectAccessibilityFrameChanges = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let callers = Thread.callStackSymbols
        if rejectAccessibilityFrameChanges,
           callers.contains(where: { $0.contains("NSAccessibilityEntryPointSetValueForAttribute") }) {
            spikeLogger?.record(
                "window_accessibility_frame_change_ignored=\(Int(frameRect.width))x\(Int(frameRect.height))"
            )
            return
        }

        let oldSize = frame.size
        super.setFrame(frameRect, display: flag)
        guard oldSize != frameRect.size else { return }
        spikeLogger?.record(
            "window_set_frame=\(Int(frameRect.width))x\(Int(frameRect.height))"
        )
    }
}
