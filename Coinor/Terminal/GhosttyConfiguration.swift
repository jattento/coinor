import Foundation
import GhosttyKit

struct GhosttyRGBColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct GhosttyThemeColors: Equatable, Sendable {
    let background: GhosttyRGBColor?
    let foreground: GhosttyRGBColor?
    let backgroundOpacity: Double
}

final class GhosttyConfiguration {
    let handle: ghostty_config_t
    let diagnostics: [String]
    let themeColors: GhosttyThemeColors

    init(bundle: Bundle = .main) throws {
        guard let handle = ghostty_config_new() else {
            throw GhosttyRuntimeError.configurationCreation
        }
        guard let overridesURL = bundle.url(
            forResource: "GhosttyOverrides",
            withExtension: "conf"
        ) else {
            ghostty_config_free(handle)
            throw GhosttyRuntimeError.missingResources("GhosttyOverrides.conf")
        }

        ghostty_config_load_default_files(handle)
        ghostty_config_load_recursive_files(handle)
        overridesURL.path.withCString {
            ghostty_config_load_file(handle, $0)
        }
        ghostty_config_finalize(handle)

        var diagnostics: [String] = []
        for index in 0..<ghostty_config_diagnostics_count(handle) {
            diagnostics.append(
                String(cString: ghostty_config_get_diagnostic(handle, index).message)
            )
        }

        self.handle = handle
        self.diagnostics = diagnostics
        self.themeColors = GhosttyThemeColors(
            background: Self.colorValue(for: "background", handle: handle),
            foreground: Self.colorValue(for: "foreground", handle: handle),
            backgroundOpacity: Self.floatValue(
                for: "background-opacity",
                handle: handle
            ) ?? 1
        )
    }

    deinit {
        ghostty_config_free(handle)
    }

    private static func colorValue(
        for key: String,
        handle: ghostty_config_t
    ) -> GhosttyRGBColor? {
        var value = ghostty_config_color_s()
        let loaded = key.withCString {
            ghostty_config_get(handle, &value, $0, UInt(key.utf8.count))
        }
        guard loaded else { return nil }
        return GhosttyRGBColor(
            red: value.r,
            green: value.g,
            blue: value.b
        )
    }

    private static func floatValue(
        for key: String,
        handle: ghostty_config_t
    ) -> Double? {
        var value: Double = 0
        let loaded = key.withCString {
            ghostty_config_get(handle, &value, $0, UInt(key.utf8.count))
        }
        return loaded ? value : nil
    }
}
