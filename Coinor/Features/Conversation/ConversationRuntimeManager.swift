import Foundation
import SwiftUI

struct ConversationTerminalTab: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case main
        case ide
        case shell
        case managed
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
    @Published private(set) var ideFresh: TerminalSession
    @Published private(set) var ideLazygit: TerminalSession
    @Published private(set) var shellTabs: [TerminalSession] = []
    @Published private(set) var managedTabs: [ManagedTerminalTab] = []
    @Published private(set) var tabMetadata: ConversationTabMetadata
    @Published private(set) var pendingRenameRequest:
        ConversationTabRenameRequest?
    @Published var rootActivity: RuntimeActivity = .working
    @Published var descendantActivity: [String: RuntimeActivity] = [:]

    var onTabMetadataChange: ((ConversationTabMetadata) -> Void)?
    private var descendantOrders: [String: SubagentStartOrder] = [:]
    private var lastFocusedMainPaneID: String
    private var lastFocusedIDEPaneID: String
    private var ideWorkingDirectory: String?
    private var shellBaseWorkingDirectory: String?
    @Published private var selectedManagedTabID: String?
    let execution: ConversationExecution

    init(
        id: String,
        root: TerminalSession,
        execution: ConversationExecution,
        ideWorkingDirectory: String?,
        shellBaseWorkingDirectory: String?,
        tabMetadata: ConversationTabMetadata
    ) {
        let resolvedIDEWorkingDirectory = ideWorkingDirectory ?? ""
        let ideFresh = TerminalSession(
            launch: TerminalLaunchRequest(
                commandID: "\(id).ide.fresh",
                workingDirectory: resolvedIDEWorkingDirectory,
                command: "fresh .",
                remote: execution.remote
            ),
            runtime: root.runtime
        )
        let ideLazygit = TerminalSession(
            launch: TerminalLaunchRequest(
                commandID: "\(id).ide.lazygit",
                workingDirectory: resolvedIDEWorkingDirectory,
                command: "lazygit",
                remote: execution.remote
            ),
            runtime: root.runtime
        )
        self.id = id
        self.root = root
        self.execution = execution
        self.ideFresh = ideFresh
        self.ideLazygit = ideLazygit
        self.ideWorkingDirectory = ideWorkingDirectory
        self.shellBaseWorkingDirectory = shellBaseWorkingDirectory
        self.tabMetadata = tabMetadata.normalized()
        self.lastFocusedMainPaneID = root.id
        self.lastFocusedIDEPaneID = ideFresh.id
        bindMainSession(root)
        bindIDESession(ideFresh)
        bindIDESession(ideLazygit)
    }

    var tabs: [ConversationTerminalTab] {
        [
            ConversationTerminalTab(
                id: ConversationTabMetadata.mainID,
                name: tabMetadata.mainName,
                kind: .main
            ),
            ConversationTerminalTab(
                id: ConversationTabMetadata.ideID,
                name: "IDE",
                kind: .ide
            ),
        ] + tabMetadata.shellTabs.map {
            ConversationTerminalTab(
                id: $0.id,
                name: $0.name,
                kind: .shell
            )
        } + managedTabs.map {
            ConversationTerminalTab(
                id: $0.id,
                name: $0.name,
                kind: .managed
            )
        }
    }

    var selectedTabID: String {
        selectedManagedTabID ?? tabMetadata.selectedTabID
    }

    var isMainTabSelected: Bool {
        selectedTabID == ConversationTabMetadata.mainID
    }

    var isIDETabSelected: Bool {
        selectedTabID == ConversationTabMetadata.ideID
    }

    var hasShellTabs: Bool {
        !shellTabs.isEmpty || !managedTabs.isEmpty
    }

    var aggregateActivity: RuntimeActivity {
        RuntimeActivity.aggregate(
            root: rootActivity,
            liveDescendantIDs: descendants.map(\.id),
            descendantActivity: descendantActivity
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

    func resolveIDEWorkingDirectory(_ directory: String) {
        guard ideWorkingDirectory == nil, !directory.isEmpty else {
            return
        }
        ideWorkingDirectory = directory
        ideFresh.shutdown()
        ideLazygit.shutdown()
        ideFresh = makeIDESession(
            suffix: "fresh",
            command: "fresh .",
            workingDirectory: directory
        )
        ideLazygit = makeIDESession(
            suffix: "lazygit",
            command: "lazygit",
            workingDirectory: directory
        )
        bindIDESession(ideFresh)
        bindIDESession(ideLazygit)
        if isIDETabSelected {
            focusSelectedTab()
        }
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
        descendantActivity[session.id] = .descendantSeed
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

    func createManagedTab(
        ownerSessionID: String,
        name: String,
        workingDirectory: String,
        controlSocket: String,
        controlToken: String,
        controlClientPath: String,
        bootstrapPath: String
    ) -> ManagedTerminalTab {
        let tabID = UUID().uuidString.lowercased()
        let capability = Self.randomCapability()
        let terminal = TerminalSession(
            launch: TerminalLaunchRequest(
                managedTabID: tabID,
                workingDirectory: workingDirectory,
                environment: [
                    "CONAN_CODE_CONTROL_SOCKET": controlSocket,
                    "CONAN_CODE_CONTROL_TOKEN": controlToken,
                    "CONAN_CODE_CONTROL_CLIENT": controlClientPath,
                    "CONAN_CODE_TAB_ID": tabID,
                    "CONAN_CODE_TAB_CAPABILITY": capability,
                ],
                bootstrapPath: bootstrapPath
            ),
            runtime: root.runtime,
            keepsSurfaceAfterProcessExit: true
        )
        let tab = ManagedTerminalTab(
            id: tabID,
            capability: capability,
            ownerSessionID: ownerSessionID,
            name: name,
            session: terminal
        )
        bindManagedSession(terminal, tabID: tabID)
        terminal.onCloseRequest = { [weak self] in
            self?.closeManagedTab(tabID: tabID)
        }
        managedTabs.append(tab)
        return tab
    }

    func closeSelectedShellTab() {
        if selectedManagedTabID != nil {
            closeManagedTab(tabID: selectedTabID)
        } else {
            closeShellTab(tabID: selectedTabID)
        }
    }

    func closeShellTab(tabID: String) {
        guard tabID != ConversationTabMetadata.mainID,
              tabID != ConversationTabMetadata.ideID,
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
        focusSelectedTab()
    }

    func closeManagedTab(tabID: String) {
        guard let index = managedTabs.firstIndex(where: {
            $0.id == tabID
        }) else {
            return
        }
        managedTabs[index].session.shutdown()
        managedTabs.remove(at: index)
        if selectedManagedTabID == tabID {
            selectedManagedTabID = nil
            focusSelectedTab()
        }
    }

    func selectTab(tabID: String) {
        if managedTabs.contains(where: { $0.id == tabID }) {
            if selectedManagedTabID != tabID {
                selectedManagedTabID = tabID
            }
            focusSelectedTab()
            return
        }
        guard tabMetadata.contains(tabID: tabID) else { return }
        if selectedManagedTabID != nil {
            selectedManagedTabID = nil
        }
        if selectedTabID != tabID {
            var updated = tabMetadata
            updated.select(tabID: tabID)
            tabMetadata = updated
            publishTabMetadata()
        }
        focusSelectedTab()
    }

    func renameTab(tabID: String, to name: String) {
        if let managed = managedTabs.first(where: { $0.id == tabID }) {
            managed.name = name
            objectWillChange.send()
            return
        }
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
        if targetTabID == ConversationTabMetadata.mainID
            || targetTabID == ConversationTabMetadata.ideID {
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
        let ids = tabs.map(\.id)
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
            } else if selectedID == ConversationTabMetadata.ideID {
                self.focusIDEPane()
            } else {
                if let managed = self.managedTabs.first(
                    where: { $0.id == selectedID }
                ) {
                    managed.session.focus()
                } else {
                    self.shellTabs.first {
                        $0.id == selectedID
                    }?.focus()
                }
            }
        }
    }

    func focusAttentionPaneIfMainSelected() {
        guard isMainTabSelected else { return }
        focusMainPane()
    }

    func shutdown() {
        ideFresh.shutdown()
        ideLazygit.shutdown()
        shellTabs.forEach { $0.shutdown() }
        shellTabs.removeAll()
        managedTabs.forEach { $0.session.shutdown() }
        managedTabs.removeAll()
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
                workingDirectory: shellBaseWorkingDirectory ?? "",
                remote: execution.remote
            ),
            runtime: root.runtime
        )
        bindShellSession(terminal, tabID: tab.id)
        terminal.onCloseRequest = { [weak self] in
            self?.closeShellTab(tabID: tab.id)
        }
        return terminal
    }

    private func makeIDESession(
        suffix: String,
        command: String,
        workingDirectory: String
    ) -> TerminalSession {
        TerminalSession(
            launch: TerminalLaunchRequest(
                commandID: "\(id).ide.\(suffix)",
                workingDirectory: workingDirectory,
                command: command,
                remote: execution.remote
            ),
            runtime: root.runtime
        )
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

    private func bindIDESession(_ session: TerminalSession) {
        bindTabActions(
            session,
            tabID: ConversationTabMetadata.ideID
        )
        session.onBecameFocused = { [weak self, weak session] in
            guard let self, let session else { return }
            self.lastFocusedIDEPaneID = session.id
            if self.selectedTabID != ConversationTabMetadata.ideID {
                self.selectTab(tabID: ConversationTabMetadata.ideID)
            }
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

    private func bindManagedSession(
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
            guard let self else { return }
            if self.managedTabs.contains(where: { $0.id == tabID }) {
                self.closeManagedTab(tabID: tabID)
            } else {
                self.closeShellTab(tabID: tabID)
            }
        }
        session.onTabNavigationRequest = { [weak self] request in
            self?.navigateTabs(request)
        }
        session.onMoveTabRequest = { [weak self] amount in
            guard let self,
                  self.tabMetadata.shellTabs.contains(where: {
                      $0.id == tabID
                  }) else {
                return
            }
            self.moveShellTab(tabID: tabID, by: amount)
        }
        session.onRenameTabRequest = { [weak self] name in
            guard let self else { return }
            guard tabID != ConversationTabMetadata.ideID else { return }
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

    private func focusIDEPane() {
        cancelPendingFocusRequests()
        if lastFocusedIDEPaneID == ideLazygit.id {
            ideLazygit.focus()
        } else {
            lastFocusedIDEPaneID = ideFresh.id
            ideFresh.focus()
        }
    }

    private func publishTabMetadata() {
        onTabMetadataChange?(tabMetadata)
    }

    private func cancelPendingFocusRequests() {
        root.cancelPendingFocus()
        descendants.forEach { $0.cancelPendingFocus() }
        ideFresh.cancelPendingFocus()
        ideLazygit.cancelPendingFocus()
        shellTabs.forEach { $0.cancelPendingFocus() }
        managedTabs.forEach { $0.session.cancelPendingFocus() }
    }

    private static func randomCapability() -> String {
        [
            UUID().uuidString.lowercased(),
            UUID().uuidString.lowercased(),
        ].joined()
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

    var localExecution: ConversationExecution {
        ConversationExecution(
            grokExecutable: grokExecutable,
            leaderSocket: leaderSocket
        )
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
        ideDirectorySource: ConversationShellDirectorySource? = nil,
        tabMetadata: ConversationTabMetadata = .initial,
        execution: ConversationExecution? = nil
    ) -> ConversationRuntime {
        if let existing = runtime(sessionID: sessionID) {
            selectedSessionID = sessionID
            return existing
        }

        let resolvedExecution = execution ?? localExecution
        let launch = TerminalLaunchRequest(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            grokExecutable: resolvedExecution.grokExecutable,
            leaderSocket: resolvedExecution.leaderSocket,
            mode: mode,
            additionalArguments: additionalArguments,
            remote: resolvedExecution.remote
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
        let ideWorkingDirectory: String?
        switch ideDirectorySource ?? shellDirectorySource {
        case .rootLaunchDirectory:
            ideWorkingDirectory = workingDirectory
        case .explicit(let directory):
            ideWorkingDirectory = directory
        case .unavailable:
            ideWorkingDirectory = nil
        }
        let runtime = ConversationRuntime(
            id: sessionID,
            root: rootSession,
            execution: resolvedExecution,
            ideWorkingDirectory: ideWorkingDirectory,
            shellBaseWorkingDirectory: shellBaseWorkingDirectory,
            tabMetadata: tabMetadata
        )
        runtime.onTabMetadataChange = { [weak self, weak runtime] tabs in
            guard let runtime else { return }
            self?.onTabMetadataChange?(runtime.id, tabs)
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
        let execution = rootRuntime.execution
        let launch = TerminalLaunchRequest(
            sessionID: pane.childSessionID,
            workingDirectory: pane.workingDirectory,
            grokExecutable: execution.grokExecutable,
            leaderSocket: execution.leaderSocket,
            mode: .resume,
            surfaceContext: .split,
            remote: execution.remote
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

    func resolveIDEWorkingDirectory(
        sessionID: String,
        directory: String
    ) {
        runtime(sessionID: sessionID)?
            .resolveIDEWorkingDirectory(directory)
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

    func archiveImmediately(sessionID: String) {
        guard let runtime = runtime(sessionID: sessionID) else { return }
        runtime.shutdown()
        runtimes.removeAll { $0.id == sessionID }
        if selectedSessionID == sessionID {
            selectedSessionID = runtimes.first?.id
        }
        onArchivedRuntimeUnload?(sessionID, selectedSessionID)
    }

    func createManagedTab(
        rootSessionID: String,
        ownerSessionID: String,
        name: String,
        workingDirectory: String,
        controlSocket: String,
        controlToken: String,
        controlClientPath: String,
        bootstrapPath: String
    ) throws -> ManagedTerminalTab {
        guard let runtime = runtime(sessionID: rootSessionID) else {
            throw TerminalControlError.sessionUnavailable
        }
        return runtime.createManagedTab(
            ownerSessionID: ownerSessionID,
            name: name,
            workingDirectory: workingDirectory,
            controlSocket: controlSocket,
            controlToken: controlToken,
            controlClientPath: controlClientPath,
            bootstrapPath: bootstrapPath
        )
    }

    func managedTab(
        tabID: String,
        capability: String
    ) throws -> ManagedTerminalTab {
        for runtime in runtimes {
            if let tab = runtime.managedTabs.first(where: {
                $0.id == tabID
            }) {
                guard tab.capability == capability else {
                    throw TerminalControlError.forbidden
                }
                return tab
            }
        }
        throw TerminalControlError.tabGone
    }

    func closeManagedTab(
        tabID: String,
        capability: String
    ) throws {
        let tab = try managedTab(
            tabID: tabID,
            capability: capability
        )
        guard let runtime = runtimes.first(where: {
            $0.managedTabs.contains(where: { $0 === tab })
        }) else {
            throw TerminalControlError.tabGone
        }
        runtime.closeManagedTab(tabID: tabID)
    }

    func shutdown() {
        runtimes.forEach { $0.shutdown() }
        runtimes.removeAll()
        ghosttyRuntime.shutdown()
    }

}
