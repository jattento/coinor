import AppKit
import Foundation
import GhosttyKit

final class GhosttyRuntime: @unchecked Sendable {
    private static let initializationLock = NSLock()
    nonisolated(unsafe) private static var initialized = false

    private(set) var app: ghostty_app_t?
    private(set) var configuration: GhosttyConfiguration?
    let resourcesDirectory: String
    let terminfoDirectory: String
    let logger: SpikeLogger
    private let allowExternalURLRequests: Bool

    init(
        resourcesDirectory: String,
        initiallyFocused: Bool,
        allowExternalURLRequests: Bool = true,
        logger: SpikeLogger
    ) throws {
        self.resourcesDirectory = resourcesDirectory
        self.terminfoDirectory = URL(fileURLWithPath: resourcesDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("terminfo", isDirectory: true)
            .path
        self.allowExternalURLRequests = allowExternalURLRequests
        self.logger = logger

        guard FileManager.default.fileExists(atPath: "\(resourcesDirectory)/shell-integration"),
              FileManager.default.fileExists(atPath: "\(terminfoDirectory)/78/xterm-ghostty") else {
            throw SpikeError.missingResources(resourcesDirectory)
        }

        try Self.initializeGhostty(resourcesDirectory: resourcesDirectory)
        let configuration = try GhosttyConfiguration(logger: logger)
        self.configuration = configuration

        var runtimeConfiguration = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyRuntime.handleWakeup(userdata)
            },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyRuntime.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.handleReadClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                GhosttyRuntime.handleConfirmReadClipboard(
                    userdata,
                    string: string,
                    state: state,
                    request: request
                )
            },
            write_clipboard_cb: { userdata, location, content, count, confirm in
                GhosttyRuntime.handleWriteClipboard(
                    userdata,
                    location: location,
                    content: content,
                    count: count,
                    confirm: confirm
                )
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.handleCloseSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtimeConfiguration, configuration.handle) else {
            throw SpikeError.applicationCreation
        }
        self.app = app
        ghostty_app_set_focus(app, initiallyFocused)
        logger.record("runtime_created resources=\(resourcesDirectory)")
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setApplicationFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
        logger.record("application_focus=\(focused)")
    }

    func reloadConfiguration() {
        do {
            let replacement = try GhosttyConfiguration(logger: logger)
            guard let app else { return }
            ghostty_app_update_config(app, replacement.handle)
            configuration = replacement
            logger.record("config_reloaded")
        } catch {
            logger.record("config_reload_failed error=\(error.localizedDescription)")
        }
    }

    func exerciseOpenURLAction(surface: GhosttySurfaceView, url: String) -> Bool {
        guard let app, let surfaceHandle = surface.surfaceHandle else { return false }
        return url.withCString { pointer in
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = surfaceHandle

            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            action.action.open_url.kind = GHOSTTY_ACTION_OPEN_URL_KIND_HTML
            action.action.open_url.url = pointer
            action.action.open_url.len = UInt(url.utf8.count)
            return Self.handleAction(app, target: target, action: action)
        }
    }

    func exerciseCloseAction(surface: GhosttySurfaceView) -> Bool {
        guard let app, let surfaceHandle = surface.surfaceHandle else { return false }
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surfaceHandle

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_WINDOW
        return Self.handleAction(app, target: target, action: action)
    }

    func shutdown() {
        guard let app else { return }
        ghostty_app_free(app)
        self.app = nil
        configuration = nil
        logger.record("runtime_destroyed")
    }

    deinit {
        shutdown()
    }

    static func initializeGhostty(resourcesDirectory: String) throws {
        initializationLock.lock()
        defer { initializationLock.unlock() }
        guard !initialized else { return }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesDirectory, 1)
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else {
            throw SpikeError.ghosttyInitialization(status)
        }
        initialized = true
    }

    private static func runtime(from app: ghostty_app_t) -> GhosttyRuntime? {
        guard let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surface(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surface(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let handle = target.target.surface,
              let userdata = ghostty_surface_userdata(handle) else {
            return nil
        }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            runtime.tick()
        }
    }

    private static func handleAction(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let runtime = runtime(from: app) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_GOTO_TAB,
             GHOSTTY_ACTION_GOTO_SPLIT,
             GHOSTTY_ACTION_GOTO_WINDOW,
             GHOSTTY_ACTION_RESIZE_SPLIT,
             GHOSTTY_ACTION_EQUALIZE_SPLITS,
             GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            runtime.logger.record("suppressed_action=\(action.tag.rawValue)")
            return true

        case GHOSTTY_ACTION_QUIT, GHOSTTY_ACTION_CLOSE_WINDOW:
            runtime.logger.record("close_action=\(action.tag.rawValue)")
            DispatchQueue.main.async {
                surface(from: target)?.requestHostClose()
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title.map(String.init(cString:)) ?? ""
            DispatchQueue.main.async {
                surface(from: target)?.updateTerminalTitle(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let directory = action.action.pwd.pwd.map(String.init(cString:)) ?? ""
            DispatchQueue.main.async {
                surface(from: target)?.updateWorkingDirectory(directory)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            DispatchQueue.main.async {
                surface(from: target)?.updateCursor(action.action.mouse_shape)
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            guard let pointer = action.action.open_url.url else { return false }
            let data = Data(bytes: pointer, count: Int(action.action.open_url.len))
            guard let value = String(data: data, encoding: .utf8),
                  let url = URL(string: value) else {
                return false
            }
            DispatchQueue.main.async {
                if runtime.allowExternalURLRequests {
                    let opened = NSWorkspace.shared.open(url)
                    runtime.logger.record("url_opened=\(opened) url=\(url.absoluteString)")
                } else {
                    runtime.logger.record("url_open_intercepted=\(url.absoluteString)")
                }
            }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async {
                runtime.reloadConfiguration()
            }
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            runtime.logger.record("renderer_health=\(action.action.renderer_health.rawValue)")
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            runtime.logger.record("child_exited")
            return true

        default:
            return false
        }
    }

    private static func handleReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = surface(from: userdata),
              let handle = surface.surfaceHandle,
              let value = NSPasteboard.general.string(forType: .string) else {
            return false
        }

        value.withCString {
            ghostty_surface_complete_clipboard_request(handle, $0, state, true)
        }
        surface.logger.record("clipboard_read bytes=\(value.utf8.count)")
        return true
    }

    private static func handleConfirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface = surface(from: userdata),
              let handle = surface.surfaceHandle else {
            return
        }
        let value = string.map(String.init(cString:)) ?? ""
        let confirmed = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        value.withCString {
            ghostty_surface_complete_clipboard_request(handle, $0, state, confirmed)
        }
        surface.logger.record("clipboard_confirm request=\(request.rawValue) confirmed=\(confirmed)")
    }

    private static func handleWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              !confirm,
              let surface = surface(from: userdata),
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            surface.logger.record("clipboard_write bytes=\(value.utf8.count)")
            return
        }
    }

    private static func handleCloseSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let surface = surface(from: userdata) else { return }
        DispatchQueue.main.async {
            surface.processDidRequestClose(processAlive: processAlive)
        }
    }
}
