import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import QuartzCore

@MainActor
final class GhosttySurfaceView: NSView {
    nonisolated(unsafe) private(set) var surfaceHandle: ghostty_surface_t?
    private let runtime: GhosttyRuntime
    private let launch: TerminalLaunchRequest
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var lastPixelSize = CGSize.zero
    private var isShuttingDown = false

    var onCloseRequest: (() -> Void)?
    var onProcessExit: ((UInt64) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    init(runtime: GhosttyRuntime, launch: TerminalLaunchRequest) throws {
        self.runtime = runtime
        self.launch = launch
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        wantsLayer = true

        let environment = [
            ("GHOSTTY_RESOURCES_DIR", runtime.resourcesDirectory),
            ("TERMINFO", runtime.terminfoDirectory),
            ("PATH", Self.terminalPath()),
        ]
        guard let app = runtime.app else {
            throw GhosttyRuntimeError.applicationCreation
        }

        let surface = try Self.withEnvironment(environment) {
            environmentPointer,
            environmentCount in
            try launch.workingDirectory.withCString { workingDirectory in
                try launch.shellCommand.withCString { command in
                    var configuration = ghostty_surface_config_new()
                    configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
                    configuration.platform = ghostty_platform_u(
                        macos: ghostty_platform_macos_s(
                            nsview: Unmanaged.passUnretained(self).toOpaque()
                        )
                    )
                    configuration.userdata = Unmanaged
                        .passUnretained(self)
                        .toOpaque()
                    configuration.scale_factor = Double(
                        NSScreen.main?.backingScaleFactor ?? 2
                    )
                    configuration.working_directory = workingDirectory
                    configuration.command = command
                    configuration.env_vars = environmentPointer
                    configuration.env_var_count = environmentCount
                    configuration.wait_after_command = true
                    configuration.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

                    guard let surface = ghostty_surface_new(
                        app,
                        &configuration
                    ) else {
                        throw GhosttyRuntimeError.surfaceCreation
                    }
                    return surface
                }
            }
        }

        surfaceHandle = surface
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
        removeObservers()
        guard let window else { return }
        updateDisplayProperties()
        updateFocus()
        window.makeFirstResponder(self)
        installObservers(window: window)
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
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { updateFocus() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { updateFocus() }
        return result
    }

    override func keyDown(with event: NSEvent) {
        sendKey(
            event,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        let modifiers = Self.modifiers(event.modifierFlags)
        let action: ghostty_input_action_e
        switch event.keyCode {
        case UInt16(kVK_Shift), UInt16(kVK_RightShift):
            action = modifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Control), UInt16(kVK_RightControl):
            action = modifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Option), UInt16(kVK_RightOption):
            action = modifiers.rawValue & GHOSTTY_MODS_ALT.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        case UInt16(kVK_Command), UInt16(kVK_RightCommand):
            action = modifiers.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0
                ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        default:
            return
        }
        sendKey(event, action: action)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self else {
            return false
        }
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

    func requestHostClose() {
        onCloseRequest?()
    }

    func processDidRequestClose(processAlive: Bool) {
        if !processAlive {
            onCloseRequest?()
        }
    }

    func processDidExit(runtimeMilliseconds: UInt64) {
        onProcessExit?(runtimeMilliseconds)
    }

    func screenText() -> String {
        guard let surfaceHandle else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(
            surfaceHandle,
            selection,
            &text
        ) else {
            return ""
        }
        defer { ghostty_surface_free_text(surfaceHandle, &text) }
        guard let pointer = text.text else { return "" }
        return String(
            data: Data(bytes: pointer, count: Int(text.text_len)),
            encoding: .utf8
        ) ?? ""
    }

    func updateTerminalTitle(_ title: String) {
        onTitleChange?(title)
    }

    func updateWorkingDirectory(_ directory: String) {
        onWorkingDirectoryChange?(directory)
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

    func focusTerminal() {
        window?.makeFirstResponder(self)
    }

    func shutdown() {
        guard !isShuttingDown, let surfaceHandle else { return }
        isShuttingDown = true
        removeObservers()
        onCloseRequest = nil
        onProcessExit = nil
        onTitleChange = nil
        onWorkingDirectoryChange = nil
        ghostty_surface_free(surfaceHandle)
        self.surfaceHandle = nil
    }

    private static func terminalPath() -> String {
        let home = NSHomeDirectory()
        let preferred = [
            "\(home)/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/Library/Apple/usr/bin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen: Set<String> = []
        return (preferred + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func installObservers(window: NSWindow) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                Task { @MainActor in
                    self.updateOcclusion(
                        visible: window.occlusionState.contains(.visible)
                    )
                }
            }
        )
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateOcclusion(visible: true)
                    self?.updateDisplayProperties()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.runtime.setApplicationFocus(true)
                    self?.updateFocus()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.runtime.setApplicationFocus(false)
                    self?.updateFocus()
                }
            }
        )
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func updateOcclusion(visible: Bool) {
        guard let surfaceHandle else { return }
        ghostty_surface_set_occlusion(surfaceHandle, visible)
    }

    private func updateDisplayProperties() {
        guard let window, let surfaceHandle else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surfaceHandle, scale, scale)
        layer?.contentsScale = scale
        if let screenNumber = window.screen?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber {
            ghostty_surface_set_display_id(surfaceHandle, screenNumber.uint32Value)
        }
        updateSurfaceSize()
    }

    private func updateFocus() {
        guard let surfaceHandle else { return }
        let focused = window?.isKeyWindow == true
            && window?.firstResponder === self
        ghostty_surface_set_focus(surfaceHandle, focused)
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
            width: max(1, pixelRect.width.rounded()),
            height: max(1, pixelRect.height.rounded())
        )
        guard size != lastPixelSize else { return }
        lastPixelSize = size
        ghostty_surface_set_size(
            surfaceHandle,
            UInt32(size.width),
            UInt32(size.height)
        )
    }

    private func sendKey(
        _ event: NSEvent,
        action: ghostty_input_action_e
    ) {
        guard let surfaceHandle else { return }
        var key = makeKeyEvent(event, action: action)
        if let characters = event.characters, !characters.isEmpty {
            characters.withCString {
                key.text = $0
                _ = ghostty_surface_key(surfaceHandle, key)
            }
        } else {
            _ = ghostty_surface_key(surfaceHandle, key)
        }
    }

    private func makeKeyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.modifiers(event.modifierFlags)
        key.consumed_mods = Self.modifiers(
            event.modifierFlags.subtracting([.control, .command])
        )
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.unshifted_codepoint = event
            .characters(byApplyingModifiers: [])?
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

    private static func modifiers(
        _ flags: NSEvent.ModifierFlags
    ) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
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
            ghostty_env_var_s(
                key: UnsafePointer($0.0),
                value: UnsafePointer($0.1)
            )
        }
        return try variables.withUnsafeMutableBufferPointer {
            try body($0.baseAddress, $0.count)
        }
    }
}
