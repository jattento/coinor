import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import QuartzCore

struct GhosttyMouseInput: Equatable {
    let point: CGPoint
    let modifiers: NSEvent.ModifierFlags

    func forcingShift(_ present: Bool) -> Self {
        var routedModifiers = modifiers
        if present {
            routedModifiers.insert(.shift)
        } else {
            routedModifiers.remove(.shift)
        }
        return Self(point: point, modifiers: routedModifiers)
    }
}

enum GhosttyMouseButtonAction: Equatable {
    case press
    case release
}

enum GhosttyMouseRoutingCommand: Equatable {
    case position(GhosttyMouseInput)
    case leftButton(GhosttyMouseButtonAction, GhosttyMouseInput)
}

enum GhosttySecondaryClickOwner: Equatable {
    case terminal
    case host
}

struct GhosttySecondaryClickRouter {
    private enum State {
        case idle
        case terminal(GhosttyMouseInput)
        case host
    }

    private var state: State = .idle

    mutating func mouseDown(
        _ input: GhosttyMouseInput,
        terminalConsumed: Bool
    ) -> GhosttySecondaryClickOwner {
        if terminalConsumed {
            state = .terminal(input)
            return .terminal
        }

        state = .host
        return .host
    }

    mutating func mouseDragged(_ input: GhosttyMouseInput) {
        guard case .terminal = state else { return }
        state = .terminal(input)
    }

    mutating func mouseUp() -> GhosttySecondaryClickOwner? {
        defer { state = .idle }
        return switch state {
        case .terminal:
            .terminal
        case .host:
            .host
        case .idle:
            nil
        }
    }

    mutating func cancel() -> GhosttyMouseInput? {
        defer { state = .idle }
        guard case .terminal(let input) = state else { return nil }
        return input
    }
}

enum GhosttyHostContextMenuPolicy {
    static func allowsMenu(
        buttonNumber: Int,
        modifiers: NSEvent.ModifierFlags,
        mouseCaptured: Bool
    ) -> Bool {
        let isControlLeftClick =
            buttonNumber == 0 && modifiers.contains(.control)
        return !(mouseCaptured && isControlLeftClick)
    }
}

enum GhosttyMouseBoundaryRouting {
    static func exitCommands(
        modifiers: NSEvent.ModifierFlags,
        hasPressedMouseButtons: Bool
    ) -> [GhosttyMouseRoutingCommand] {
        guard !hasPressedMouseButtons else { return [] }
        return [
            .position(
                GhosttyMouseInput(
                    point: CGPoint(x: -1, y: -1),
                    modifiers: modifiers
                )
            ),
        ]
    }
}

struct GhosttyMouseRouter {
    private struct ActiveGesture {
        let shiftPresent: Bool
        var lastRoutedInput: GhosttyMouseInput

        mutating func route(_ input: GhosttyMouseInput) -> GhosttyMouseInput {
            let routed = input.forcingShift(shiftPresent)
            lastRoutedInput = routed
            return routed
        }
    }

    private enum State {
        case idle
        case immediate(ActiveGesture)
        case deferred(ActiveGesture)
        case selecting(ActiveGesture)
    }

    private var state: State = .idle

    mutating func mouseDown(
        _ input: GhosttyMouseInput,
        mouseCaptured: Bool
    ) -> [GhosttyMouseRoutingCommand] {
        let shiftPresent = input.modifiers.contains(.shift)
        let routed = input.forcingShift(shiftPresent)
        let gesture = ActiveGesture(
            shiftPresent: shiftPresent,
            lastRoutedInput: routed
        )

        if !mouseCaptured || shiftPresent {
            state = .immediate(gesture)
            return [
                .position(routed),
                .leftButton(.press, routed),
            ]
        }

        state = .deferred(gesture)
        return []
    }

    mutating func mouseDragged(
        _ input: GhosttyMouseInput
    ) -> [GhosttyMouseRoutingCommand] {
        switch state {
        case .deferred(let gesture):
            let shiftedOriginal = gesture.lastRoutedInput.forcingShift(true)
            let shiftedCurrent = input.forcingShift(true)
            state = .selecting(
                ActiveGesture(
                    shiftPresent: true,
                    lastRoutedInput: shiftedCurrent
                )
            )
            return [
                .position(shiftedOriginal),
                .leftButton(.press, shiftedOriginal),
                .position(shiftedCurrent),
            ]

        case .selecting(var gesture):
            let routed = gesture.route(input)
            state = .selecting(gesture)
            return [.position(routed)]

        case .immediate(var gesture):
            let routed = gesture.route(input)
            state = .immediate(gesture)
            return [.position(routed)]

        case .idle:
            return [.position(input)]
        }
    }

    mutating func mouseUp(
        _ input: GhosttyMouseInput
    ) -> [GhosttyMouseRoutingCommand] {
        defer { state = .idle }

        switch state {
        case .deferred(let gesture):
            let original = gesture.lastRoutedInput.forcingShift(false)
            let routed = input.forcingShift(false)
            return [
                .position(original),
                .leftButton(.press, original),
                .position(routed),
                .leftButton(.release, routed),
            ]

        case .selecting(var gesture):
            let routed = gesture.route(input)
            return [
                .position(routed),
                .leftButton(.release, routed),
            ]

        case .immediate(var gesture):
            let routed = gesture.route(input)
            return [
                .position(routed),
                .leftButton(.release, routed),
            ]

        case .idle:
            return []
        }
    }

    mutating func cancel() -> [GhosttyMouseRoutingCommand] {
        defer { state = .idle }

        switch state {
        case .immediate(let gesture), .selecting(let gesture):
            let last = gesture.lastRoutedInput
            return [
                .position(last),
                .leftButton(.release, last),
            ]

        case .deferred, .idle:
            return []
        }
    }
}

enum GhosttyMouseCoordinateMapper {
    static func surfacePoint(
        viewPoint: CGPoint,
        bounds: CGRect,
        isFlipped: Bool
    ) -> CGPoint {
        CGPoint(
            x: viewPoint.x - bounds.minX,
            y: isFlipped
                ? viewPoint.y - bounds.minY
                : bounds.maxY - viewPoint.y
        )
    }
}

struct GhosttyScrollEvent: Equatable {
    let deltaX: Double
    let deltaY: Double
    let modifiers: ghostty_input_scroll_mods_t
}

enum GhosttyScrollEventMapper {
    private enum Momentum: Int32 {
        case none = 0
        case began = 1
        case stationary = 2
        case changed = 3
        case ended = 4
        case cancelled = 5
        case mayBegin = 6
    }

    static func event(
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        momentumPhase: NSEvent.Phase
    ) -> GhosttyScrollEvent {
        let precisionBit: Int32 = hasPreciseScrollingDeltas ? 1 : 0
        let momentumBits = momentum(for: momentumPhase).rawValue << 1
        return GhosttyScrollEvent(
            deltaX: deltaX,
            deltaY: deltaY,
            modifiers: precisionBit | momentumBits
        )
    }

    private static func momentum(
        for phase: NSEvent.Phase
    ) -> Momentum {
        switch phase {
        case .began:
            .began
        case .stationary:
            .stationary
        case .changed:
            .changed
        case .ended:
            .ended
        case .cancelled:
            .cancelled
        case .mayBegin:
            .mayBegin
        default:
            .none
        }
    }
}

struct GhosttySurfaceResizePolicy: Equatable {
    private(set) var lastAppliedSize = CGSize.zero
    private(set) var pendingSize: CGSize?

    mutating func requestedSize(
        _ size: CGSize,
        hostVisible: Bool
    ) -> CGSize? {
        guard hostVisible else {
            pendingSize = size
            return nil
        }

        pendingSize = nil
        guard size != lastAppliedSize else { return nil }
        lastAppliedSize = size
        return size
    }
}

@MainActor
final class GhosttySurfaceView: NSView, NSMenuItemValidation {
    nonisolated(unsafe) private(set) var surfaceHandle: ghostty_surface_t?
    private let runtime: GhosttyRuntime
    private let launch: TerminalLaunchRequest
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var resizePolicy = GhosttySurfaceResizePolicy()
    private var isShuttingDown = false
    private var mouseRouter = GhosttyMouseRouter()
    private var secondaryClickRouter = GhosttySecondaryClickRouter()
    private var hostVisible = true
    private var focusesWhenAttached = false

    var onCloseRequest: (() -> Void)?
    var onProcessExit: ((UInt32, UInt64) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onNewTabRequest: (() -> Void)?
    var onCloseTabRequest: (() -> Void)?
    var onTabNavigationRequest: ((TerminalTabNavigationRequest) -> Void)?
    var onMoveTabRequest: ((Int) -> Void)?
    var onRenameTabRequest: ((String?) -> Void)?
    var onBecameFocused: (() -> Void)?

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
        ] + launch.surfaceEnvironment.sorted { $0.key < $1.key }
        guard let app = runtime.app else {
            throw GhosttyRuntimeError.applicationCreation
        }

        let surface = try Self.withEnvironment(environment) {
            environmentPointer,
            environmentCount in
            try launch.surfaceWorkingDirectory.withCString { workingDirectory in
                let createSurface: (
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?
                ) throws
                    -> ghostty_surface_t = { command, initialInput in
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
                    configuration.initial_input = initialInput
                    configuration.wait_after_command = launch.waitsAfterCommand
                    configuration.context = Self.context(
                        for: launch.surfaceContext
                    )

                    guard let surface = ghostty_surface_new(
                        app,
                        &configuration
                    ) else {
                        throw GhosttyRuntimeError.surfaceCreation
                    }
                    return surface
                }
                let withInitialInput:
                    ((UnsafePointer<CChar>?) throws -> ghostty_surface_t)
                    throws -> ghostty_surface_t = { body in
                        if let initialInput = launch.initialInput {
                            return try initialInput.withCString(body)
                        }
                        return try body(nil)
                    }
                return try withInitialInput { initialInput in
                    if let command = launch.explicitCommand {
                        return try command.withCString {
                            try createSurface($0, initialInput)
                        }
                    }
                    return try createSurface(nil, initialInput)
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
        guard let window else {
            cancelMouseInteraction()
            return
        }
        updateDisplayProperties()
        updateFocus()
        updateOcclusion()
        if focusesWhenAttached, hostVisible {
            focusesWhenAttached = false
            window.makeFirstResponder(self)
        }
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
        if result {
            updateFocus()
            onBecameFocused?()
        }
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
        let captured = surfaceHandle.map(ghostty_surface_mouse_captured) ?? false
        dispatchMouseCommands(
            mouseRouter.mouseDown(
                mouseInput(event),
                mouseCaptured: captured
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dispatchMouseCommands(mouseRouter.mouseUp(mouseInput(event)))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let input = mouseInput(event)
        let consumed = sendMouseButton(
            input,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT
        )
        if secondaryClickRouter.mouseDown(
            input,
            terminalConsumed: consumed
        ) == .host {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        switch secondaryClickRouter.mouseUp() {
        case .terminal:
            _ = sendMouseButton(
                event,
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT
            )
        case .host:
            super.rightMouseUp(with: event)
        case nil:
            break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let hasPressedMouseButtons = NSEvent.pressedMouseButtons != 0
        if !hasPressedMouseButtons {
            cancelMouseInteraction()
            dispatchMouseCommands(
                GhosttyMouseBoundaryRouting.exitCommands(
                    modifiers: event.modifierFlags,
                    hasPressedMouseButtons: false
                )
            )
        }
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        dispatchMouseCommands(mouseRouter.mouseDragged(mouseInput(event)))
    }

    override func rightMouseDragged(with event: NSEvent) {
        let input = mouseInput(event)
        secondaryClickRouter.mouseDragged(input)
        sendMousePosition(input)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceHandle else { return }
        let scrollEvent = GhosttyScrollEventMapper.event(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            momentumPhase: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(
            surfaceHandle,
            scrollEvent.deltaX,
            scrollEvent.deltaY,
            scrollEvent.modifiers
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let mouseCaptured = surfaceHandle.map(ghostty_surface_mouse_captured) ?? false
        guard GhosttyHostContextMenuPolicy.allowsMenu(
            buttonNumber: event.buttonNumber,
            modifiers: event.modifierFlags,
            mouseCaptured: mouseCaptured
        ) else {
            return nil
        }

        let menu = NSMenu()

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }

    @IBAction func copy(_ sender: Any?) {
        guard hasSelection else { return }
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = performBindingAction("select_all")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            hasSelection
        case #selector(paste(_:)):
            NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            surfaceHandle != nil
        default:
            true
        }
    }

    func requestHostClose() {
        guard launch.mode != .shell,
              launch.mode != .managedShell else {
            return
        }
        onCloseRequest?()
    }

    func processDidRequestClose(processAlive: Bool) {
        if launch.mode == .managedShell {
            return
        }
        if !processAlive || launch.mode == .shell {
            onCloseRequest?()
        }
    }

    func processDidExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) {
        onProcessExit?(exitCode, runtimeMilliseconds)
    }

    func sendText(_ text: String) {
        guard let surfaceHandle, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes {
            guard let baseAddress = $0.baseAddress else { return }
            ghostty_surface_text(
                surfaceHandle,
                baseAddress.assumingMemoryBound(to: CChar.self),
                UInt(bytes.count)
            )
        }
    }

    func sendKey(_ key: TerminalInputKey) {
        switch key {
        case .enter:
            sendSyntheticKey(keyCode: UInt32(kVK_Return))
        case .escape:
            sendSyntheticKey(keyCode: UInt32(kVK_Escape))
        case .up:
            sendSyntheticKey(keyCode: UInt32(kVK_UpArrow))
        case .down:
            sendSyntheticKey(keyCode: UInt32(kVK_DownArrow))
        case .left:
            sendSyntheticKey(keyCode: UInt32(kVK_LeftArrow))
        case .right:
            sendSyntheticKey(keyCode: UInt32(kVK_RightArrow))
        case .interrupt:
            sendSyntheticKey(
                keyCode: UInt32(kVK_ANSI_C),
                modifiers: GHOSTTY_MODS_CTRL,
                text: "c",
                unshiftedCodepoint: 99
            )
        }
    }

    var processHasExited: Bool {
        surfaceHandle.map(ghostty_surface_process_exited) ?? true
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
        defer { GhosttyPinnedTextAPI.free(&text) }
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

    func setHostVisibility(_ visible: Bool) {
        guard hostVisible != visible else { return }
        if !visible {
            cancelMouseInteraction()
        }
        hostVisible = visible
        if visible {
            // Apply the latest deferred geometry while the surface is still
            // hidden, so its grid is current before the first visible frame.
            updateDisplayProperties()
        }
        isHidden = !visible
        updateOcclusion()
        updateFocus()
        if visible, focusesWhenAttached, let window {
            focusesWhenAttached = false
            window.makeFirstResponder(self)
        }
    }

    func requestNewTab() {
        onNewTabRequest?()
    }

    func requestCloseTab() {
        onCloseTabRequest?()
    }

    func requestTabNavigation(_ request: TerminalTabNavigationRequest) {
        onTabNavigationRequest?(request)
    }

    func requestMoveTab(by amount: Int) {
        onMoveTabRequest?(amount)
    }

    func requestRenameTab(_ name: String?) {
        onRenameTabRequest?(name)
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
        guard hostVisible, let window else {
            focusesWhenAttached = true
            return
        }
        focusesWhenAttached = false
        window.makeFirstResponder(self)
    }

    func cancelPendingFocus() {
        focusesWhenAttached = false
    }

    func shutdown() {
        cancelMouseInteraction()
        guard !isShuttingDown, let surfaceHandle else { return }
        isShuttingDown = true
        removeObservers()
        onCloseRequest = nil
        onProcessExit = nil
        onTitleChange = nil
        onWorkingDirectoryChange = nil
        onNewTabRequest = nil
        onCloseTabRequest = nil
        onTabNavigationRequest = nil
        onMoveTabRequest = nil
        onRenameTabRequest = nil
        onBecameFocused = nil
        focusesWhenAttached = false
        ghostty_surface_free(surfaceHandle)
        self.surfaceHandle = nil
    }

    private func cancelMouseInteraction() {
        dispatchMouseCommands(mouseRouter.cancel())
        if let input = secondaryClickRouter.cancel() {
            _ = sendMouseButton(
                input,
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT
            )
        }
    }

    private static func context(
        for context: TerminalSurfaceContext
    ) -> ghostty_surface_context_e {
        switch context {
        case .window:
            GHOSTTY_SURFACE_CONTEXT_WINDOW
        case .tab:
            GHOSTTY_SURFACE_CONTEXT_TAB
        case .split:
            GHOSTTY_SURFACE_CONTEXT_SPLIT
        }
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
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.updateOcclusion()
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
                    self?.updateOcclusion()
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

    private func updateOcclusion() {
        guard let surfaceHandle else { return }
        let visible = hostVisible
            && window?.occlusionState.contains(.visible) == true
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
        let focused = hostVisible
            && window?.isKeyWindow == true
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
        guard let requestedSize = resizePolicy.requestedSize(
            size,
            hostVisible: hostVisible
        ) else {
            return
        }
        ghostty_surface_set_size(
            surfaceHandle,
            UInt32(requestedSize.width),
            UInt32(requestedSize.height)
        )
    }

    private func sendKey(
        _ event: NSEvent,
        action: ghostty_input_action_e
    ) {
        guard let surfaceHandle else { return }
        var key = makeKeyEvent(event, action: action)
        let characters = action.rawValue == GHOSTTY_ACTION_RELEASE.rawValue
            ? nil
            : GhosttyKeyEventText.sendableText(for: event)
        if let characters {
            characters.withCString {
                key.text = $0
                _ = ghostty_surface_key(surfaceHandle, key)
            }
        } else {
            _ = ghostty_surface_key(surfaceHandle, key)
        }
    }

    private func sendSyntheticKey(
        keyCode: UInt32,
        modifiers: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0
    ) {
        guard let surfaceHandle else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = modifiers
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = keyCode
        key.composing = false
        key.unshifted_codepoint = unshiftedCodepoint
        if let text {
            text.withCString {
                key.text = $0
                _ = ghostty_surface_key(surfaceHandle, key)
            }
        } else {
            _ = ghostty_surface_key(surfaceHandle, key)
        }
        key.action = GHOSTTY_ACTION_RELEASE
        key.text = nil
        _ = ghostty_surface_key(surfaceHandle, key)
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
    ) -> Bool {
        sendMouseButton(
            mouseInput(event),
            state: state,
            button: button
        )
    }

    private func sendMouseButton(
        _ input: GhosttyMouseInput,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) -> Bool {
        guard let surfaceHandle else { return false }
        sendMousePosition(input)
        return ghostty_surface_mouse_button(
            surfaceHandle,
            state,
            button,
            Self.modifiers(input.modifiers)
        )
    }

    private func sendMousePosition(_ event: NSEvent) {
        sendMousePosition(mouseInput(event))
    }

    private func sendMousePosition(_ input: GhosttyMouseInput) {
        guard let surfaceHandle else { return }
        ghostty_surface_mouse_pos(
            surfaceHandle,
            input.point.x,
            input.point.y,
            Self.modifiers(input.modifiers)
        )
    }

    private func mouseInput(_ event: NSEvent) -> GhosttyMouseInput {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return GhosttyMouseInput(
            point: GhosttyMouseCoordinateMapper.surfacePoint(
                viewPoint: viewPoint,
                bounds: bounds,
                isFlipped: isFlipped
            ),
            modifiers: event.modifierFlags
        )
    }

    private func dispatchMouseCommands(
        _ commands: [GhosttyMouseRoutingCommand]
    ) {
        guard let surfaceHandle else { return }

        for command in commands {
            switch command {
            case .position(let input):
                sendMousePosition(input)

            case .leftButton(let action, let input):
                let state: ghostty_input_mouse_state_e = switch action {
                case .press:
                    GHOSTTY_MOUSE_PRESS
                case .release:
                    GHOSTTY_MOUSE_RELEASE
                }
                _ = ghostty_surface_mouse_button(
                    surfaceHandle,
                    state,
                    GHOSTTY_MOUSE_LEFT,
                    Self.modifiers(input.modifiers)
                )
            }
        }
    }

    private var hasSelection: Bool {
        surfaceHandle.map(ghostty_surface_has_selection) ?? false
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surfaceHandle else { return false }
        return action.withCString {
            ghostty_surface_binding_action(
                surfaceHandle,
                $0,
                UInt(action.utf8.count)
            )
        }
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

/// Ghostty v1.3.1's exported function takes only the text pointer even though
/// the pinned public header still declares a leading surface argument.
@_silgen_name("ghostty_surface_free_text")
private func ghosttySurfaceFreeTextV131(
    _ text: UnsafeMutablePointer<ghostty_text_s>
)

private enum GhosttyPinnedTextAPI {
    static func free(_ text: UnsafeMutablePointer<ghostty_text_s>) {
        ghosttySurfaceFreeTextV131(text)
    }
}
