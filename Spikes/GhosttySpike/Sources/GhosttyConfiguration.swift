import Foundation
import GhosttyKit

final class GhosttyConfiguration {
    let handle: ghostty_config_t
    let diagnostics: [String]

    init(logger: SpikeLogger) throws {
        guard let handle = ghostty_config_new() else {
            throw SpikeError.configurationCreation
        }

        ghostty_config_load_default_files(handle)
        ghostty_config_load_recursive_files(handle)
        ghostty_config_finalize(handle)

        var diagnostics: [String] = []
        let count = ghostty_config_diagnostics_count(handle)
        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(handle, index)
            diagnostics.append(String(cString: diagnostic.message))
        }

        self.handle = handle
        self.diagnostics = diagnostics
        logger.record("config_loaded diagnostics=\(diagnostics.count)")
        for diagnostic in diagnostics {
            logger.record("config_diagnostic=\(diagnostic)")
        }
    }

    deinit {
        ghostty_config_free(handle)
    }

    func floatValue(for key: String) -> Float? {
        var value: Float = 0
        let loaded = key.withCString {
            ghostty_config_get(handle, &value, $0, UInt(key.utf8.count))
        }
        return loaded ? value : nil
    }

    func colorValue(for key: String) -> ghostty_config_color_s? {
        var value = ghostty_config_color_s()
        let loaded = key.withCString {
            ghostty_config_get(handle, &value, $0, UInt(key.utf8.count))
        }
        return loaded ? value : nil
    }
}
