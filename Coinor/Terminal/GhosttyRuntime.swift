import AppKit
import Foundation
import GhosttyKit

private func coinorGhosttyWakeup(
    _ userdata: UnsafeMutableRawPointer?
) {
    GhosttyRuntime.handleWakeup(userdata)
}

private func coinorGhosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app else { return false }
    return GhosttyRuntime.handleAction(
        app,
        target: target,
        action: action
    )
}

private func coinorGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.readClipboard(
        userdata,
        location: location,
        state: state
    )
}

private func coinorGhosttyConfirmClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    GhosttyRuntime.confirmClipboard(
        userdata,
        string: string,
        state: state,
        request: request
    )
}

private func coinorGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    GhosttyRuntime.writeClipboard(
        userdata,
        location: location,
        content: content,
        count: count,
        confirm: confirm
    )
}

private func coinorGhosttyCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    GhosttyRuntime.handleCloseSurface(
        userdata,
        processAlive: processAlive
    )
}

enum GhosttyRuntimeError: LocalizedError {
    case missingResources(String)
    case initialization(Int32)
    case configurationCreation
    case applicationCreation
    case surfaceCreation

    var errorDescription: String? {
        switch self {
        case .missingResources(let path):
            "Ghostty resources are missing from \(path)."
        case .initialization(let code):
            "Ghostty initialization failed with status \(code)."
        case .configurationCreation:
            "Conan Code could not load the Ghostty configuration."
        case .applicationCreation:
            "Conan Code could not create the embedded Ghostty runtime."
        case .surfaceCreation:
            "Conan Code could not create an embedded terminal surface."
        }
    }
}

@MainActor
final class GhosttyRuntime: ObservableObject {
    private static let initializationLock = NSLock()
    nonisolated(unsafe) private static var initialized = false

    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    private(set) var configuration: GhosttyConfiguration?
    let resourcesDirectory: String
    let terminfoDirectory: String
    @Published private(set) var configurationDiagnostics: [String] = []
    @Published private(set) var themeColors: GhosttyThemeColors

    init(bundle: Bundle = .main) throws {
        guard let resourceURL = bundle.resourceURL else {
            throw GhosttyRuntimeError.missingResources("Coinor.app/Contents/Resources")
        }
        let ghosttyResources = resourceURL
            .appendingPathComponent("ghostty", isDirectory: true)
            .path
        let terminfo = resourceURL
            .appendingPathComponent("terminfo", isDirectory: true)
            .path
        guard FileManager.default.fileExists(
            atPath: "\(ghosttyResources)/shell-integration"
        ),
        FileManager.default.fileExists(atPath: "\(terminfo)/78/xterm-ghostty") else {
            throw GhosttyRuntimeError.missingResources(resourceURL.path)
        }

        resourcesDirectory = ghosttyResources
        terminfoDirectory = terminfo
        try Self.initializeGhostty(resourcesDirectory: ghosttyResources)

        let configuration = try GhosttyConfiguration()
        self.configuration = configuration
        configurationDiagnostics = configuration.diagnostics
        themeColors = configuration.themeColors

        var runtimeConfiguration = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: coinorGhosttyWakeup,
            action_cb: coinorGhosttyAction,
            read_clipboard_cb: coinorGhosttyReadClipboard,
            confirm_read_clipboard_cb: coinorGhosttyConfirmClipboard,
            write_clipboard_cb: coinorGhosttyWriteClipboard,
            close_surface_cb: coinorGhosttyCloseSurface
        )

        guard let app = ghostty_app_new(
            &runtimeConfiguration,
            configuration.handle
        ) else {
            throw GhosttyRuntimeError.applicationCreation
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setApplicationFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func reloadConfiguration() {
        do {
            let replacement = try GhosttyConfiguration()
            guard let app else { return }
            ghostty_app_update_config(app, replacement.handle)
            configuration = replacement
            configurationDiagnostics = replacement.diagnostics
            themeColors = replacement.themeColors
        } catch {
            configurationDiagnostics = [error.localizedDescription]
        }
    }

    func shutdown() {
        guard let app else { return }
        ghostty_app_free(app)
        self.app = nil
        configuration = nil
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
    }

    private static func initializeGhostty(
        resourcesDirectory: String
    ) throws {
        initializationLock.lock()
        defer { initializationLock.unlock() }
        guard !initialized else { return }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesDirectory, 1)
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else {
            throw GhosttyRuntimeError.initialization(status)
        }
        initialized = true
    }

    fileprivate nonisolated static func runtime(
        from app: ghostty_app_t
    ) -> GhosttyRuntime? {
        guard let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>
            .fromOpaque(userdata)
            .takeUnretainedValue()
    }

    fileprivate nonisolated static func surface(
        from userdata: UnsafeMutableRawPointer?
    ) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>
            .fromOpaque(userdata)
            .takeUnretainedValue()
    }

    fileprivate nonisolated static func surface(
        from target: ghostty_target_s
    ) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let handle = target.target.surface,
              let userdata = ghostty_surface_userdata(handle) else {
            return nil
        }
        return surface(from: userdata)
    }

    fileprivate nonisolated static func handleWakeup(
        _ userdata: UnsafeMutableRawPointer?
    ) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyRuntime>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            runtime.tick()
        }
    }

    fileprivate nonisolated static func handleCloseSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let surface = surface(from: userdata) else { return }
        DispatchQueue.main.async {
            surface.processDidRequestClose(processAlive: processAlive)
        }
    }

    fileprivate nonisolated static func handleAction(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let runtime = runtime(from: app) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
             GHOSTTY_ACTION_GOTO_SPLIT,
             GHOSTTY_ACTION_GOTO_WINDOW,
             GHOSTTY_ACTION_RESIZE_SPLIT,
             GHOSTTY_ACTION_EQUALIZE_SPLITS,
             GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.requestNewTab()
            }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB:
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.requestCloseTab()
            }
            return true

        case GHOSTTY_ACTION_MOVE_TAB:
            let targetSurface = surface(from: target)
            let amount = Int(action.action.move_tab.amount)
            DispatchQueue.main.async {
                targetSurface?.requestMoveTab(by: amount)
            }
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            let targetSurface = surface(from: target)
            let request = tabNavigationRequest(
                action.action.goto_tab
            )
            DispatchQueue.main.async {
                targetSurface?.requestTabNavigation(request)
            }
            return true

        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW:
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.requestHostClose()
            }
            return true

        case GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_tab_title.title.map(
                String.init(cString:)
            ) ?? ""
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.requestRenameTab(title)
            }
            return true

        case GHOSTTY_ACTION_PROMPT_TITLE:
            guard action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB
            else {
                return true
            }
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.requestRenameTab(nil)
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title.map(String.init(cString:)) ?? ""
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.updateTerminalTitle(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let directory = action.action.pwd.pwd.map(String.init(cString:)) ?? ""
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.updateWorkingDirectory(directory)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let targetSurface = surface(from: target)
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                targetSurface?.updateCursor(shape)
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            guard let pointer = action.action.open_url.url else { return false }
            let data = Data(
                bytes: pointer,
                count: Int(action.action.open_url.len)
            )
            guard let value = String(data: data, encoding: .utf8),
                  let url = URL(string: value) else {
                return false
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async {
                runtime.reloadConfiguration()
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let targetSurface = surface(from: target)
            let exitCode = action.action.child_exited.exit_code
            let runtimeMilliseconds = action.action.child_exited.timetime_ms
            DispatchQueue.main.async { [weak targetSurface] in
                targetSurface?.processDidExit(
                    exitCode: exitCode,
                    runtimeMilliseconds: runtimeMilliseconds
                )
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            let targetSurface = surface(from: target)
            let needle = action.action.start_search.needle.map(
                String.init(cString:)
            ) ?? ""
            DispatchQueue.main.async {
                targetSurface?.applySearchStart(needle: needle)
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            let targetSurface = surface(from: target)
            DispatchQueue.main.async {
                targetSurface?.applySearchEnd()
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let targetSurface = surface(from: target)
            let total = Int(action.action.search_total.total)
            DispatchQueue.main.async {
                targetSurface?.applySearchTotal(total)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let targetSurface = surface(from: target)
            let selected = Int(action.action.search_selected.selected)
            DispatchQueue.main.async {
                targetSurface?.applySearchSelected(selected)
            }
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return true

        default:
            return false
        }
    }

    private nonisolated static func tabNavigationRequest(
        _ value: ghostty_action_goto_tab_e
    ) -> TerminalTabNavigationRequest {
        switch value {
        case GHOSTTY_GOTO_TAB_PREVIOUS:
            .previous
        case GHOSTTY_GOTO_TAB_NEXT:
            .next
        case GHOSTTY_GOTO_TAB_LAST:
            .last
        default:
            .index(Int(value.rawValue))
        }
    }

    fileprivate nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = surface(from: userdata) else {
            return false
        }
        // The pasteboard is read before the surface lock is taken: hopping to
        // the main thread while holding it would deadlock against a shutdown
        // that is freeing the surface.
        let value: String?
        if Thread.isMainThread {
            value = NSPasteboard.general.string(forType: .string)
        } else {
            value = DispatchQueue.main.sync {
                NSPasteboard.general.string(forType: .string)
            }
        }
        guard let value else { return false }
        return surface.surfaceHandle.withHandle { handle in
            value.withCString {
                ghostty_surface_complete_clipboard_request(
                    handle,
                    $0,
                    state,
                    true
                )
            }
            return true
        } ?? false
    }

    fileprivate nonisolated static func confirmClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface = surface(from: userdata) else { return }
        let value = string.map(String.init(cString:)) ?? ""
        let confirmed = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        surface.surfaceHandle.withHandle { handle in
            value.withCString {
                ghostty_surface_complete_clipboard_request(
                    handle,
                    $0,
                    state,
                    confirmed
                )
            }
        }
    }

    fileprivate nonisolated static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              !confirm,
              surface(from: userdata) != nil,
              let content else {
            return
        }

        for index in 0..<count {
            guard let mime = content[index].mime,
                  String(cString: mime) == "text/plain",
                  let data = content[index].data else {
                continue
            }
            let value = String(cString: data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            return
        }
    }
}
