import AppKit
import Testing

@testable import Coinor

@Suite
struct GhosttyMouseRoutingTests {
    @Test
    func inactiveCaptureForwardsImmediatePressDragAndRelease() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command])
        let drag = input(x: 30, y: 40, modifiers: [.command, .option])
        let up = input(x: 35, y: 45, modifiers: [.option])

        #expect(router.mouseDown(down, mouseCaptured: false) == [
            .position(down),
            .leftButton(.press, down),
        ])
        #expect(router.mouseDragged(drag) == [.position(drag)])
        #expect(router.mouseUp(up) == [
            .position(up),
            .leftButton(.release, up),
        ])
    }

    @Test
    func heldShiftBypassesDeferralWhileMouseIsCaptured() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.shift, .control])

        #expect(router.mouseDown(down, mouseCaptured: true) == [
            .position(down),
            .leftButton(.press, down),
        ])
    }

    @Test
    func shiftStartedCapturedGestureKeepsShiftAfterPhysicalRelease() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.shift, .control])
        let drag = input(x: 20, y: 30, modifiers: [.command])
        let up = input(x: 25, y: 35, modifiers: [.option])
        let routedDrag = drag.forcingShift(true)
        let routedUp = up.forcingShift(true)

        #expect(router.mouseDown(down, mouseCaptured: true) == [
            .position(down),
            .leftButton(.press, down),
        ])
        #expect(router.mouseDragged(drag) == [.position(routedDrag)])
        #expect(router.mouseUp(up) == [
            .position(routedUp),
            .leftButton(.release, routedUp),
        ])
    }

    @Test
    func inactiveCaptureLatchesShiftAbsentThroughGesture() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])
        let drag = input(x: 20, y: 30, modifiers: [.shift, .command])
        let up = input(x: 25, y: 35, modifiers: [.shift, .option])
        let routedDrag = drag.forcingShift(false)
        let routedUp = up.forcingShift(false)

        #expect(router.mouseDown(down, mouseCaptured: false) == [
            .position(down),
            .leftButton(.press, down),
        ])
        #expect(router.mouseDragged(drag) == [.position(routedDrag)])
        #expect(router.mouseUp(up) == [
            .position(routedUp),
            .leftButton(.release, routedUp),
        ])
    }

    @Test
    func capturedClickReplaysOrdinaryPressAndRelease() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command])
        let up = input(x: 11, y: 21, modifiers: [.option])

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        #expect(router.mouseUp(up) == [
            .position(down),
            .leftButton(.press, down),
            .position(up),
            .leftButton(.release, up),
        ])
    }

    @Test
    func deferredCapturedClickKeepsShiftAbsentIfPressedBeforeRelease() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command])
        let up = input(x: 11, y: 21, modifiers: [.shift, .option])
        let routedUp = up.forcingShift(false)

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        #expect(router.mouseUp(up) == [
            .position(down),
            .leftButton(.press, down),
            .position(routedUp),
            .leftButton(.release, routedUp),
        ])
    }

    @Test
    func twoCapturedClicksReplayTwoCompleteUnshiftedGestures() {
        var router = GhosttyMouseRouter()
        let firstDown = input(x: 10, y: 20, modifiers: [.command])
        let firstUp = input(x: 10, y: 20, modifiers: [.command])
        let secondDown = input(x: 11, y: 20, modifiers: [.option])
        let secondUp = input(x: 11, y: 20, modifiers: [.option])

        var commands: [GhosttyMouseRoutingCommand] = []
        commands += router.mouseDown(firstDown, mouseCaptured: true)
        commands += router.mouseUp(firstUp)
        commands += router.mouseDown(secondDown, mouseCaptured: true)
        commands += router.mouseUp(secondUp)

        #expect(commands == [
            .position(firstDown),
            .leftButton(.press, firstDown),
            .position(firstUp),
            .leftButton(.release, firstUp),
            .position(secondDown),
            .leftButton(.press, secondDown),
            .position(secondUp),
            .leftButton(.release, secondUp),
        ])
        #expect(commands.allSatisfy { command in
            switch command {
            case .position(let input), .leftButton(_, let input):
                !input.modifiers.contains(.shift)
            }
        })
    }

    @Test
    func capturedClickSurvivesJitterUnderTheDragThreshold() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command])
        let jitter = input(x: 12, y: 23, modifiers: [.command])
        let up = input(x: 12, y: 23, modifiers: [.command])

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        #expect(router.mouseDragged(jitter).isEmpty)
        #expect(router.mouseUp(up) == [
            .position(down),
            .leftButton(.press, down),
            .position(up),
            .leftButton(.release, up),
        ])
    }

    @Test
    func capturedGesturePromotesOnceTravelPassesTheDragThreshold() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command])
        let jitter = input(x: 13, y: 23, modifiers: [.command])
        let drag = input(x: 10, y: 26, modifiers: [.command])
        let shiftedDown = down.forcingShift(true)
        let shiftedDrag = drag.forcingShift(true)

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        #expect(router.mouseDragged(jitter).isEmpty)
        #expect(router.mouseDragged(drag) == [
            .position(shiftedDown),
            .leftButton(.press, shiftedDown),
            .position(shiftedDrag),
        ])
    }

    @Test
    func capturedDragAddsShiftWithoutDroppingOriginalModifiers() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.command, .control])
        let drag = input(x: 30, y: 40, modifiers: [.command, .option])
        let laterDrag = input(x: 45, y: 55, modifiers: [.control])
        let shiftedDown = down.forcingShift(true)
        let shiftedDrag = drag.forcingShift(true)
        let shiftedLaterDrag = laterDrag.forcingShift(true)

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        #expect(router.mouseDragged(drag) == [
            .position(shiftedDown),
            .leftButton(.press, shiftedDown),
            .position(shiftedDrag),
        ])
        #expect(router.mouseDragged(laterDrag) == [
            .position(shiftedLaterDrag),
        ])
        #expect(router.mouseUp(laterDrag) == [
            .position(shiftedLaterDrag),
            .leftButton(.release, shiftedLaterDrag),
        ])
    }

    @Test
    func cancellingImmediateGestureReleasesAtLastRoutedPosition() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.shift, .control])
        let drag = input(x: 30, y: 40, modifiers: [.command])
        let routedDrag = drag.forcingShift(true)

        _ = router.mouseDown(down, mouseCaptured: false)
        _ = router.mouseDragged(drag)

        #expect(router.cancel() == [
            .position(routedDrag),
            .leftButton(.release, routedDrag),
        ])
        #expect(router.mouseUp(drag).isEmpty)
    }

    @Test
    func cancellingSelectingGestureReleasesWithForcedShift() {
        var router = GhosttyMouseRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])
        let drag = input(x: 30, y: 40, modifiers: [.command])
        let routedDrag = drag.forcingShift(true)

        #expect(router.mouseDown(down, mouseCaptured: true).isEmpty)
        _ = router.mouseDragged(drag)

        #expect(router.cancel() == [
            .position(routedDrag),
            .leftButton(.release, routedDrag),
        ])
        #expect(router.mouseUp(drag).isEmpty)
    }

    @Test
    func cancellingDeferredGestureEmitsNothing() {
        var router = GhosttyMouseRouter()
        let abandoned = input(x: 10, y: 20)

        #expect(router.mouseDown(abandoned, mouseCaptured: true).isEmpty)
        #expect(router.cancel().isEmpty)
        #expect(router.mouseUp(abandoned).isEmpty)
        #expect(router.cancel().isEmpty)
    }

    @Test
    func exitWithoutPressedButtonsSendsSentinelWithModifiers() {
        let commands = GhosttyMouseBoundaryRouting.exitCommands(
            modifiers: [.command, .option],
            hasPressedMouseButtons: false
        )

        #expect(commands == [
            .position(
                input(
                    x: -1,
                    y: -1,
                    modifiers: [.command, .option]
                )
            ),
        ])
    }

    @Test
    func exitDuringDragDoesNotInterruptMouseRouting() {
        #expect(
            GhosttyMouseBoundaryRouting.exitCommands(
                modifiers: [.shift],
                hasPressedMouseButtons: true
            ).isEmpty
        )
    }

    @Test
    func terminalConsumedSecondaryClickKeepsTerminalOwnershipThroughUp() {
        var router = GhosttySecondaryClickRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])

        #expect(router.mouseDown(down, terminalConsumed: true) == .terminal)
        #expect(router.mouseUp() == .terminal)
        #expect(router.mouseUp() == nil)
    }

    @Test
    func unconsumedSecondaryClickFallsBackToHostThroughUp() {
        var router = GhosttySecondaryClickRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])

        #expect(router.mouseDown(down, terminalConsumed: false) == .host)
        #expect(router.mouseUp() == .host)
        #expect(router.mouseUp() == nil)
    }

    @Test
    func cancellingTerminalOwnedSecondaryGestureReleasesAtLastRoutedInput() {
        var router = GhosttySecondaryClickRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])
        let drag = input(x: 30, y: 40, modifiers: [.command, .option])

        #expect(router.mouseDown(down, terminalConsumed: true) == .terminal)
        router.mouseDragged(drag)

        #expect(router.cancel() == drag)
        #expect(router.mouseUp() == nil)
    }

    @Test
    func cancellingHostOwnedSecondaryGestureNeedsNoTerminalRelease() {
        var router = GhosttySecondaryClickRouter()
        let down = input(x: 10, y: 20, modifiers: [.control])
        let drag = input(x: 30, y: 40, modifiers: [.command, .option])

        #expect(router.mouseDown(down, terminalConsumed: false) == .host)
        router.mouseDragged(drag)

        #expect(router.cancel() == nil)
        #expect(router.mouseUp() == nil)
    }

    @Test
    func capturedControlLeftClickSuppressesHostContextMenu() {
        #expect(
            !GhosttyHostContextMenuPolicy.allowsMenu(
                buttonNumber: 0,
                modifiers: [.control],
                mouseCaptured: true
            )
        )
        #expect(
            GhosttyHostContextMenuPolicy.allowsMenu(
                buttonNumber: 1,
                modifiers: [.control],
                mouseCaptured: true
            )
        )
        #expect(
            GhosttyHostContextMenuPolicy.allowsMenu(
                buttonNumber: 0,
                modifiers: [.shift],
                mouseCaptured: true
            )
        )
    }

    private func input(
        x: CGFloat,
        y: CGFloat,
        modifiers: NSEvent.ModifierFlags = []
    ) -> GhosttyMouseInput {
        GhosttyMouseInput(
            point: CGPoint(x: x, y: y),
            modifiers: modifiers
        )
    }
}
