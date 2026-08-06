import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import QuartzCore

final class GhosttySurfaceView: NSView {
    nonisolated(unsafe) private(set) var surfaceHandle: ghostty_surface_t?
    private let runtime: GhosttyRuntime
    private let options: SpikeOptions
    let logger: SpikeLogger
    private var tracking: NSTrackingArea?
    private var lastPixelSize = CGSize.zero
    private var isShuttingDown = false
    private(set) var terminalTitle = ""
    private(set) var terminalWorkingDirectory = ""

    var onCloseRequest: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    init(runtime: GhosttyRuntime, options: SpikeOptions, logger: SpikeLogger) throws {
        self.runtime = runtime
        self.options = options
        self.logger = logger
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        var environment = [
            ("GHOSTTY_RESOURCES_DIR", runtime.resourcesDirectory),
            ("TERMINFO", runtime.terminfoDirectory),
            ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        ]
        if let eventLogPath = options.eventLogPath {
            environment.append(("COINOR_SPIKE_EVENT_LOG", eventLogPath))
        }

        guard let app = runtime.app else { throw SpikeError.applicationCreation }
        let surface = try Self.withEnvironment(environment) { environmentPointer, environmentCount in
            try options.workingDirectory.withCString { workingDirectory in
                try options.shellCommand.withCString { command in
                    var configuration = ghostty_surface_config_new()
                    configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
                    configuration.platform = ghostty_platform_u(
                        macos: ghostty_platform_macos_s(
                            nsview: Unmanaged.passUnretained(self).toOpaque()
                        )
                    )
                    configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
                    configuration.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
                    configuration.working_directory = workingDirectory
                    configuration.command = command
                    configuration.env_vars = environmentPointer
                    configuration.env_var_count = environmentCount
                    configuration.wait_after_command = true
                    configuration.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

                    guard let surface = ghostty_surface_new(app, &configuration) else {
                        throw SpikeError.surfaceCreation
                    }
                    return surface
                }
            }
        }

        surfaceHandle = surface
        logger.record(
            "surface_created command=\(options.shellCommand) cwd=\(options.workingDirectory)"
        )
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let surfaceHandle {
            ghostty_surface_free(surfaceHandle)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            logger.record("surface_detached")
            return
        }
        updateDisplayProperties()
        updateFocus()
        window.makeFirstResponder(self)
        logger.record("surface_attached window=\(window.windowNumber)")
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayProperties()
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            updateFocus()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            updateFocus()
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        let active = Self.modifiers(event.modifierFlags)
        let action: ghostty_input_action_e
        switch event.keyCode {
        case UInt16(kVK_Shift), UInt16(kVK_RightShift):
            action = active.rawValue & GHOSTTY_MODS_SHIFT.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Control), UInt16(kVK_RightControl):
            action = active.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Option), UInt16(kVK_RightOption):
            action = active.rawValue & GHOSTTY_MODS_ALT.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Command), UInt16(kVK_RightCommand):
            action = active.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        default:
            return
        }
        sendKey(event, action: action)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        var key = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString {
            key.text = $0
            return surfaceHandle.map {
                ghostty_surface_key_is_binding($0, key, &flags)
            } ?? false
        }
        guard isBinding else { return false }
        keyDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceHandle else { return }
        ghostty_surface_mouse_scroll(
            surfaceHandle,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            0
        )
    }

    func updateOcclusion(isVisible: Bool) {
        guard let surfaceHandle else { return }
        ghostty_surface_set_occlusion(surfaceHandle, isVisible)
        logger.record("surface_occlusion_visible=\(isVisible)")
    }

    func updateTerminalTitle(_ title: String) {
        terminalTitle = title
        if !title.isEmpty {
            window?.title = title
        }
        logger.record("terminal_title=\(title)")
    }

    func updateWorkingDirectory(_ directory: String) {
        terminalWorkingDirectory = directory
        logger.record("terminal_cwd=\(directory)")
    }

    func updateCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            NSCursor.crosshair.set()
        default:
            NSCursor.arrow.set()
        }
    }

    func requestHostClose() {
        logger.record("surface_host_close_requested")
        onCloseRequest?()
    }

    func processDidRequestClose(processAlive: Bool) {
        logger.record("surface_process_close process_alive=\(processAlive)")
        if !processAlive {
            onCloseRequest?()
        }
    }

    func sendAutomationText(_ text: String) {
        guard let surfaceHandle else { return }
        var sent = 0
        for character in text {
            guard let mapping = Self.automationKey(for: character) else {
                logger.record("automation_key_unmapped=\(character)")
                continue
            }

            var press = ghostty_input_key_s()
            press.action = GHOSTTY_ACTION_PRESS
            press.keycode = UInt32(mapping.keyCode)
            press.mods = mapping.modifiers
            press.consumed_mods = mapping.modifiers
            press.unshifted_codepoint = mapping.unshiftedCodepoint

            if character == "\n" {
                _ = ghostty_surface_key(surfaceHandle, press)
            } else {
                String(character).withCString {
                    press.text = $0
                    _ = ghostty_surface_key(surfaceHandle, press)
                }
            }

            var release = press
            release.action = GHOSTTY_ACTION_RELEASE
            release.text = nil
            _ = ghostty_surface_key(surfaceHandle, release)
            sent += 2
        }
        logger.record("automation_keyboard_events=\(sent)")
    }

    @discardableResult
    func performAutomationAction(_ action: String) -> Bool {
        guard let surfaceHandle else { return false }
        let handled = action.withCString {
            ghostty_surface_binding_action(surfaceHandle, $0, UInt(action.utf8.count))
        }
        logger.record("automation_binding_action=\(action) handled=\(handled)")
        return handled
    }

    func exerciseBackingPropertyTransition() {
        viewDidChangeBackingProperties()
        logger.record("automation_backing_transition")
    }

    func visibleText() -> String {
        guard let surfaceHandle else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surfaceHandle, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surfaceHandle, &text) }
        guard let pointer = text.text else { return "" }
        return String(
            data: Data(bytes: pointer, count: Int(text.text_len)),
            encoding: .utf8
        ) ?? ""
    }

    func shutdown() {
        guard !isShuttingDown, let surfaceHandle else { return }
        isShuttingDown = true
        ghostty_surface_free(surfaceHandle)
        self.surfaceHandle = nil
        logger.record("surface_destroyed")
    }

    private func updateDisplayProperties() {
        guard let surfaceHandle else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surfaceHandle, scale, scale)
        layer?.contentsScale = scale
        if let screenNumber = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber {
            ghostty_surface_set_display_id(surfaceHandle, screenNumber.uint32Value)
        }
        updateSurfaceSize()
        logger.record("surface_scale=\(scale)")
    }

    private func updateFocus() {
        guard let surfaceHandle else { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        ghostty_surface_set_focus(surfaceHandle, focused)
        logger.record("surface_focus=\(focused)")
    }

    private func updateSurfaceSize() {
        guard window != nil,
              let surfaceHandle,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        let pixelRect = convertToBacking(bounds)
        let size = CGSize(
            width: max(1, pixelRect.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, pixelRect.height.rounded(.toNearestOrAwayFromZero))
        )
        guard size != lastPixelSize else { return }
        lastPixelSize = size
        ghostty_surface_set_size(surfaceHandle, UInt32(size.width), UInt32(size.height))
        logger.record("surface_size_pixels=\(Int(size.width))x\(Int(size.height))")
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surfaceHandle else { return }
        var key = makeKeyEvent(event, action: action)
        let characters = event.characters
        if let characters, !characters.isEmpty {
            characters.withCString {
                key.text = $0
                _ = ghostty_surface_key(surfaceHandle, key)
            }
        } else {
            _ = ghostty_surface_key(surfaceHandle, key)
        }
        logger.record("key_event action=\(action.rawValue) keycode=\(event.keyCode)")
    }

    private func makeKeyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.modifiers(event.modifierFlags)
        key.consumed_mods = Self.modifiers(event.modifierFlags.subtracting([.control, .command]))
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?
            .unicodeScalars.first?.value ?? 0
        return key
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surfaceHandle else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(
            surfaceHandle,
            state,
            button,
            Self.modifiers(event.modifierFlags)
        )
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surfaceHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let backingPoint = convertToBacking(point)
        ghostty_surface_mouse_pos(
            surfaceHandle,
            backingPoint.x,
            backingPoint.y,
            Self.modifiers(event.modifierFlags)
        )
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
    }

    private static func automationKey(
        for character: Character
    ) -> (keyCode: UInt16, modifiers: ghostty_input_mods_e, unshiftedCodepoint: UInt32)? {
        if character == "\n" {
            return (UInt16(kVK_Return), GHOSTTY_MODS_NONE, 0)
        }
        if character == " " {
            return (UInt16(kVK_Space), GHOSTTY_MODS_NONE, 32)
        }
        if character == "." {
            return (UInt16(kVK_ANSI_Period), GHOSTTY_MODS_NONE, 46)
        }
        if character == "/" {
            return (UInt16(kVK_ANSI_Slash), GHOSTTY_MODS_NONE, 47)
        }
        if character == "-" {
            return (UInt16(kVK_ANSI_Minus), GHOSTTY_MODS_NONE, 45)
        }
        if character == ">" {
            return (UInt16(kVK_ANSI_Period), GHOSTTY_MODS_SHIFT, 46)
        }

        let keyCodes: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C,
            "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I,
            "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
            "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        ]
        guard let keyCode = keyCodes[character],
              let scalar = character.unicodeScalars.first else {
            return nil
        }
        return (UInt16(keyCode), GHOSTTY_MODS_NONE, scalar.value)
    }

    private static func withEnvironment<Result>(
        _ entries: [(String, String)],
        body: (UnsafeMutablePointer<ghostty_env_var_s>?, Int) throws -> Result
    ) rethrows -> Result {
        let keys = entries.map { strdup($0.0) }
        let values = entries.map { strdup($0.1) }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }

        var variables = zip(keys, values).map {
            ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1))
        }
        return try variables.withUnsafeMutableBufferPointer {
            try body($0.baseAddress, $0.count)
        }
    }
}
