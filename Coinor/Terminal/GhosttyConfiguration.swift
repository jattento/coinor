import Foundation
import GhosttyKit

final class GhosttyConfiguration {
    let handle: ghostty_config_t
    let diagnostics: [String]

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
    }

    deinit {
        ghostty_config_free(handle)
    }
}
