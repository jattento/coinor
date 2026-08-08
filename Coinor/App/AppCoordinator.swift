import AppKit
import Foundation

private struct ProjectLocationSnapshot: Sendable {
    let projectIDBySessionID: [String: String]
    let mainCheckoutByProjectID: [String: String]
}

private struct DetachedRuntimeState {
    let controlClient: GrokControlClient?
    let leaderSocket: GrokLeaderSocket?
}

struct ArchiveConfirmation: Identifiable, Equatable {
    enum Target: Equatable {
        case conversation(sessionID: String)
        case project(projectID: String)
    }

    let id = UUID()
    let target: Target
    let title: String
    let message: String
}

private struct TerminalControlConfiguration {
    let socket: TerminalControlSocket
    let token: String
    let clientPath: String
    let bootstrapPath: String
}

@MainActor
final class AppCoordinator: ObservableObject {
    private static let supportedProjectIconNames =
        ProjectIconChoice.supportedSystemNames.union([
            "app",
            "cloud",
            "cylinder",
            "server.rack",
            "wrench.and.screwdriver",
        ])
    private static let supportedProjectIconColorNames = Set(
        ProjectIconColorChoice.allCases.compactMap(\.persistedName)
    )

    enum Status: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var catalog: SessionCatalog = .empty
    @Published private(set) var metadata: MetadataDocument = .empty
    @Published private(set) var persistedSessions: [GrokPersistedSession] = []
    @Published private(set) var roster: [String: GrokRosterEntry] = [:]
    @Published private(set) var warningMessage: String?
    @Published var selectedSessionID: String?
    @Published var showsArchivedItems = false
    @Published var archiveConfirmation: ArchiveConfirmation?

    private(set) var runtimeManager: ConversationRuntimeManager?

    private var controlClient: GrokControlClient?
    private var terminalControlServer: TerminalControlServer?
    private var terminalControlConfiguration:
        TerminalControlConfiguration?
    private var metadataStore: MetadataStore?
    private var hookCoordinator: HookCoordinator?
    private var applicationInstanceLock: ApplicationInstanceLock?
    private var controlEventsTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var lifecycleCatchupTasks: [String: Task<Void, Never>] = [:]
    private var lifecycleReconciliationTasks: [String: Task<Void, Never>] = [:]
    private var pendingMaterializationTasks: [String: Task<Void, Never>] = [:]
    private var pendingLifecycleCatchup: Set<String> = []
    private var completedLifecycleCatchup: Set<String> = []
    private var pendingSessions: [String: SessionSummary] = [:]
    private var projectIDBySessionID: [String: String] = [:]
    private var mainCheckoutByProjectID: [String: String] = [:]
    @Published private var pendingAttentionSessionIDs: Set<String> = []
    private var lastAggregateActivity: [String: RuntimeActivity] = [:]
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
    private var activeLeaderSocket: GrokLeaderSocket?
    private var visibleConversationNavigationIDs: [String] = []
    private var reorderGeneration = 0
    private var lifecycleGeneration = 0
    private var started = false
    private let notifications = AttentionNotificationService()
    private let isApplicationActive: () -> Bool = { NSApp.isActive }
    private var activationObserver: (any NSObjectProtocol)?
    private let leaderProcessManager = GrokLeaderProcessManager()
    private let terminalControlAuthorizer =
        TerminalControlInvocationAuthorizer()

    func start() async {
        guard !started else { return }
        started = true
        observeApplicationActivation()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .starting

        do {
            let fileManager = FileManager.default
            let supportDirectory = try CoinorRuntimeEnvironment
                .applicationSupportDirectory(fileManager: fileManager)
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: NSNumber(value: 0o700),
                ]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: supportDirectory.path
            )
            if applicationInstanceLock == nil {
                applicationInstanceLock = try ApplicationInstanceLock(
                    directoryURL: supportDirectory
                )
            }

            let store = try MetadataStore(directoryURL: supportDirectory)
            metadataStore = store
            metadata = await store.currentDocument
            mainCheckoutByProjectID = metadata.projects.compactMapValues {
                $0.checkoutPath
            }

            try GrokSkillInstaller().install()
            guard let clientURL = Bundle.main.url(
                forResource: "coinorctl",
                withExtension: nil
            ), fileManager.isExecutableFile(atPath: clientURL.path) else {
                throw TerminalControlError.internalFailure(
                    "the bundled coinorctl executable is unavailable"
                )
            }
            guard let bootstrapURL = Bundle.main.url(
                forResource: "managed-terminal-bootstrap",
                withExtension: "zsh"
            ) else {
                throw TerminalControlError.internalFailure(
                    "the managed terminal bootstrap is unavailable"
                )
            }
            let terminalControlSocket =
                try TerminalControlSocket.coinorDefault(
                    supportDirectory: supportDirectory
                )
            let terminalControlToken = Self.randomControlToken()
            let terminalControlConfiguration =
                TerminalControlConfiguration(
                    socket: terminalControlSocket,
                    token: terminalControlToken,
                    clientPath: clientURL.path,
                    bootstrapPath: bootstrapURL.path
                )
            self.terminalControlConfiguration =
                terminalControlConfiguration

            let executable = try GrokExecutable.resolve()
            let leaderSocket = try GrokLeaderSocket.coinorDefault(
                supportDirectory: supportDirectory
            )
            _ = try await leaderProcessManager.stop(
                leaderSocket: leaderSocket
            )
            var leaderEnvironment = ProcessInfo.processInfo.environment
            leaderEnvironment["CONAN_CODE_CONTROL_SOCKET"] =
                terminalControlSocket.path
            leaderEnvironment["CONAN_CODE_CONTROL_TOKEN"] =
                terminalControlToken
            leaderEnvironment["CONAN_CODE_CONTROL_CLIENT"] =
                clientURL.path
            let launch = GrokControlLaunch(
                executable: executable,
                leaderSocket: leaderSocket,
                environment: leaderEnvironment
            )
            let control = GrokControlClient(launch: launch)
            activeLeaderSocket = leaderSocket
            controlClient = control
            _ = try await control.connect()

            let ghostty = try GhosttyRuntime()
            if let diagnostic = ghostty.configurationDiagnostics.first {
                warningMessage =
                    "Ghostty configuration warning: \(diagnostic)"
            }
            let runtimes = ConversationRuntimeManager(
                ghosttyRuntime: ghostty,
                grokExecutable: executable.path,
                leaderSocket: leaderSocket.path
            )
            runtimeManager = runtimes
            runtimes.onArchivedRuntimeUnload = { [weak self] sessionID, next in
                self?.archivedRuntimeUnloaded(
                    sessionID: sessionID,
                    nextSelectedSessionID: next
                )
            }
            runtimes.onTabMetadataChange = {
                [weak self] sessionID, tabs in
                self?.terminalTabsDidChange(
                    sessionID: sessionID,
                    tabs: tabs
                )
            }

            let hook = HookCoordinator(runtimes: runtimes)
            hookCoordinator = hook
            runtimes.onRootProcessExit = { [weak self] sessionID in
                self?.rootProcessExited(sessionID: sessionID)
            }

            let terminalControlServer = TerminalControlServer(
                socket: terminalControlSocket
            ) { [weak self] request in
                guard let self else {
                    return .failure(
                        .internalFailure("Conan Code is shutting down")
                    )
                }
                return await self.handleTerminalControl(request)
            }
            try terminalControlServer.start()
            self.terminalControlServer = terminalControlServer

            listenForControlEvents(control, generation: generation)
            try await refresh(
                using: control,
                generation: generation
            )
            try Task.checkCancellation()
            guard isCurrent(control, generation: generation),
                  status == .starting else {
                throw CancellationError()
            }
            status = .ready
            startCatalogRefreshLoop(
                control: control,
                generation: generation
            )

            if let lastVisible = metadata.lastVisibleSessionID,
               isConversationVisible(lastVisible) {
                selectConversation(lastVisible)
            }
        } catch is CancellationError {
            guard generation == lifecycleGeneration else { return }
            let detached = detachRuntimeState()
            await stop(detached)
            status = .failed("Conan Code startup was cancelled.")
        } catch {
            guard generation == lifecycleGeneration else { return }
            let message = error.localizedDescription
            let detached = detachRuntimeState()
            await stop(detached)
            status = .failed(message)
        }
    }

    func refresh() async throws {
        guard let controlClient else {
            throw GrokControlError.notConnected
        }
        try await refresh(
            using: controlClient,
            generation: lifecycleGeneration
        )
    }

    private func refresh(
        using control: GrokControlClient,
        generation: Int
    ) async throws {
        try Task.checkCancellation()
        async let persistedSessionsRequest =
            control.listPersistedSessions()
        async let rosterRequest = control.listRoster()

        let (allSessions, rosterEntries) = try await (
            persistedSessionsRequest,
            rosterRequest
        )
        try Task.checkCancellation()
        let sessions = allSessions.filter { !$0.isSubagent }
        let locations = await Task.detached {
            Self.resolveProjectLocations(for: sessions)
        }.value
        try Task.checkCancellation()
        guard isCurrent(control, generation: generation) else {
            throw CancellationError()
        }

        let persistedIDs = Set(sessions.map(\.id.rawValue))
        let refreshedPendingSessions = pendingSessions.filter {
            !persistedIDs.contains($0.key)
        }
        var refreshedMainCheckouts = mainCheckoutByProjectID
        refreshedMainCheckouts.merge(
            locations.mainCheckoutByProjectID,
            uniquingKeysWith: { _, refreshed in refreshed }
        )
        let refreshedRoster = Dictionary(
            uniqueKeysWithValues: rosterEntries.map {
                ($0.id.rawValue, $0)
            }
        )

        persistedSessions = sessions
        for session in sessions {
            if let directory = session.cwd {
                runtimeManager?.resolveShellBaseWorkingDirectory(
                    sessionID: session.id.rawValue,
                    directory: directory
                )
            }
            if let directory = session.gitRootDirectory ?? session.cwd {
                runtimeManager?.resolveIDEWorkingDirectory(
                    sessionID: session.id.rawValue,
                    directory: directory
                )
            }
        }
        pendingSessions = refreshedPendingSessions
        projectIDBySessionID = locations.projectIDBySessionID
        mainCheckoutByProjectID = refreshedMainCheckouts
        roster = refreshedRoster
        rebuildCatalog()
        reconcileRuntimeActivity()
    }

    func selectConversation(_ sessionID: String) {
        guard let runtimeManager else {
            return
        }
        if runtimeManager.runtime(sessionID: sessionID) != nil {
            runtimeManager.select(sessionID: sessionID)
            selectedSessionID = sessionID
            acknowledgeAttention(sessionID)
            schedulePersistence { coordinator in
                await coordinator.persist {
                    $0.setLastVisibleSession(sessionID)
                }
            }
            return
        }
        guard let session = session(sessionID) else { return }
        let workingDirectory = session.cwd
            ?? session.sourceWorkspaceDirectory
            ?? session.gitRootDirectory
            ?? NSHomeDirectory()
        _ = runtimeManager.activateRoot(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            mode: .resume,
            shellDirectorySource: session.cwd.map {
                .explicit($0)
            } ?? .unavailable,
            ideDirectorySource: (
                session.gitRootDirectory ?? session.cwd
            ).map {
                ConversationShellDirectorySource.explicit($0)
            } ?? .unavailable,
            tabMetadata: metadata.conversationTabs(sessionID)
        )
        hookCoordinator?.activateRoot(sessionID: sessionID)
        runtimeManager.select(sessionID: sessionID)
        selectedSessionID = sessionID
        acknowledgeAttention(sessionID)
        reconcileRuntimeActivity()
        requestLifecycleCatchup(for: sessionID)

        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setLastVisibleSession(sessionID)
            }
        }
    }

    func setVisibleConversationNavigationIDs(_ conversationIDs: [String]) {
        visibleConversationNavigationIDs = conversationIDs
    }

    @discardableResult
    func navigateConversation(
        _ direction: SidebarConversationNavigation.Direction
    ) -> Bool {
        guard !visibleConversationNavigationIDs.isEmpty else { return false }
        if let target = SidebarConversationNavigation.target(
            in: visibleConversationNavigationIDs,
            selectedConversationID: selectedSessionID,
            direction: direction
        ) {
            selectConversation(target)
        }
        return true
    }

    func createConversation(in projectID: String) {
        createConversation(
            in: projectID,
            workingDirectory: mainCheckout(for: projectID),
            additionalArguments: []
        )
    }

    private func createConversation(
        in projectID: String,
        workingDirectory: String,
        additionalArguments: [String]
    ) {
        guard let runtimeManager else { return }
        let sessionID = UUID().uuidString.lowercased()
        let summary = SessionSummary(
            id: sessionID,
            projectID: projectID,
            title: "New Conversation",
            lastActivityAt: Date()
        )
        pendingSessions[sessionID] = summary
        rebuildCatalog()

        _ = runtimeManager.activateRoot(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            mode: .newSession,
            additionalArguments: additionalArguments,
            shellDirectorySource: additionalArguments.contains {
                $0.hasPrefix("--worktree=")
            } ? .unavailable : .rootLaunchDirectory,
            tabMetadata: metadata.conversationTabs(sessionID)
        )
        hookCoordinator?.activateRoot(sessionID: sessionID)
        selectedSessionID = sessionID
        reconcileRuntimeActivity()
        requestLifecycleCatchup(for: sessionID)
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setLastVisibleSession(sessionID)
            }
        }
    }

    func addProject(url: URL) {
        let generation = lifecycleGeneration
        Task { [weak self] in
            do {
                let resolution = try await Task.detached {
                    try GitProjectResolver().resolve(checkout: url)
                }.value
                guard let self,
                      generation == self.lifecycleGeneration else {
                    return
                }
                let projectID = resolution.identity.rawValue
                self.mainCheckoutByProjectID[projectID] =
                    resolution.mainCheckout.path
                self.schedulePersistence { coordinator in
                    await coordinator.persist {
                        $0.registerProject(
                            projectID,
                            checkoutPath: resolution.mainCheckout.path
                        )
                    }
                }
            } catch {
                guard let self,
                      generation == self.lifecycleGeneration else {
                    return
                }
                self.warningMessage = error.localizedDescription
            }
        }
    }

    func setProjectExpanded(_ projectID: String, expanded: Bool) {
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setProjectExpanded(projectID, expanded: expanded)
            }
        }
    }

    func reorderProjects(to projectIDs: [String]) {
        let visibleProjectIDs = catalog.projects.map(\.projectID)
        guard projectIDs.count == visibleProjectIDs.count,
              Set(projectIDs) == Set(visibleProjectIDs) else {
            return
        }

        let rowsByID = Dictionary(
            uniqueKeysWithValues: catalog.projects.map {
                ($0.projectID, $0)
            }
        )
        catalog = SessionCatalog(
            pinned: catalog.pinned,
            projects: projectIDs.compactMap { rowsByID[$0] }
        )

        reorderGeneration += 1
        let generation = reorderGeneration
        schedulePersistence { coordinator in
            let allKnownProjectIDs = coordinator.allKnownProjectIDs
            _ = await coordinator.persist(
                {
                    $0.reorderVisibleProjects(
                        to: projectIDs,
                        allKnownProjectIDs: allKnownProjectIDs
                    )
                },
                rebuildCatalog: false
            )
            if coordinator.reorderGeneration == generation {
                coordinator.rebuildCatalog()
            }
        }
    }

    func reorderPinnedConversations(to sessionIDs: [String]) {
        let visibleSessionIDs = catalog.pinned.map(\.id)
        guard sessionIDs.count == visibleSessionIDs.count,
              Set(sessionIDs) == Set(visibleSessionIDs) else {
            return
        }

        let rowsByID = Dictionary(
            uniqueKeysWithValues: catalog.pinned.map {
                ($0.id, $0)
            }
        )
        catalog = SessionCatalog(
            pinned: sessionIDs.compactMap { rowsByID[$0] },
            projects: catalog.projects
        )

        reorderGeneration += 1
        let generation = reorderGeneration
        schedulePersistence { coordinator in
            _ = await coordinator.persist(
                {
                    $0.reorderVisiblePinnedSessions(to: sessionIDs)
                },
                rebuildCatalog: false
            )
            if coordinator.reorderGeneration == generation {
                coordinator.rebuildCatalog()
            }
        }
    }

    func reorderConversations(
        in projectID: String,
        to sessionIDs: [String]
    ) {
        guard let projectIndex = catalog.projects.firstIndex(
            where: { $0.projectID == projectID }
        ) else {
            return
        }
        let project = catalog.projects[projectIndex]
        let visibleSessionIDs = project.conversations.map(\.id)
        guard sessionIDs.count == visibleSessionIDs.count,
              Set(sessionIDs) == Set(visibleSessionIDs) else {
            return
        }

        let rowsByID = Dictionary(
            uniqueKeysWithValues: project.conversations.map {
                ($0.id, $0)
            }
        )
        var projects = catalog.projects
        projects[projectIndex] = ProjectRow(
            projectID: project.projectID,
            conversations: sessionIDs.compactMap { rowsByID[$0] },
            isManuallyRegistered: project.isManuallyRegistered,
            isExpanded: project.isExpanded
        )
        catalog = SessionCatalog(
            pinned: catalog.pinned,
            projects: projects
        )

        reorderGeneration += 1
        let generation = reorderGeneration
        schedulePersistence { coordinator in
            let allKnownSessionIDs = coordinator.summaries
                .filter { $0.projectID == projectID }
                .map(\.id)
            _ = await coordinator.persist(
                {
                    $0.reorderVisibleConversations(
                        in: projectID,
                        to: sessionIDs,
                        allKnownSessionIDs: allKnownSessionIDs
                    )
                },
                rebuildCatalog: false
            )
            if coordinator.reorderGeneration == generation {
                coordinator.rebuildCatalog()
            }
        }
    }

    func createWorktreeConversation(
        in projectID: String,
        name: String
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            warningMessage = "A worktree name is required."
            return
        }
        let checkout = URL(
            fileURLWithPath: mainCheckout(for: projectID),
            isDirectory: true
        )
        Task {
            do {
                let result = try await Task.detached {
                    try WorktreeService().prepareCreation(
                        named: trimmed,
                        from: checkout
                    )
                }.value
                mainCheckoutByProjectID[projectID] =
                    result.plan.project.mainCheckout.path
                warningMessage = result.warning
                createConversation(
                    in: projectID,
                    workingDirectory: result.plan.workingDirectory.path,
                    additionalArguments: result.plan.grokArguments
                )
            } catch {
                warningMessage = error.localizedDescription
            }
        }
    }

    func pin(_ sessionID: String) {
        schedulePersistence { coordinator in
            await coordinator.persist { $0.pin(sessionID) }
        }
    }

    func unpin(_ sessionID: String) {
        schedulePersistence { coordinator in
            await coordinator.persist { $0.unpin(sessionID) }
        }
    }

    func archiveConversation(_ sessionID: String) {
        if runtimeManager?.runtime(sessionID: sessionID) != nil {
            let title = summaries.first {
                $0.id == sessionID
            }?.title ?? "this conversation"
            archiveConfirmation = ArchiveConfirmation(
                target: .conversation(sessionID: sessionID),
                title: "Archive Conversation?",
                message:
                    "Archiving \(title) will immediately stop Grok, "
                    + "all subagents, IDE tools, shell tabs, and managed "
                    + "services for this conversation."
            )
            return
        }
        performArchiveConversation(sessionID)
    }

    func confirmArchive() {
        guard let confirmation = archiveConfirmation else { return }
        archiveConfirmation = nil
        switch confirmation.target {
        case .conversation(let sessionID):
            performArchiveConversation(sessionID)
        case .project(let projectID):
            performArchiveProject(projectID)
        }
    }

    func cancelArchive() {
        archiveConfirmation = nil
    }

    private func performArchiveConversation(_ sessionID: String) {
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist { document in
                document.unpin(sessionID)
                document.setSessionArchived(sessionID, archived: true)
            }
            if persisted {
                coordinator.runtimeManager?.archiveImmediately(
                    sessionID: sessionID
                )
            }
        }
    }

    func unarchiveConversation(_ sessionID: String) {
        schedulePersistence { coordinator in
            _ = await coordinator.persist {
                $0.setSessionArchived(sessionID, archived: false)
            }
        }
    }

    func archiveProject(_ projectID: String) {
        let hasLoadedRuntime = summaries
            .filter { $0.projectID == projectID }
            .contains {
                runtimeManager?.runtime(sessionID: $0.id) != nil
            }
        if hasLoadedRuntime {
            archiveConfirmation = ArchiveConfirmation(
                target: .project(projectID: projectID),
                title: "Archive Project?",
                message:
                    "Archiving \(projectDisplayName(projectID)) will "
                    + "immediately stop Grok, all subagents, IDE tools, "
                    + "shell tabs, and managed services for every active "
                    + "conversation in this project."
            )
            return
        }
        performArchiveProject(projectID)
    }

    private func performArchiveProject(_ projectID: String) {
        let sessionIDs = summaries
            .filter { $0.projectID == projectID }
            .map(\.id)
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist {
                $0.setProjectArchived(projectID, archived: true)
            }
            if persisted {
                sessionIDs.forEach {
                    coordinator.runtimeManager?.archiveImmediately(
                        sessionID: $0
                    )
                }
            }
        }
    }

    func unarchiveProject(_ projectID: String) {
        schedulePersistence { coordinator in
            _ = await coordinator.persist {
                $0.setProjectArchived(projectID, archived: false)
            }
        }
    }

    func renameConversation(_ sessionID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let controlClient else { return }
        let directory = session(sessionID)?.cwd
        Task {
            do {
                try await controlClient.rename(
                    GrokSessionID(sessionID),
                    to: trimmed,
                    inDirectory: directory
                )
                try await refresh()
            } catch {
                warningMessage = error.localizedDescription
            }
        }
    }

    func dismissWarning() {
        warningMessage = nil
    }

    @discardableResult
    func createTerminalTab() -> Bool {
        guard runtimeManager?.selectedRuntime != nil else { return false }
        runtimeManager?.createShellTab()
        return true
    }

    @discardableResult
    func closeSelectedTerminalTab() -> Bool {
        guard runtimeManager?.selectedRuntime != nil else { return false }
        runtimeManager?.closeSelectedShellTab()
        return true
    }

    @discardableResult
    func selectTerminalTab(number: Int) -> Bool {
        guard runtimeManager?.selectedRuntime != nil else { return false }
        if number == 9 {
            runtimeManager?.selectLastTab()
        } else {
            runtimeManager?.selectTab(at: number)
        }
        return true
    }

    func restart() async {
        await drainPersistenceTasks()
        let detached = detachRuntimeState()
        await stop(detached)
        started = false
        status = .starting
        await start()
    }

    func shutdown() async {
        await drainPersistenceTasks()
        let detached = detachRuntimeState()
        await stop(detached)
        applicationInstanceLock = nil
        started = false
    }

    private func detachRuntimeState() -> DetachedRuntimeState {
        lifecycleGeneration += 1
        controlEventsTask?.cancel()
        controlEventsTask = nil
        catalogRefreshTask?.cancel()
        catalogRefreshTask = nil
        lifecycleCatchupTasks.values.forEach { $0.cancel() }
        lifecycleCatchupTasks.removeAll()
        lifecycleReconciliationTasks.values.forEach { $0.cancel() }
        lifecycleReconciliationTasks.removeAll()
        pendingMaterializationTasks.values.forEach { $0.cancel() }
        pendingMaterializationTasks.removeAll()
        pendingLifecycleCatchup.removeAll()
        completedLifecycleCatchup.removeAll()
        terminalControlAuthorizer.reset()
        terminalControlServer?.stop()
        terminalControlServer = nil
        terminalControlConfiguration = nil
        archiveConfirmation = nil
        hookCoordinator = nil
        runtimeManager?.shutdown()
        runtimeManager = nil
        let control = controlClient
        controlClient = nil
        let leaderSocket = activeLeaderSocket
        activeLeaderSocket = nil
        metadataStore = nil
        roster.removeAll()
        pendingAttentionSessionIDs.removeAll()
        lastAggregateActivity.removeAll()
        return DetachedRuntimeState(
            controlClient: control,
            leaderSocket: leaderSocket
        )
    }

    private func stop(_ detached: DetachedRuntimeState) async {
        await detached.controlClient?.shutdown()
        guard let leaderSocket = detached.leaderSocket else { return }
        do {
            _ = try await leaderProcessManager.stop(
                leaderSocket: leaderSocket
            )
        } catch {
            warningMessage =
                "Conan Code could not stop its private Grok leader: "
                + error.localizedDescription
        }
    }

    var archivedConversations: [SessionSummary] {
        summaries.filter { metadata.isSessionArchived($0.id) }
    }

    var archivedProjectIDs: [String] {
        metadata.projects.compactMap { id, value in
            value.archived ? id : nil
        }.sorted()
    }

    func projectDisplayName(_ projectID: String) -> String {
        if let displayName = metadata.projectDisplayName(projectID) {
            return displayName
        }
        return URL(
            fileURLWithPath: mainCheckout(for: projectID),
            isDirectory: true
        ).lastPathComponent
    }

    func projectIconName(_ projectID: String) -> String {
        guard let iconName = metadata.projectIconName(projectID),
              Self.supportedProjectIconNames.contains(iconName) else {
            return "folder"
        }
        return iconName
    }

    func projectIconColorName(_ projectID: String) -> String? {
        guard let colorName = metadata.projectIconColorName(projectID),
              Self.supportedProjectIconColorNames.contains(colorName) else {
            return nil
        }
        return colorName
    }

    func projectHasCustomDisplayName(_ projectID: String) -> Bool {
        metadata.projectDisplayName(projectID) != nil
    }

    func renameProject(_ projectID: String, displayName: String) {
        let trimmed = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return }
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setProjectDisplayName(
                    projectID,
                    displayName: trimmed
                )
            }
        }
    }

    func setProjectIcon(_ projectID: String, iconName: String?) {
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setProjectIconName(
                    projectID,
                    iconName: iconName
                )
            }
        }
    }

    func setProjectAppearance(
        _ projectID: String,
        iconName: String?,
        colorName: String?
    ) {
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setProjectIconName(
                    projectID,
                    iconName: iconName
                )
                $0.setProjectIconColorName(
                    projectID,
                    iconColorName: colorName
                )
            }
        }
    }

    func useFolderName(for projectID: String) {
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setProjectDisplayName(projectID, displayName: nil)
            }
        }
    }

    func projectActivity(_ project: ProjectRow) -> RuntimeActivity {
        RuntimeActivity.aggregate(
            summaries.lazy
                .filter {
                    $0.projectID == project.projectID
                        && !self.metadata.isSessionArchived($0.id)
                }
                .map { self.activity(for: $0.id) }
        )
    }

    func activity(for sessionID: String) -> RuntimeActivity {
        let activity = rawActivity(for: sessionID)
        if activity == .failed { return activity }
        if pendingAttentionSessionIDs.contains(sessionID) { return .needsInput }
        // A raw needs_input only reaches the sidebar through the pending set,
        // so opening the conversation keeps the indicator down until the next
        // time the conversation asks for the user.
        return activity == .needsInput ? .idle : activity
    }

    private func rawActivity(for sessionID: String) -> RuntimeActivity {
        if let runtime = runtimeManager?.runtime(sessionID: sessionID) {
            return runtime.aggregateActivity
        }
        return authoritativeActivity(for: sessionID) ?? .idle
    }

    private func acknowledgeAttention(_ sessionID: String) {
        pendingAttentionSessionIDs.remove(sessionID)
    }

    func searchConversations(_ query: String) -> [ConversationRow] {
        ConversationSearch.results(
            query: query,
            sessions: summaries,
            metadata: metadata
        )
    }

    private var summaries: [SessionSummary] {
        let persisted = persistedSessions.map { session in
            let dates = [
                session.lastActiveAt,
                session.updatedAt,
                session.createdAt,
                roster[session.id.rawValue]?.lastChange,
            ].compactMap { $0 }
            return SessionSummary(
                id: session.id.rawValue,
                projectID: projectIDBySessionID[session.id.rawValue]
                    ?? fallbackProjectID(for: session),
                title: session.title ?? "Untitled Conversation",
                lastActivityAt: dates.max()
            )
        }
        let persistedIDs = Set(persisted.map(\.id))
        return persisted + pendingSessions.values.filter {
            !persistedIDs.contains($0.id)
        }
    }

    private func session(_ sessionID: String) -> GrokPersistedSession? {
        persistedSessions.first { $0.id.rawValue == sessionID }
    }

    private func fallbackProjectID(
        for session: GrokPersistedSession
    ) -> String {
        let value = session.projectDirectory ?? session.cwd ?? NSHomeDirectory()
        return URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func mainCheckout(for projectID: String) -> String {
        mainCheckoutByProjectID[projectID]
            ?? metadata.projectCheckoutPath(projectID)
            ?? {
            let projectURL = URL(
                fileURLWithPath: projectID,
                isDirectory: true
            )
            if projectURL.lastPathComponent == ".git" {
                return projectURL.deletingLastPathComponent().path
            }
            return projectURL.path
            }()
    }

    private nonisolated static func resolveProjectLocations(
        for sessions: [GrokPersistedSession]
    ) -> ProjectLocationSnapshot {
        guard let resolver = try? GitProjectResolver() else {
            return ProjectLocationSnapshot(
                projectIDBySessionID: [:],
                mainCheckoutByProjectID: [:]
            )
        }

        var projectIDs: [String: String] = [:]
        var mainCheckouts: [String: String] = [:]
        for session in sessions {
            guard let resolution = try? resolver.resolve(
                projectFor: session
            ) else {
                continue
            }
            let projectID = resolution.identity.rawValue
            projectIDs[session.id.rawValue] = projectID
            mainCheckouts[projectID] = resolution.mainCheckout.path
        }
        return ProjectLocationSnapshot(
            projectIDBySessionID: projectIDs,
            mainCheckoutByProjectID: mainCheckouts
        )
    }

    private func rebuildCatalog() {
        catalog = SessionCatalog.build(
            sessions: summaries,
            metadata: metadata
        )
    }

    private var allKnownProjectIDs: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for projectID in summaries.map(\.projectID)
            + metadata.projects.keys.sorted() {
            if seen.insert(projectID).inserted {
                result.append(projectID)
            }
        }
        return result
    }

    private func schedulePersistence(
        _ operation: @escaping @MainActor (AppCoordinator) async -> Void
    ) {
        let id = UUID()
        let predecessor = persistenceTail
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await operation(self)
            self.persistenceTasks.removeValue(forKey: id)
        }
        persistenceTasks[id] = task
        persistenceTail = task
    }

    private func drainPersistenceTasks() async {
        while let task = persistenceTail {
            await task.value
            if persistenceTasks.isEmpty {
                persistenceTail = nil
            }
        }
    }

    @discardableResult
    private func persist(
        _ transform: @Sendable @escaping (inout MetadataDocument) -> Void,
        rebuildCatalog shouldRebuildCatalog: Bool = true
    ) async -> Bool {
        guard let metadataStore else { return false }
        do {
            metadata = try await metadataStore.update(transform)
            if shouldRebuildCatalog {
                rebuildCatalog()
            }
            return true
        } catch {
            warningMessage = error.localizedDescription
            return false
        }
    }

    private func terminalTabsDidChange(
        sessionID: String,
        tabs: ConversationTabMetadata
    ) {
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setConversationTabs(sessionID, tabs: tabs)
            }
        }
    }

    private func isCurrent(
        _ control: GrokControlClient,
        generation: Int
    ) -> Bool {
        lifecycleGeneration == generation && controlClient === control
    }

    private func listenForControlEvents(
        _ control: GrokControlClient,
        generation: Int
    ) {
        controlEventsTask = Task { [weak self] in
            let events = await control.events()
            for await event in events {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrent(
                          control,
                          generation: generation
                      ) else {
                    break
                }
                switch event {
                case .rosterChanged(let change):
                    for removed in change.removed {
                        self.roster.removeValue(forKey: removed.rawValue)
                    }
                    for entry in change.upserted {
                        self.roster[entry.id.rawValue] = entry
                        if let directory = entry.cwd {
                            self.runtimeManager?
                                .resolveShellBaseWorkingDirectory(
                                    sessionID: entry.id.rawValue,
                                    directory: directory
                                )
                            self.runtimeManager?
                                .resolveIDEWorkingDirectory(
                                    sessionID: entry.id.rawValue,
                                    directory: directory
                                )
                        }
                        self.materializePendingSessionIfNeeded(entry)
                        self.startLifecycleCatchupIfReady(entry)
                    }
                    self.reconcileRuntimeActivity()
                case .subagentLifecycle(let observation):
                    self.reconcileSubagentLifecycle(observation)
                case .terminated(let error):
                    await self.controlTerminated(
                        control,
                        generation: generation,
                        error: error
                    )
                    return
                case .notification(let method, let params):
                    if let invocation =
                        GrokTerminalToolInvocation.parseNotification(
                            method: method,
                            params: params
                        ) {
                        self.terminalControlAuthorizer.observe(invocation)
                    }
                    if method == GrokMethod.leaderReconnected {
                        self.restoreSubscriptionsAfterLeaderReconnect()
                    }
                }
            }
        }
    }

    private func controlTerminated(
        _ control: GrokControlClient,
        generation: Int,
        error: GrokControlError
    ) async {
        guard isCurrent(control, generation: generation) else { return }
        let message = error.localizedDescription
        let detached = detachRuntimeState()
        await stop(detached)
        status = .failed(message)
    }

    private func reconcileRuntimeActivity() {
        guard let runtimeManager else { return }
        for runtime in runtimeManager.runtimes {
            let paneIDs = [runtime.id] + runtime.descendants.map(\.id)
            for paneID in paneIDs {
                guard let activity = authoritativeActivity(
                    for: paneID
                ) else {
                    continue
                }
                runtimeManager.setActivity(
                    activity,
                    sessionID: paneID,
                    rootSessionID: runtime.id
                )
            }
            updateAttention(for: runtime)
        }
    }

    /// Raises the sidebar indicator when a conversation stops needing the CPU
    /// and starts needing the user.
    ///
    /// Grok reports `needs_input` only while it is blocked on a question, and
    /// reports a finished turn as plain `idle`, so waiting for `needs_input`
    /// alone would leave a completed run silent. The working-to-settled edge is
    /// therefore what raises attention, and a conversation the user is already
    /// watching raises nothing.
    private func updateAttention(for runtime: ConversationRuntime) {
        let sessionID = runtime.id
        let current = runtime.aggregateActivity
        let previous = lastAggregateActivity[sessionID]
        lastAggregateActivity[sessionID] = current

        switch ConversationAttention.transition(
            from: previous,
            to: current
        ) {
        case .unchanged:
            return
        case .settled:
            pendingAttentionSessionIDs.remove(sessionID)
            return
        case .raised:
            break
        }

        guard !isWatching(sessionID) else { return }
        guard pendingAttentionSessionIDs.insert(sessionID).inserted else {
            return
        }

        let title = summaries.first { $0.id == sessionID }?.title
            ?? "Grok Conversation"
        Task {
            await notifications.notifyIfNeeded(
                sessionID: sessionID,
                conversationTitle: title
            )
        }
    }

    /// Whether the user is looking at this conversation right now.
    private func isWatching(_ sessionID: String) -> Bool {
        selectedSessionID == sessionID && isApplicationActive()
    }

    /// Returning to Conan Code counts as reading whatever is on screen, so the
    /// open conversation lowers its indicator without a second click.
    private func observeApplicationActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let sessionID = self.selectedSessionID else {
                    return
                }
                self.acknowledgeAttention(sessionID)
            }
        }
    }

    private func authoritativeActivity(
        for sessionID: String
    ) -> RuntimeActivity? {
        roster[sessionID].map {
            RuntimeActivity(grokActivity: $0.activity)
        }
    }

    private func startCatalogRefreshLoop(
        control: GrokControlClient,
        generation: Int
    ) {
        guard catalogRefreshTask == nil else { return }
        catalogRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.refresh(
                        using: control,
                        generation: generation
                    )
                } catch is CancellationError {
                    return
                } catch {
                    await self.controlTerminated(
                        control,
                        generation: generation,
                        error: error as? GrokControlError
                            ?? .launchFailed(error.localizedDescription)
                    )
                    return
                }
            }
        }
    }

    private func requestLifecycleCatchup(for rootSessionID: String) {
        guard !completedLifecycleCatchup.contains(rootSessionID) else {
            return
        }
        pendingLifecycleCatchup.insert(rootSessionID)
        lifecycleCatchupTasks[rootSessionID]?.cancel()
        let generation = lifecycleGeneration
        lifecycleCatchupTasks[rootSessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self,
                  !Task.isCancelled,
                  let controlClient = self.controlClient else {
                return
            }
            do {
                let entries = try await controlClient.listRoster()
                guard self.isCurrent(
                    controlClient,
                    generation: generation
                ), let entry = entries.first(where: {
                    $0.id.rawValue == rootSessionID
                }), entry.isResident else {
                    return
                }
                self.roster[rootSessionID] = entry
                self.startLifecycleCatchupIfReady(entry)
            } catch {
                // A roster broadcast will retry this path when the terminal
                // finishes attaching. Startup remains usable in the meantime.
            }
        }
    }

    private func startLifecycleCatchupIfReady(_ entry: GrokRosterEntry) {
        let rootSessionID = entry.id.rawValue
        guard entry.isResident,
              pendingLifecycleCatchup.contains(rootSessionID),
              !completedLifecycleCatchup.contains(rootSessionID),
              runtimeManager?.runtime(sessionID: rootSessionID) != nil,
              let controlClient,
              let cwd = runtimeManager?.workingDirectory(
                  sessionID: rootSessionID,
                  rootSessionID: rootSessionID
              ) else {
            return
        }

        pendingLifecycleCatchup.remove(rootSessionID)
        lifecycleCatchupTasks[rootSessionID]?.cancel()
        let generation = lifecycleGeneration
        lifecycleCatchupTasks[rootSessionID] = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.restoreSubagentTree(
                    rootSessionID: rootSessionID,
                    rootWorkingDirectory: cwd,
                    controlClient: controlClient,
                    generation: generation
                )
                guard !Task.isCancelled,
                      self.isCurrent(
                          controlClient,
                          generation: generation
                      ),
                      self.runtimeManager?.runtime(
                          sessionID: rootSessionID
                      ) != nil else {
                    return
                }
                self.completedLifecycleCatchup.insert(rootSessionID)
                self.lifecycleCatchupTasks.removeValue(
                    forKey: rootSessionID
                )
                self.reconcileRuntimeActivity()
                self.ensureLifecycleReconciliation(
                    for: rootSessionID
                )
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrent(
                          controlClient,
                          generation: generation
                      ) else {
                    return
                }
                self.pendingLifecycleCatchup.insert(rootSessionID)
                self.lifecycleCatchupTasks.removeValue(
                    forKey: rootSessionID
                )
                self.warningMessage =
                    "Conan Code could not restore subagent panels: \(error.localizedDescription)"
            }
        }
    }

    private func restoreSubagentTree(
        rootSessionID: String,
        rootWorkingDirectory: String,
        controlClient: GrokControlClient,
        generation: Int
    ) async throws {
        struct ReplayTarget {
            let sessionID: String
            let parentSessionID: String?
            let workingDirectory: String
        }

        var queue = [
            ReplayTarget(
                sessionID: rootSessionID,
                parentSessionID: nil,
                workingDirectory: rootWorkingDirectory
            ),
        ]
        var queued: Set<String> = [rootSessionID]
        var visited: Set<String> = []

        while !queue.isEmpty {
            try Task.checkCancellation()
            guard isCurrent(controlClient, generation: generation) else {
                throw CancellationError()
            }
            let target = queue.removeFirst()
            guard visited.insert(target.sessionID).inserted,
                  runtimeManager?.runtime(
                      sessionID: rootSessionID
                  ) != nil else {
                continue
            }

            let observations = try await controlClient
                .listSubagentLifecycle(
                    sessionID: target.sessionID,
                    cwd: target.workingDirectory,
                    parentSessionID: target.parentSessionID
                )
            try Task.checkCancellation()
            guard isCurrent(controlClient, generation: generation) else {
                throw CancellationError()
            }
            for persistedObservation in observations {
                let targetIsActive = target.sessionID == rootSessionID
                    || hookCoordinator?.rootSessionID(
                        for: target.sessionID
                    ) == rootSessionID
                let observation = Self.normalizedReplayObservation(
                    persistedObservation,
                    targetSessionID: target.sessionID,
                    targetIsActive: targetIsActive,
                    rootSessionID: rootSessionID
                )
                if observation.kind != .finished,
                   queued.insert(observation.childSessionID).inserted {
                    queue.append(
                        ReplayTarget(
                            sessionID: observation.childSessionID,
                            parentSessionID: observation.parentSessionID,
                            workingDirectory: target.workingDirectory
                        )
                    )
                }
                reconcileSubagentLifecycle(
                    observation,
                    knownRootSessionID: rootSessionID,
                    schedulesReconciliation: false
                )
            }

            for pane in hookCoordinator?.activePanes(
                rootSessionID: rootSessionID
            ) ?? [] where queued.insert(pane.childSessionID).inserted {
                let workingDirectory = runtimeManager?.workingDirectory(
                    sessionID: pane.childSessionID,
                    rootSessionID: rootSessionID
                ) ?? pane.workingDirectory
                queue.append(
                    ReplayTarget(
                        sessionID: pane.childSessionID,
                        parentSessionID: pane.immediateParentSessionID,
                        workingDirectory: workingDirectory
                    )
                )
            }
        }
    }

    nonisolated static func normalizedReplayObservation(
        _ observation: GrokSubagentLifecycleObservation,
        targetSessionID: String,
        targetIsActive: Bool,
        rootSessionID: String
    ) -> GrokSubagentLifecycleObservation {
        guard targetSessionID != rootSessionID,
              !targetIsActive,
              observation.parentSessionID == targetSessionID else {
            return observation
        }
        return GrokSubagentLifecycleObservation(
            kind: observation.kind,
            childSessionID: observation.childSessionID,
            parentSessionID: rootSessionID,
            description: observation.description,
            subagentType: observation.subagentType,
            status: observation.status,
            timestamp: observation.timestamp
        )
    }

    private func ensureLifecycleReconciliation(
        for rootSessionID: String
    ) {
        guard lifecycleReconciliationTasks[rootSessionID] == nil,
              hookCoordinator?.activePanes(
                rootSessionID: rootSessionID
              ).isEmpty == false,
              let controlClient else {
            return
        }
        let generation = lifecycleGeneration
        lifecycleReconciliationTasks[rootSessionID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrent(
                          controlClient,
                          generation: generation
                      ),
                      self.runtimeManager?.runtime(
                          sessionID: rootSessionID
                      ) != nil,
                      self.hookCoordinator?.activePanes(
                          rootSessionID: rootSessionID
                      ).isEmpty == false,
                      let cwd = self.runtimeManager?.workingDirectory(
                          sessionID: rootSessionID,
                          rootSessionID: rootSessionID
                      ) else {
                    break
                }
                do {
                    try await self.restoreSubagentTree(
                        rootSessionID: rootSessionID,
                        rootWorkingDirectory: cwd,
                        controlClient: controlClient,
                        generation: generation
                    )
                } catch is CancellationError {
                    break
                } catch {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                guard self.isCurrent(
                    controlClient,
                    generation: generation
                ) else {
                    break
                }
                self.reconcileRuntimeActivity()
                try? await Task.sleep(for: .seconds(3))
            }
            guard let self,
                  generation == self.lifecycleGeneration else {
                return
            }
            self.lifecycleReconciliationTasks.removeValue(forKey: rootSessionID)
        }
    }

    private func restoreSubscriptionsAfterLeaderReconnect() {
        lifecycleCatchupTasks.values.forEach { $0.cancel() }
        lifecycleCatchupTasks.removeAll()
        lifecycleReconciliationTasks.values.forEach { $0.cancel() }
        lifecycleReconciliationTasks.removeAll()
        pendingLifecycleCatchup.removeAll()
        completedLifecycleCatchup.removeAll()
        for runtime in runtimeManager?.runtimes ?? [] {
            requestLifecycleCatchup(for: runtime.id)
        }
    }

    private func reconcileSubagentLifecycle(
        _ observation: GrokSubagentLifecycleObservation,
        knownRootSessionID: String? = nil,
        schedulesReconciliation: Bool = true
    ) {
        guard let runtimeManager, let hookCoordinator else { return }
        let rootSessionID = knownRootSessionID
            ?? hookCoordinator.rootSessionID(
                for: observation.childSessionID
            )
            ?? hookCoordinator.rootSessionID(
                for: observation.parentSessionID
            )
            ?? runtimeManager.rootSessionID(
                containing: observation.parentSessionID
            )
        guard let rootSessionID,
              runtimeManager.runtime(sessionID: rootSessionID) != nil else {
            return
        }
        let workingDirectory = runtimeManager.workingDirectory(
            sessionID: observation.parentSessionID,
            rootSessionID: rootSessionID
        ) ?? runtimeManager.workingDirectory(
            sessionID: rootSessionID,
            rootSessionID: rootSessionID
        ) ?? NSHomeDirectory()
        hookCoordinator.reconcile(
            observation,
            workingDirectory: workingDirectory
        )
        reconcileRuntimeActivity()
        if schedulesReconciliation {
            ensureLifecycleReconciliation(for: rootSessionID)
        }
    }

    private func rootProcessExited(sessionID: String) {
        lifecycleCatchupTasks.removeValue(forKey: sessionID)?.cancel()
        lifecycleReconciliationTasks.removeValue(
            forKey: sessionID
        )?.cancel()
        pendingMaterializationTasks.removeValue(forKey: sessionID)?.cancel()
        pendingLifecycleCatchup.remove(sessionID)
        completedLifecycleCatchup.remove(sessionID)
        hookCoordinator?.rootProcessExited(sessionID: sessionID)
        if session(sessionID) == nil,
           pendingSessions.removeValue(forKey: sessionID) != nil {
            rebuildCatalog()
        }
        if selectedSessionID == sessionID {
            selectedSessionID = runtimeManager?.selectedSessionID
            let nextSelectedSessionID = selectedSessionID
            schedulePersistence { coordinator in
                await coordinator.persist {
                    $0.setLastVisibleSession(nextSelectedSessionID)
                }
            }
        }
    }

    private func materializePendingSessionIfNeeded(
        _ entry: GrokRosterEntry
    ) {
        let sessionID = entry.id.rawValue
        guard pendingSessions[sessionID] != nil,
              pendingMaterializationTasks[sessionID] == nil,
              let controlClient else {
            return
        }
        let generation = lifecycleGeneration
        pendingMaterializationTasks[sessionID] = Task { [weak self] in
            let delays: [Duration] = [
                .zero,
                .milliseconds(100),
                .milliseconds(250),
                .milliseconds(500),
                .seconds(1),
            ]
            for delay in delays {
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                guard let self, !Task.isCancelled else { return }
                do {
                    let sessions = try await controlClient
                        .listPersistedSessions(inDirectory: entry.cwd)
                    guard let persisted = sessions.first(where: {
                        $0.id.rawValue == sessionID
                    }) else {
                        continue
                    }
                    let locations = await Task.detached {
                        Self.resolveProjectLocations(for: [persisted])
                    }.value
                    guard !Task.isCancelled,
                          self.isCurrent(
                              controlClient,
                              generation: generation
                          ) else {
                        return
                    }
                    self.persistedSessions.removeAll {
                        $0.id.rawValue == sessionID
                    }
                    self.persistedSessions.append(persisted)
                    if let directory = persisted.cwd {
                        self.runtimeManager?
                            .resolveShellBaseWorkingDirectory(
                                sessionID: sessionID,
                                directory: directory
                            )
                    }
                    if let directory =
                        persisted.gitRootDirectory ?? persisted.cwd {
                        self.runtimeManager?
                            .resolveIDEWorkingDirectory(
                                sessionID: sessionID,
                                directory: directory
                            )
                    }
                    self.pendingSessions.removeValue(forKey: sessionID)
                    self.projectIDBySessionID.merge(
                        locations.projectIDBySessionID,
                        uniquingKeysWith: { _, refreshed in refreshed }
                    )
                    self.mainCheckoutByProjectID.merge(
                        locations.mainCheckoutByProjectID,
                        uniquingKeysWith: { _, refreshed in refreshed }
                    )
                    self.pendingMaterializationTasks.removeValue(
                        forKey: sessionID
                    )
                    self.rebuildCatalog()
                    return
                } catch {
                    continue
                }
            }
            guard let self,
                  generation == self.lifecycleGeneration else {
                return
            }
            self.pendingMaterializationTasks.removeValue(forKey: sessionID)
        }
    }

    private func handleTerminalControl(
        _ request: TerminalControlRequest
    ) async -> TerminalControlResponse {
        do {
            guard let configuration = terminalControlConfiguration,
                  request.token == configuration.token else {
                throw TerminalControlError.unauthorized
            }
            guard let runtimeManager else {
                throw TerminalControlError.sessionUnavailable
            }

            switch request.method {
            case "create":
                guard let requestID = request.requestID,
                      !requestID.isEmpty else {
                    throw TerminalControlError.invalidRequest(
                        "requestID is required"
                    )
                }
                let workingDirectory = request.cwd ?? NSHomeDirectory()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: workingDirectory,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw TerminalControlError.invalidDirectory(
                        workingDirectory
                    )
                }
                guard let ownerSessionID =
                    await terminalControlAuthorizer.consume(
                        requestID: requestID
                    ) else {
                    throw TerminalControlError.invocationNotObserved
                }
                guard let rootSessionID = terminalControlRootSessionID(
                    for: ownerSessionID
                ) else {
                    throw TerminalControlError.sessionUnavailable
                }
                let title = request.title?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                let tab = try runtimeManager.createManagedTab(
                    rootSessionID: rootSessionID,
                    ownerSessionID: ownerSessionID,
                    name: title?.isEmpty == false ? title! : "Service",
                    workingDirectory: URL(
                        fileURLWithPath: workingDirectory,
                        isDirectory: true
                    ).standardizedFileURL.path,
                    controlSocket: configuration.socket.path,
                    controlToken: configuration.token,
                    controlClientPath: configuration.clientPath,
                    bootstrapPath: configuration.bootstrapPath
                )
                return .success(
                    .object([
                        "tabID": .string(tab.id),
                        "capability": .string(tab.capability),
                        "state": .string(tab.state.wireValue),
                    ])
                )

            case "execute":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                guard let command = request.command else {
                    throw TerminalControlError.invalidRequest(
                        "command is required"
                    )
                }
                let commandID = try tab.execute(command)
                return .success(
                    .object([
                        "tabID": .string(tab.id),
                        "commandID": .string(commandID),
                        "state": .string(tab.state.wireValue),
                    ])
                )

            case "read":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                let result = tab.read(
                    cursor: request.cursor,
                    maximumBytes: request.maxBytes
                )
                return .success(
                    .object([
                        "text": .string(result.text),
                        "cursor": .string(result.cursor),
                        "reset": .bool(result.reset),
                        "truncated": .bool(result.truncated),
                    ])
                )

            case "write":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                guard let text = request.text else {
                    throw TerminalControlError.invalidRequest(
                        "text is required"
                    )
                }
                try tab.write(text)
                return .success()

            case "key":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                guard let rawKey = request.key,
                      let key = TerminalInputKey(rawValue: rawKey),
                      key != .interrupt else {
                    throw TerminalControlError.invalidRequest(
                        "key must be enter, escape, up, down, left, or right"
                    )
                }
                try tab.sendKey(key)
                return .success()

            case "interrupt":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                try tab.sendKey(.interrupt)
                return .success()

            case "status":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                return .success(tab.statusPayload)

            case "close":
                let fields = try managedTerminalFields(request)
                try runtimeManager.closeManagedTab(
                    tabID: fields.tabID,
                    capability: fields.capability
                )
                return .success(
                    .object(["closed": .bool(true)])
                )

            case "shell-ready":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                try tab.markShellReady()
                return .success(tab.statusPayload)

            case "fetch-command":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                guard let commandID = request.commandID else {
                    throw TerminalControlError.invalidRequest(
                        "commandID is required"
                    )
                }
                return .success(
                    .object([
                        "command": .string(
                            try tab.command(commandID: commandID)
                        ),
                    ])
                )

            case "command-finished":
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                guard let commandID = request.commandID,
                      let exitCode = request.exitCode else {
                    throw TerminalControlError.invalidRequest(
                        "commandID and exitCode are required"
                    )
                }
                try tab.finish(
                    commandID: commandID,
                    exitCode: exitCode
                )
                return .success(tab.statusPayload)

            default:
                throw TerminalControlError.unsupportedMethod(
                    request.method
                )
            }
        } catch let error as TerminalControlError {
            return .failure(error)
        } catch {
            return .failure(
                .internalFailure(error.localizedDescription)
            )
        }
    }

    private func managedTerminal(
        _ request: TerminalControlRequest,
        runtimeManager: ConversationRuntimeManager
    ) throws -> ManagedTerminalTab {
        let fields = try managedTerminalFields(request)
        return try runtimeManager.managedTab(
            tabID: fields.tabID,
            capability: fields.capability
        )
    }

    private func managedTerminalFields(
        _ request: TerminalControlRequest
    ) throws -> (tabID: String, capability: String) {
        guard let tabID = request.tabID, !tabID.isEmpty,
              let capability = request.capability,
              !capability.isEmpty else {
            throw TerminalControlError.invalidRequest(
                "tabID and capability are required"
            )
        }
        return (tabID, capability)
    }

    private func terminalControlRootSessionID(
        for sessionID: String
    ) -> String? {
        if runtimeManager?.runtime(sessionID: sessionID) != nil {
            return sessionID
        }
        return hookCoordinator?.rootSessionID(for: sessionID)
            ?? runtimeManager?.rootSessionID(containing: sessionID)
    }

    private func archivedRuntimeUnloaded(
        sessionID: String,
        nextSelectedSessionID: String?
    ) {
        lifecycleCatchupTasks.removeValue(forKey: sessionID)?.cancel()
        lifecycleReconciliationTasks.removeValue(
            forKey: sessionID
        )?.cancel()
        pendingLifecycleCatchup.remove(sessionID)
        completedLifecycleCatchup.remove(sessionID)
        hookCoordinator?.deactivateRoot(sessionID: sessionID)
        guard selectedSessionID == sessionID else { return }
        selectedSessionID = nextSelectedSessionID
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setLastVisibleSession(nextSelectedSessionID)
            }
        }
    }

    private func isConversationVisible(_ sessionID: String) -> Bool {
        guard let summary = summaries.first(where: { $0.id == sessionID })
        else {
            return false
        }
        return !metadata.isSessionArchived(sessionID)
            && !metadata.isProjectArchived(summary.projectID)
    }

    private static func randomControlToken() -> String {
        [
            UUID().uuidString.lowercased(),
            UUID().uuidString.lowercased(),
        ].joined()
    }
}
