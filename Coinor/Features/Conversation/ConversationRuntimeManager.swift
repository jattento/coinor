import Foundation
import SwiftUI

struct ConversationTerminalTab: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case main
        case shell
    }

    let id: String
    let name: String
    let kind: Kind
}

struct ConversationTabRenameRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let tabID: String

    init(tabID: String) {
        self.tabID = tabID
    }
}

@MainActor
final class ConversationRuntime: ObservableObject, Identifiable {
    let id: String
    let root: TerminalSession

    @Published private(set) var descendants: [TerminalSession] = []
    @Published private(set) var shellTabs: [TerminalSession] = []
    @Published private(set) var tabMetadata: ConversationTabMetadata
    @Published private(set) var pendingRenameRequest:
        ConversationTabRenameRequest?
    @Published var rootActivity: RuntimeActivity = .working
    @Published var descendantActivity: [String: RuntimeActivity] = [:]

    var onTabMetadataChange: ((ConversationTabMetadata) -> Void)?
    var onArchiveUnloadEligibilityChange: (() -> Void)?

    private var descendantOrders: [String: SubagentStartOrder] = [:]
    private var archiveUnloadPolicy = RuntimeArchiveUnloadPolicy()
    private var lastFocusedMainPaneID: String
    private var shellBaseWorkingDirectory: String?

    init(
        id: String,
        root: TerminalSession,
        shellBaseWorkingDirectory: String?,
        tabMetadata: ConversationTabMetadata
    ) {
        self.id = id
        self.root = root
        self.shellBaseWorkingDirectory = shellBaseWorkingDirectory
        self.tabMetadata = tabMetadata.normalized()
        self.lastFocusedMainPaneID = root.id
        bindMainSession(root)
    }

    var tabs: [ConversationTerminalTab] {
        [
            ConversationTerminalTab(
                id: ConversationTabMetadata.mainID,
                name: tabMetadata.mainName,
                kind: .main
            ),
        ] + tabMetadata.shellTabs.map {
            ConversationTerminalTab(
                id: $0.id,
                name: $0.name,
                kind: .shell
            )
        }
    }

    var selectedTabID: String {
        tabMetadata.selectedTabID
    }

    var isMainTabSelected: Bool {
        selectedTabID == ConversationTabMetadata.mainID
    }

    var hasShellTabs: Bool {
        !shellTabs.isEmpty
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

    func activatePersistedShellTabs() {
        shellTabs = tabMetadata.shellTabs.map(makeShellSession)
    }

    func resolveShellBaseWorkingDirectory(_ directory: String) {
        guard shellBaseWorkingDirectory == nil, !directory.isEmpty else {
            return
        }
        shellBaseWorkingDirectory = directory
        guard !shellTabs.isEmpty else { return }
        shellTabs.forEach { $0.shutdown() }
        shellTabs = tabMetadata.shellTabs.map(makeShellSession)
        focusSelectedTab()
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
        bindMainSession(session)
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
        if sessionIDs.contains(lastFocusedMainPaneID) {
            lastFocusedMainPaneID = root.id
        }
    }

    func createShellTab() {
        var updated = tabMetadata
        let tab = updated.appendShell(
            id: UUID().uuidString.lowercased()
        )
        let session = makeShellSession(tab)
        tabMetadata = updated
        shellTabs.append(session)
        publishTabMetadata()
        focusSelectedTab()
    }

    func closeSelectedShellTab() {
        closeShellTab(tabID: selectedTabID)
    }

    func closeShellTab(tabID: String) {
        guard tabID != ConversationTabMetadata.mainID,
              let sessionIndex = shellTabs.firstIndex(where: {
                  $0.id == tabID
              }) else {
            return
        }
        shellTabs[sessionIndex].shutdown()
        shellTabs.remove(at: sessionIndex)
        var updated = tabMetadata
        updated.closeShell(tabID: tabID)
        tabMetadata = updated
        publishTabMetadata()
        onArchiveUnloadEligibilityChange?()
        focusSelectedTab()
    }

    func selectTab(tabID: String) {
        guard tabMetadata.contains(tabID: tabID) else { return }
        if selectedTabID != tabID {
            var updated = tabMetadata
            updated.select(tabID: tabID)
            tabMetadata = updated
            publishTabMetadata()
        }
        focusSelectedTab()
    }

    func renameTab(tabID: String, to name: String) {
        guard tabMetadata.contains(tabID: tabID) else { return }
        var updated = tabMetadata
        updated.rename(tabID: tabID, to: name)
        guard updated != tabMetadata else { return }
        tabMetadata = updated
        publishTabMetadata()
    }

    func moveShellTab(tabID: String, toward targetTabID: String?) {
        guard tabMetadata.shellTabs.contains(where: {
            $0.id == tabID
        }) else {
            return
        }
        let finalIndex: Int
        if targetTabID == ConversationTabMetadata.mainID {
            finalIndex = 0
        } else if let targetTabID,
                  let targetIndex = tabMetadata.shellTabs.firstIndex(
                      where: { $0.id == targetTabID }
                  ) {
            finalIndex = targetIndex
        } else {
            finalIndex = max(tabMetadata.shellTabs.count - 1, 0)
        }
        moveShellTab(tabID: tabID, toFinalIndex: finalIndex)
    }

    func moveShellTab(tabID: String, by amount: Int) {
        guard let sourceIndex = tabMetadata.shellTabs.firstIndex(where: {
            $0.id == tabID
        }), tabMetadata.shellTabs.count > 1 else {
            return
        }
        let count = tabMetadata.shellTabs.count
        let normalizedAmount = amount % count
        let destination = (
            sourceIndex + normalizedAmount + count
        ) % count
        moveShellTab(
            tabID: tabID,
            toFinalIndex: destination
        )
    }

    func navigateTabs(_ request: TerminalTabNavigationRequest) {
        let ids = tabMetadata.orderedTabIDs
        guard !ids.isEmpty,
              let selectedIndex = ids.firstIndex(of: selectedTabID)
        else {
            return
        }
        let destination: Int?
        switch request {
        case .previous:
            destination = (selectedIndex - 1 + ids.count) % ids.count
        case .next:
            destination = (selectedIndex + 1) % ids.count
        case .last:
            destination = ids.count - 1
        case .index(let oneBasedIndex):
            let zeroBasedIndex = oneBasedIndex - 1
            destination = ids.indices.contains(zeroBasedIndex)
                ? zeroBasedIndex
                : nil
        }
        if let destination {
            selectTab(tabID: ids[destination])
        }
    }

    func consumeRenameRequest(_ requestID: UUID) {
        guard pendingRenameRequest?.id == requestID else { return }
        pendingRenameRequest = nil
    }

    func focusSelectedTab() {
        cancelPendingFocusRequests()
        let selectedID = selectedTabID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedTabID == selectedID else {
                return
            }
            if selectedID == ConversationTabMetadata.mainID {
                self.focusMainPane()
            } else {
                self.shellTabs.first {
                    $0.id == selectedID
                }?.focus()
            }
        }
    }

    func focusAttentionPaneIfMainSelected() {
        guard isMainTabSelected else { return }
        focusMainPane()
    }

    func markArchived() {
        archiveUnloadPolicy.markArchived()
    }

    func cancelArchiveUnload() {
        archiveUnloadPolicy.cancel()
    }

    func shouldUnloadAfterArchive() -> Bool {
        archiveUnloadPolicy.shouldUnload(
            activity: aggregateActivity,
            hasShellTabs: hasShellTabs
        )
    }

    func shutdown() {
        shellTabs.forEach { $0.shutdown() }
        shellTabs.removeAll()
        descendants.forEach { $0.shutdown() }
        descendants.removeAll()
        root.shutdown()
    }

    private func makeShellSession(
        _ tab: ShellTabMetadata
    ) -> TerminalSession {
        let terminal = TerminalSession(
            launch: TerminalLaunchRequest(
                shellTabID: tab.id,
                workingDirectory: shellBaseWorkingDirectory ?? ""
            ),
            runtime: root.runtime
        )
        bindShellSession(terminal, tabID: tab.id)
        terminal.onCloseRequest = { [weak self] in
            self?.closeShellTab(tabID: tab.id)
        }
        return terminal
    }

    private func bindMainSession(_ session: TerminalSession) {
        bindTabActions(
            session,
            tabID: ConversationTabMetadata.mainID
        )
        session.onBecameFocused = { [weak self, weak session] in
            guard let self, let session else { return }
            self.lastFocusedMainPaneID = session.id
        }
    }

    private func bindShellSession(
        _ session: TerminalSession,
        tabID: String
    ) {
        bindTabActions(session, tabID: tabID)
        session.onBecameFocused = { [weak self] in
            guard let self, self.selectedTabID != tabID else { return }
            self.selectTab(tabID: tabID)
        }
    }

    private func bindTabActions(
        _ session: TerminalSession,
        tabID: String
    ) {
        session.onNewTabRequest = { [weak self] in
            self?.createShellTab()
        }
        session.onCloseTabRequest = { [weak self] in
            self?.closeShellTab(tabID: tabID)
        }
        session.onTabNavigationRequest = { [weak self] request in
            self?.navigateTabs(request)
        }
        session.onMoveTabRequest = { [weak self] amount in
            guard tabID != ConversationTabMetadata.mainID else { return }
            self?.moveShellTab(tabID: tabID, by: amount)
        }
        session.onRenameTabRequest = { [weak self] name in
            guard let self else { return }
            if let name {
                self.renameTab(tabID: tabID, to: name)
            } else {
                self.pendingRenameRequest = ConversationTabRenameRequest(
                    tabID: tabID
                )
            }
        }
    }

    private func moveShellTab(
        tabID: String,
        toFinalIndex: Int
    ) {
        var updated = tabMetadata
        updated.moveShell(
            tabID: tabID,
            toFinalIndex: toFinalIndex
        )
        guard updated != tabMetadata else { return }
        tabMetadata = updated
        let sessionsByID = Dictionary(
            uniqueKeysWithValues: shellTabs.map { ($0.id, $0) }
        )
        shellTabs = updated.shellTabs.compactMap {
            sessionsByID[$0.id]
        }
        publishTabMetadata()
    }

    private func focusMainPane() {
        cancelPendingFocusRequests()
        if let attentionPaneID {
            if attentionPaneID == root.id {
                root.focus()
            } else {
                descendants.first {
                    $0.id == attentionPaneID
                }?.focus()
            }
            return
        }
        if lastFocusedMainPaneID == root.id {
            root.focus()
            return
        }
        if let descendant = descendants.first(where: {
            $0.id == lastFocusedMainPaneID
        }) {
            descendant.focus()
        } else {
            lastFocusedMainPaneID = root.id
            root.focus()
        }
    }

    private func publishTabMetadata() {
        onTabMetadataChange?(tabMetadata)
    }

    private func cancelPendingFocusRequests() {
        root.cancelPendingFocus()
        descendants.forEach { $0.cancelPendingFocus() }
        shellTabs.forEach { $0.cancelPendingFocus() }
    }
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
    var onTabMetadataChange:
        ((String, ConversationTabMetadata) -> Void)?

    init(
        ghosttyRuntime: GhosttyRuntime,
        grokExecutable: String,
        leaderSocket: String
    ) {
        self.ghosttyRuntime = ghosttyRuntime
        self.grokExecutable = grokExecutable
        self.leaderSocket = leaderSocket
    }

    var selectedRuntime: ConversationRuntime? {
        guard let selectedSessionID else { return nil }
        return runtime(sessionID: selectedSessionID)
    }

    func activateRoot(
        sessionID: String,
        workingDirectory: String,
        mode: TerminalLaunchRequest.Mode,
        additionalArguments: [String] = [],
        shellDirectorySource: ConversationShellDirectorySource =
            .rootLaunchDirectory,
        tabMetadata: ConversationTabMetadata = .initial
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
        let shellBaseWorkingDirectory: String?
        switch shellDirectorySource {
        case .rootLaunchDirectory:
            shellBaseWorkingDirectory = workingDirectory
        case .explicit(let directory):
            shellBaseWorkingDirectory = directory
        case .unavailable:
            shellBaseWorkingDirectory = nil
        }
        let runtime = ConversationRuntime(
            id: sessionID,
            root: rootSession,
            shellBaseWorkingDirectory: shellBaseWorkingDirectory,
            tabMetadata: tabMetadata
        )
        runtime.onTabMetadataChange = { [weak self, weak runtime] tabs in
            guard let runtime else { return }
            self?.onTabMetadataChange?(runtime.id, tabs)
        }
        runtime.onArchiveUnloadEligibilityChange = {
            [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.unloadIfArchivedAndInactive(runtime)
        }
        rootSession.onCloseRequest = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            if let onRootProcessExit = self.onRootProcessExit {
                onRootProcessExit(runtime.id)
            } else {
                self.rootProcessExited(sessionID: runtime.id)
            }
        }
        runtime.activatePersistedShellTabs()
        runtimes.append(runtime)
        selectedSessionID = sessionID
        runtime.focusSelectedTab()
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
            mode: .resume,
            surfaceContext: .split
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

    func createShellTab() {
        selectedRuntime?.createShellTab()
    }

    func closeSelectedShellTab() {
        selectedRuntime?.closeSelectedShellTab()
    }

    func selectTab(at oneBasedIndex: Int) {
        selectedRuntime?.navigateTabs(.index(oneBasedIndex))
    }

    func selectLastTab() {
        selectedRuntime?.navigateTabs(.last)
    }

    func resolveShellBaseWorkingDirectory(
        sessionID: String,
        directory: String
    ) {
        runtime(sessionID: sessionID)?
            .resolveShellBaseWorkingDirectory(directory)
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
            runtime.focusAttentionPaneIfMainSelected()
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
        runtime(sessionID: sessionID)?.focusSelectedTab()
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
