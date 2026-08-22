import AppKit
import GhosttyKit
import Testing

@testable import Coinor

@Suite
struct GhosttyMouseRoutingTests {
    @Test
    func exitWithoutPressedButtonsSendsSentinelWithModifiers() {
        let positions = GhosttyMouseBoundaryRouting.exitPositions(
            modifiers: [.command, .option],
            hasPressedMouseButtons: false
        )

        #expect(positions == [
            input(x: -1, y: -1, modifiers: [.command, .option]),
        ])
    }

    @Test
    func exitDuringDragDoesNotInterruptMouseRouting() {
        #expect(
            GhosttyMouseBoundaryRouting.exitPositions(
                modifiers: [.shift],
                hasPressedMouseButtons: true
            ).isEmpty
        )
    }

    @Test
    func buttonNumbersMapToGhosttysButtonOrder() {
        #expect(button(0) == GHOSTTY_MOUSE_LEFT)
        #expect(button(1) == GHOSTTY_MOUSE_RIGHT)
        #expect(button(2) == GHOSTTY_MOUSE_MIDDLE)
        #expect(button(3) == GHOSTTY_MOUSE_EIGHT)
        #expect(button(4) == GHOSTTY_MOUSE_NINE)
        #expect(button(5) == GHOSTTY_MOUSE_SIX)
        #expect(button(6) == GHOSTTY_MOUSE_SEVEN)
        #expect(button(7) == GHOSTTY_MOUSE_FOUR)
        #expect(button(8) == GHOSTTY_MOUSE_FIVE)
        #expect(button(9) == GHOSTTY_MOUSE_TEN)
        #expect(button(10) == GHOSTTY_MOUSE_ELEVEN)
        #expect(button(11) == GHOSTTY_MOUSE_UNKNOWN)
    }

    @Test
    func clickOnUnfocusedPaneOfAnActiveWindowOnlyMovesFocus() {
        #expect(
            GhosttyFocusTransferPolicy.isFocusTransferOnly(
                isAlreadyFirstResponder: false,
                isApplicationActive: true,
                isKeyWindow: true
            )
        )
    }

    @Test
    func clickOnFocusedPaneReachesTheTerminal() {
        #expect(
            !GhosttyFocusTransferPolicy.isFocusTransferOnly(
                isAlreadyFirstResponder: true,
                isApplicationActive: true,
                isKeyWindow: true
            )
        )
    }

    @Test
    func clickThatAlsoActivatesTheWindowReachesTheTerminal() {
        #expect(
            !GhosttyFocusTransferPolicy.isFocusTransferOnly(
                isAlreadyFirstResponder: false,
                isApplicationActive: false,
                isKeyWindow: true
            )
        )
        #expect(
            !GhosttyFocusTransferPolicy.isFocusTransferOnly(
                isAlreadyFirstResponder: false,
                isApplicationActive: true,
                isKeyWindow: false
            )
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

    private func button(
        _ number: Int
    ) -> ghostty_input_mouse_button_e {
        GhosttyMouseButtonMapper.button(forNSEventButtonNumber: number)
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
