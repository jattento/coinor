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
    let keepsSurfaceAfterProcessExit: Bool

    @Published private(set) var generation = 0
    @Published private(set) var title = ""
    @Published private(set) var workingDirectory: String
    @Published private(set) var startupError: String?
    @Published private(set) var exitCode: UInt32?

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
    private var focusLatch = TerminalFocusLatch()
    private var retryTask: Task<Void, Never>?

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
        self.keepsSurfaceAfterProcessExit = keepsSurfaceAfterProcessExit
        self.workingDirectory = launch.workingDirectory
    }

    func attach(_ surface: GhosttySurfaceView) {
        self.surface = surface
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

    func recreate() {
        retryTask?.cancel()
        retryTask = nil
        surface?.shutdown()
        surface = nil
        generation += 1
    }

    func shutdown() {
        retryTask?.cancel()
        retryTask = nil
        surface?.shutdown()
        surface = nil
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

@MainActor
struct TerminalSurfaceRepresentable: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool

    init(session: TerminalSession, isVisible: Bool = true) {
        self.session = session
        self.isVisible = isVisible
    }

    func makeCoordinator() -> TerminalSession {
        session
    }

    func makeNSView(context: Context) -> NSView {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: session.launch.workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            let message = session.launch.workingDirectory.isEmpty
                ? "The conversation working directory is unavailable."
                : "The terminal working directory is unavailable:\n"
                    + session.launch.workingDirectory
            return TerminalErrorView(
                message: message
            )
        }
        do {
            let view = try GhosttySurfaceView(
                runtime: session.runtime,
                launch: session.launch
            )
            view.setHostVisibility(isVisible)
            session.attach(view)
            return view
        } catch {
            return TerminalErrorView(message: error.localizedDescription)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? GhosttySurfaceView)?
            .setHostVisibility(isVisible)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: 900, height: 600)
        )
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: TerminalSession
    ) {
        guard let surface = nsView as? GhosttySurfaceView else { return }
        coordinator.detach(surface)
        surface.shutdown()
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
