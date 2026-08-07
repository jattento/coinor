import AppKit

enum GhosttyKeyEventText {
    static func sendableText(for event: NSEvent) -> String? {
        guard let characters = translatedCharacters(for: event),
              !characters.isEmpty,
              let firstByte = characters.utf8.first,
              firstByte >= 0x20 else {
            return nil
        }
        return characters
    }

    static func translatedCharacters(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control)
                )
            }

            if (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
        }

        return characters
    }
}
