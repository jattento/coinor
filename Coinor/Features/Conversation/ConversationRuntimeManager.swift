import Foundation
import SwiftUI

@MainActor
final class ConversationRuntime: ObservableObject, Identifiable {
    let id: String
    let root: TerminalSession
    @Published private(set) var descendants: [TerminalSession] = []
    @Published var rootActivity: RuntimeActivity = .working
    @Published var descendantActivity: [String: RuntimeActivity] = [:]

    init(id: String, root: TerminalSession) {
        self.id = id
        self.root = root
    }

    var aggregateActivity: RuntimeActivity {
        RuntimeActivity.aggregate(
            [rootActivity] + descendants.map {
                descendantActivity[$0.id] ?? .idle
            }
        )
    }

    var attentionPaneID: String? {
        if rootActivity == .needsInput {
            return root.id
        }
        return descendants.first {
            descendantActivity[$0.id] == .needsInput
        }?.id
    }

    func addDescendant(
        _ session: TerminalSession,
        startedAt: String,
        sequence: UInt64
    ) {
        guard !descendants.contains(where: { $0.id == session.id }) else {
            return
        }
        descendantOrders[session.id] = SubagentStartOrder(
            timestamp: startedAt,
            sequence: sequence,
            sessionID: session.id
        )
        descendants.append(session)
        descendants.sort {
            let left = descendantOrders[$0.id] ?? SubagentStartOrder(
                timestamp: "",
                sequence: .max,
                sessionID: $0.id
            )
            let right = descendantOrders[$1.id] ?? SubagentStartOrder(
                timestamp: "",
                sequence: .max,
                sessionID: $1.id
            )
            return left < right
        }
    }

    func removeDescendants(sessionIDs: Set<String>) {
        for session in descendants where sessionIDs.contains(session.id) {
            session.shutdown()
            descendantActivity.removeValue(forKey: session.id)
            descendantOrders.removeValue(forKey: session.id)
        }
        descendants.removeAll { sessionIDs.contains($0.id) }
    }

    func focusAttentionPane() {
        if attentionPaneID == root.id {
            root.focus()
            return
        }
        descendants.first(where: { $0.id == attentionPaneID })?.focus()
    }

    func markArchived() {
        archiveUnloadPolicy.markArchived()
    }

    func cancelArchiveUnload() {
        archiveUnloadPolicy.cancel()
    }

    func shouldUnloadAfterArchive() -> Bool {
        archiveUnloadPolicy.shouldUnload(activity: aggregateActivity)
    }

    func shutdown() {
        descendants.forEach { $0.shutdown() }
        descendants.removeAll()
        root.shutdown()
    }

    private var descendantOrders: [String: SubagentStartOrder] = [:]
    private var archiveUnloadPolicy = RuntimeArchiveUnloadPolicy()
}

@MainActor
final class ConversationRuntimeManager: ObservableObject {
    @Published private(set) var runtimes: [ConversationRuntime] = []
    @Published var selectedSessionID: String?

    let ghosttyRuntime: GhosttyRuntime
    let grokExecutable: String
    let leaderSocket: String
    var onRootProcessExit: ((String) -> Void)?
    var onArchivedRuntimeUnload: ((String, String?) -> Void)?

    init(
        ghosttyRuntime: GhosttyRuntime,
        grokExecutable: String,
        leaderSocket: String
    ) {
        self.ghosttyRuntime = ghosttyRuntime
        self.grokExecutable = grokExecutable
        self.leaderSocket = leaderSocket
    }

    func activateRoot(
        sessionID: String,
        workingDirectory: String,
        mode: TerminalLaunchRequest.Mode,
        additionalArguments: [String] = []
    ) -> ConversationRuntime {
        if let existing = runtime(sessionID: sessionID) {
            selectedSessionID = sessionID
            return existing
        }

        let launch = TerminalLaunchRequest(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            grokExecutable: grokExecutable,
            leaderSocket: leaderSocket,
            mode: mode,
            additionalArguments: additionalArguments
        )
        let rootSession = TerminalSession(
            launch: launch,
            runtime: ghosttyRuntime
        )
        let runtime = ConversationRuntime(id: sessionID, root: rootSession)
        rootSession.onCloseRequest = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            if let onRootProcessExit = self.onRootProcessExit {
                onRootProcessExit(runtime.id)
            } else {
                self.rootProcessExited(sessionID: runtime.id)
            }
        }
        runtimes.append(runtime)
        selectedSessionID = sessionID
        return runtime
    }

    func openSubagent(_ pane: HookPaneRecord) {
        guard let rootRuntime = runtime(sessionID: pane.rootSessionID) else {
            return
        }
        let launch = TerminalLaunchRequest(
            sessionID: pane.childSessionID,
            workingDirectory: pane.workingDirectory,
            grokExecutable: grokExecutable,
            leaderSocket: leaderSocket,
            mode: .resume
        )
        let terminal = TerminalSession(
            launch: launch,
            runtime: ghosttyRuntime,
            resumePolicy: SubagentResumePolicy()
        )
        terminal.onCloseRequest = { [weak self] in
            self?.closeSubagents(sessionIDs: [pane.childSessionID])
        }
        rootRuntime.addDescendant(
            terminal,
            startedAt: pane.startedAt,
            sequence: pane.startSequence
        )
    }

    func closeSubagents(sessionIDs: Set<String>) {
        for runtime in runtimes {
            runtime.removeDescendants(sessionIDs: sessionIDs)
            unloadIfArchivedAndInactive(runtime)
        }
    }

    func setActivity(
        _ activity: RuntimeActivity,
        sessionID: String,
        rootSessionID: String
    ) {
        guard let runtime = runtime(sessionID: rootSessionID) else { return }
        if sessionID == rootSessionID {
            runtime.rootActivity = activity
        } else {
            runtime.descendantActivity[sessionID] = activity
        }
        if activity == .needsInput,
           selectedSessionID == rootSessionID {
            runtime.focusAttentionPane()
        }
        unloadIfArchivedAndInactive(runtime)
    }

    func markArchived(sessionID: String) {
        guard let runtime = runtime(sessionID: sessionID) else { return }
        runtime.markArchived()
        unloadIfArchivedAndInactive(runtime)
    }

    func markUnarchived(sessionID: String) {
        runtime(sessionID: sessionID)?.cancelArchiveUnload()
    }

    func select(sessionID: String) {
        selectedSessionID = sessionID
        runtime(sessionID: sessionID)?.focusAttentionPane()
    }

    func runtime(sessionID: String) -> ConversationRuntime? {
        runtimes.first { $0.id == sessionID }
    }

    func rootSessionID(containing sessionID: String) -> String? {
        runtimes.first {
            $0.id == sessionID
                || $0.descendants.contains(where: { $0.id == sessionID })
        }?.id
    }

    func workingDirectory(
        sessionID: String,
        rootSessionID: String
    ) -> String? {
        guard let runtime = runtime(sessionID: rootSessionID) else {
            return nil
        }
        if sessionID == rootSessionID {
            return runtime.root.workingDirectory
        }
        return runtime.descendants.first {
            $0.id == sessionID
        }?.workingDirectory
    }

    func rootProcessExited(sessionID: String) {
        guard let runtime = runtime(sessionID: sessionID) else { return }
        runtime.shutdown()
        runtimes.removeAll { $0.id == sessionID }
        if selectedSessionID == sessionID {
            selectedSessionID = runtimes.first?.id
        }
    }

    func shutdown() {
        runtimes.forEach { $0.shutdown() }
        runtimes.removeAll()
        ghosttyRuntime.shutdown()
    }

    private func unloadIfArchivedAndInactive(
        _ runtime: ConversationRuntime
    ) {
        guard runtime.shouldUnloadAfterArchive() else {
            return
        }
        runtime.shutdown()
        runtimes.removeAll { $0.id == runtime.id }
        if selectedSessionID == runtime.id {
            selectedSessionID = runtimes.first?.id
        }
        onArchivedRuntimeUnload?(runtime.id, selectedSessionID)
    }
}
