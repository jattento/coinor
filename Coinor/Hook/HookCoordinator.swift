import Foundation

@MainActor
final class HookCoordinator: ObservableObject {
    @Published private(set) var lastError: String?
    var onError: ((String) -> Void)?

    private let listener: HookEventListener
    private let runtimes: ConversationRuntimeManager
    private var lifecycle = HookLifecycleState()
    private var listeningTask: Task<Void, Never>?

    init(
        listener: HookEventListener,
        runtimes: ConversationRuntimeManager
    ) {
        self.listener = listener
        self.runtimes = runtimes
    }

    func start() {
        guard listeningTask == nil else { return }
        listeningTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in listener.events() {
                    if Task.isCancelled { break }
                    consume(event)
                }
            } catch {
                lastError = error.localizedDescription
                onError?(error.localizedDescription)
            }
        }
    }

    func activateRoot(sessionID: String) {
        let opened = lifecycle.activateRoot(sessionID: sessionID)
        opened.forEach(runtimes.openSubagent)
    }

    func rootProcessExited(sessionID: String) {
        let closed = lifecycle.rootProcessExited(sessionID: sessionID)
        runtimes.closeSubagents(sessionIDs: Set(closed))
        runtimes.rootProcessExited(sessionID: sessionID)
    }

    func deactivateRoot(sessionID: String) {
        let closed = lifecycle.deactivateRoot(sessionID: sessionID)
        runtimes.closeSubagents(sessionIDs: Set(closed))
    }

    func reconcilePersistedLine(
        sessionID: String,
        data: Data
    ) {
        consume(
            lifecycle.applyPersistedRecord(
                sessionID: sessionID,
                jsonLine: data
            )
        )
    }

    func reconcile(
        _ observation: GrokSubagentLifecycleObservation,
        workingDirectory: String
    ) {
        consume(
            lifecycle.apply(
                observation,
                workingDirectory: workingDirectory
            )
        )
    }

    func rootSessionID(for sessionID: String) -> String? {
        lifecycle.rootSessionID(for: sessionID)
    }

    func activePanes(rootSessionID: String) -> [HookPaneRecord] {
        lifecycle.orderedPanes.filter {
            $0.rootSessionID == rootSessionID
        }
    }

    func stop() {
        listeningTask?.cancel()
        listeningTask = nil
        listener.stop()
    }

    private func consume(_ event: GrokHookEvent) {
        consume(lifecycle.apply(event))
    }

    private func consume(_ action: HookLifecycleAction) {
        switch action {
        case .panesOpened(let panes):
            panes.forEach(runtimes.openSubagent)
        case .panesClosed(let ids):
            runtimes.closeSubagents(sessionIDs: Set(ids))
        case let .panesChanged(opened, closed):
            runtimes.closeSubagents(sessionIDs: Set(closed))
            opened.forEach(runtimes.openSubagent)
        case .rootObserved, .buffered, .ignored:
            break
        }
    }
}
