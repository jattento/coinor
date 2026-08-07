import AppKit
import Carbon.HIToolbox
import Testing

@testable import Coinor

@Suite
struct GhosttyKeyEventTextTests {
    @Test
    func appKitFunctionKeyRangeIsNeverSentAsText() {
        for value in UInt32(0xF700)...UInt32(0xF8FF) {
            let characters = String(UnicodeScalar(value)!)
            let event = keyEvent(
                characters: characters,
                charactersIgnoringModifiers: characters,
                keyCode: UInt16(kVK_LeftArrow)
            )

            #expect(GhosttyKeyEventText.translatedCharacters(for: event) == nil)
            #expect(GhosttyKeyEventText.sendableText(for: event) == nil)
        }
    }

    @Test
    func knownNavigationEditingAndFunctionKeysAreCovered() {
        let values: [Int] = [
            NSUpArrowFunctionKey,
            NSDownArrowFunctionKey,
            NSLeftArrowFunctionKey,
            NSRightArrowFunctionKey,
            NSHomeFunctionKey,
            NSEndFunctionKey,
            NSPageUpFunctionKey,
            NSPageDownFunctionKey,
            NSInsertFunctionKey,
            NSDeleteFunctionKey,
            NSHelpFunctionKey,
            NSF1FunctionKey,
            NSF35FunctionKey,
        ]

        for value in values {
            let characters = String(UnicodeScalar(value)!)
            let event = keyEvent(
                characters: characters,
                charactersIgnoringModifiers: characters,
                keyCode: UInt16(kVK_LeftArrow)
            )

            #expect(GhosttyKeyEventText.sendableText(for: event) == nil)
        }
    }

    @Test
    func controlModifiedKeysUseTheirTextWithoutControl() {
        let event = keyEvent(
            characters: "\u{03}",
            charactersIgnoringModifiers: "c",
            modifiers: .control,
            keyCode: UInt16(kVK_ANSI_C)
        )

        #expect(GhosttyKeyEventText.translatedCharacters(for: event) == "c")
        #expect(GhosttyKeyEventText.sendableText(for: event) == "c")
    }

    @Test
    func terminalControlKeysStayKeycodeDriven() {
        let events = [
            keyEvent(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: UInt16(kVK_Return)
            ),
            keyEvent(
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                keyCode: UInt16(kVK_Tab)
            ),
            keyEvent(
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                keyCode: UInt16(kVK_Escape)
            ),
        ]

        for event in events {
            #expect(GhosttyKeyEventText.sendableText(for: event) == nil)
        }
    }

    @Test
    func printableAsciiUnicodeAndComposedTextArePreserved() {
        for characters in ["a", "é", "界", "👨‍💻", "ab", "\u{7F}"] {
            let event = keyEvent(
                characters: characters,
                charactersIgnoringModifiers: characters,
                keyCode: UInt16(kVK_ANSI_A)
            )

            #expect(GhosttyKeyEventText.sendableText(for: event) == characters)
        }
    }

    private func keyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags = [],
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
