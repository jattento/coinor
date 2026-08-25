import AppKit
import SwiftUI

enum TerminalInputKey: String, CaseIterable, Sendable {
    case enter
    case escape
    case up
    case down
    case left
    case right
    case interrupt
}

struct TerminalFocusLatch {
    private var isPending = false

    mutating func request(perform: (() -> Void)?) {
        guard let perform else {
            isPending = true
            return
        }
        perform()
    }

    mutating func consumeOnAttachment(perform: () -> Void) {
        guard isPending else { return }
        isPending = false
        perform()
    }

    mutating func cancel() {
        isPending = false
    }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let launch: TerminalLaunchRequest
    let runtime: GhosttyRuntime
    let resumePolicy: SubagentResumePolicy?
    let reconnectPolicy: RemoteReconnectPolicy?
    let keepsSurfaceAfterProcessExit: Bool

    @Published private(set) var generation = 0
    @Published private(set) var title = ""
    @Published private(set) var workingDirectory: String
    @Published private(set) var startupError: String?
    @Published private(set) var exitCode: UInt32?
    /// Only meaningful for a remote pane. Drives the reconnect banner.
    @Published private(set) var connectionState: RemoteConnectionState =
        .connected

    weak var surface: GhosttySurfaceView?
    var onCloseRequest: (() -> Void)?
    var onNewTabRequest: (() -> Void)?
    var onCloseTabRequest: (() -> Void)?
    var onTabNavigationRequest: ((TerminalTabNavigationRequest) -> Void)?
    var onMoveTabRequest: ((Int) -> Void)?
    var onRenameTabRequest: ((String?) -> Void)?
    var onBecameFocused: (() -> Void)?
    var onProcessDidExit: ((UInt32) -> Void)?
    private var completedRetries = 0
    private var completedReconnects = 0
    private var focusLatch = TerminalFocusLatch()
    private var retryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(
        launch: TerminalLaunchRequest,
        runtime: GhosttyRuntime,
        resumePolicy: SubagentResumePolicy? = nil,
        keepsSurfaceAfterProcessExit: Bool = false
    ) {
        self.id = launch.id
        self.launch = launch
        self.runtime = runtime
        self.resumePolicy = resumePolicy
        self.reconnectPolicy = launch.remote == nil
            ? nil
            : RemoteReconnectPolicy()
        self.keepsSurfaceAfterProcessExit = keepsSurfaceAfterProcessExit
        self.workingDirectory = launch.workingDirectory
    }

    static let stableConnectionMilliseconds: UInt64 = 60_000

    func attach(_ surface: GhosttySurfaceView) {
        self.surface = surface
        if case .reconnecting = connectionState {
            connectionState = .connected
        }
        let attachedGeneration = generation
        surface.onCloseRequest = { [weak self] in
            self?.onCloseRequest?()
        }
        surface.onProcessExit = {
            [weak self, weak surface] exitCode, milliseconds in
            guard let self, let surface else { return }
            self.processDidExit(
                surface: surface,
                generation: attachedGeneration,
                exitCode: exitCode,
                runtimeMilliseconds: milliseconds
            )
        }
        surface.onTitleChange = { [weak self] title in
            self?.title = title
        }
        surface.onWorkingDirectoryChange = { [weak self] directory in
            self?.workingDirectory = directory
        }
        surface.onNewTabRequest = { [weak self] in
            self?.onNewTabRequest?()
        }
        surface.onCloseTabRequest = { [weak self] in
            self?.onCloseTabRequest?()
        }
        surface.onTabNavigationRequest = { [weak self] request in
            self?.onTabNavigationRequest?(request)
        }
        surface.onMoveTabRequest = { [weak self] amount in
            self?.onMoveTabRequest?(amount)
        }
        surface.onRenameTabRequest = { [weak self] name in
            self?.onRenameTabRequest?(name)
        }
        surface.onBecameFocused = { [weak self] in
            self?.onBecameFocused?()
        }
        focusLatch.consumeOnAttachment {
            surface.focusTerminal()
        }
    }

    func detach(_ surface: GhosttySurfaceView) {
        if self.surface === surface {
            self.surface = nil
        }
    }

    func focus() {
        if let surface {
            focusLatch.request {
                surface.focusTerminal()
            }
        } else {
            focusLatch.request(perform: nil)
        }
    }

    func cancelPendingFocus() {
        focusLatch.cancel()
        surface?.cancelPendingFocus()
    }

    func write(_ text: String) {
        surface?.sendText(text)
    }

    func sendKey(_ key: TerminalInputKey) {
        surface?.sendKey(key)
    }

    func screenText() -> String {
        surface?.screenText() ?? ""
    }

    var isAttached: Bool {
        surface != nil
    }

    var processHasExited: Bool {
        surface?.processHasExited ?? (exitCode != nil)
    }

    /// Reattaches a remote pane after the user dismissed the automatic
    /// attempts. The remote session is still alive, so this is a new SSH
    /// channel to the same conversation.
    func reconnect() {
        guard reconnectPolicy != nil else { return }
        completedReconnects = 0
        connectionState = .connected
        recreate()
    }

    func recreate() {
        retryTask?.cancel()
        retryTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        surface?.shutdown()
        surface = nil
        generation += 1
    }

    func shutdown() {
        retryTask?.cancel()
        retryTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        surface?.shutdown()
        surface = nil
    }

    private func scheduleReconnect(
        policy: RemoteReconnectPolicy,
        generation: Int
    ) {
        guard reconnectTask == nil,
              let delay = policy.delay(after: completedReconnects) else {
            connectionState = .disconnected
            return
        }
        connectionState = .reconnecting(
            attempt: completedReconnects + 1,
            of: policy.delays.count
        )
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  self.generation == generation else {
                return
            }
            self.completedReconnects += 1
            self.reconnectTask = nil
            self.recreate()
        }
    }

    private func processDidExit(
        surface: GhosttySurfaceView,
        generation: Int,
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) {
        guard self.surface === surface,
              self.generation == generation else {
            return
        }
        self.exitCode = exitCode
        onProcessDidExit?(exitCode)
        if reconnectPolicy != nil,
           runtimeMilliseconds > Self.stableConnectionMilliseconds {
            // A connection that lasted is not a failing one: a later drop
            // deserves the whole reconnect budget again.
            completedReconnects = 0
        }
        if let reconnectPolicy,
           reconnectPolicy.shouldReconnect(
               exitCode: exitCode,
               completedAttempts: completedReconnects
           ) {
            scheduleReconnect(policy: reconnectPolicy, generation: generation)
            return
        }
        if reconnectPolicy != nil,
           exitCode == RemoteReconnectPolicy.sshFailureExitCode {
            // The work is still running on the remote computer, so the pane
            // stays and offers an explicit reconnect instead of closing the
            // conversation.
            connectionState = .disconnected
            return
        }
        if keepsSurfaceAfterProcessExit {
            return
        }
        guard let resumePolicy else {
            onCloseRequest?()
            return
        }
        guard retryTask == nil else {
            return
        }
        guard let delay = resumePolicy.delay(after: completedRetries),
              runtimeMilliseconds
                <= resumePolicy.maximumInitialRuntimeMilliseconds else {
            onCloseRequest?()
            return
        }

        retryTask = Task { [weak self, weak surface] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  let surface,
                  self.surface === surface,
                  self.generation == generation else {
                return
            }
            let terminalText = surface.screenText()
            guard resumePolicy.shouldRetry(
                terminalText: terminalText,
                processRuntimeMilliseconds: runtimeMilliseconds,
                completedRetries: completedRetries
            ) else {
                retryTask = nil
                onCloseRequest?()
                return
            }
            completedRetries += 1
            startupError = SubagentResumePolicy.missingSessionLine
            recreate()
        }
    }
}

/// Hosts a terminal surface, resized from a `GeometryReader`-reported size
/// rather than from the wrapped `NSView`'s own `bounds`.
///
/// AppKit can lag behind SwiftUI's layout during animated or fast-moving
/// resizes (window resize, sidebar drag, split resize), leaving the view's
/// `bounds` briefly stale relative to the size SwiftUI already committed to.
/// Reading size from `GeometryReader` instead keeps the terminal's grid in
/// sync with its actual on-screen slot, matching the approach Ghostty's own
/// macOS app uses around `libghostty`.
@MainActor
struct TerminalSurfaceRepresentable: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool

    init(session: TerminalSession, isVisible: Bool = true) {
        self.session = session
        self.isVisible = isVisible
    }

    var body: some View {
        GeometryReader { proxy in
            TerminalSurfaceHostingView(
                session: session,
                isVisible: isVisible,
                hostSize: proxy.size
            )
        }
    }
}

@MainActor
private struct TerminalSurfaceHostingView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let hostSize: CGSize

    func makeCoordinator() -> TerminalSession {
        session
    }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalClippingContainer()
        if let failure = session.launch.surfaceStartupFailure() {
            container.host(TerminalErrorView(message: failure))
            return container
        }
        do {
            let view = try GhosttySurfaceView(
                runtime: session.runtime,
                launch: session.launch
            )
            view.setHostVisibility(isVisible)
            view.sizeDidChange(hostSize)
            session.attach(view)
            container.host(view)
            return container
        } catch {
            container.host(TerminalErrorView(message: error.localizedDescription))
            return container
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let surface = (nsView as? TerminalClippingContainer)?
            .hostedView as? GhosttySurfaceView else {
            return
        }
        surface.setHostVisibility(isVisible)
        surface.sizeDidChange(hostSize)
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: TerminalSession
    ) {
        guard let surface = (nsView as? TerminalClippingContainer)?
            .hostedView as? GhosttySurfaceView else {
            return
        }
        coordinator.detach(surface)
        surface.shutdown()
    }
}

/// Clips its hosted view to its own bounds.
///
/// SwiftUI does not clip an `NSViewRepresentable`'s content by default, and
/// Ghostty's renderer can briefly hold a frame sized for the surface's
/// previous geometry while a resize is in flight — possibly under a layer it
/// replaced outright, past whatever `GhosttySurfaceView` itself masks. This
/// container sits between SwiftUI and the terminal so that content can never
/// visually bleed into neighboring chrome (the tab strip above, the prompt
/// input below), regardless of what layer Ghostty ends up owning.
private final class TerminalClippingContainer: NSView {
    private(set) var hostedView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func host(_ view: NSView) {
        hostedView?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        hostedView = view
    }
}

private final class TerminalErrorView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: message)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}
