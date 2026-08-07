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

@MainActor
final class AppCoordinator: ObservableObject {
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

    private(set) var runtimeManager: ConversationRuntimeManager?

    private var controlClient: GrokControlClient?
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
    private var attentionNotifiedSessionIDs: Set<String> = []
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
    private var activeLeaderSocket: GrokLeaderSocket?
    private var lifecycleGeneration = 0
    private var started = false
    private let notifications = AttentionNotificationService()
    private let leaderProcessManager = GrokLeaderProcessManager()

    func start() async {
        guard !started else { return }
        started = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        status = .starting

        do {
            let fileManager = FileManager.default
            let supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Coinor", isDirectory: true)
            try fileManager.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
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

            let executable = try GrokExecutable.resolve()
            let leaderSocket = try GrokLeaderSocket.coinorDefault()
            let launch = GrokControlLaunch(
                executable: executable,
                leaderSocket: leaderSocket
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

            let hookSocket = supportDirectory
                .appendingPathComponent("hook.sock")
                .path
            let hook = HookCoordinator(
                listener: try HookEventListener(socketPath: hookSocket),
                runtimes: runtimes
            )
            hookCoordinator = hook
            hook.onError = { [weak self] message in
                self?.warningMessage =
                    "Coinor's hook listener stopped: \(message)"
            }
            runtimes.onRootProcessExit = { [weak self] sessionID in
                self?.rootProcessExited(sessionID: sessionID)
            }
            hook.start()

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
            status = .failed("Coinor startup was cancelled.")
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
            mode: .resume
        )
        hookCoordinator?.activateRoot(sessionID: sessionID)
        runtimeManager.select(sessionID: sessionID)
        selectedSessionID = sessionID
        reconcileRuntimeActivity()
        requestLifecycleCatchup(for: sessionID)

        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setLastVisibleSession(sessionID)
            }
        }
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
            title: "New Conversation"
        )
        pendingSessions[sessionID] = summary
        rebuildCatalog()

        _ = runtimeManager.activateRoot(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            mode: .newSession,
            additionalArguments: additionalArguments
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
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist { document in
                document.unpin(sessionID)
                document.setSessionArchived(sessionID, archived: true)
            }
            if persisted {
                coordinator.runtimeManager?.markArchived(
                    sessionID: sessionID
                )
            }
        }
    }

    func unarchiveConversation(_ sessionID: String) {
        let cancelsPendingUnload = summaries.first {
            $0.id == sessionID
        }.map {
            !metadata.isProjectArchived($0.projectID)
        } ?? false
        if cancelsPendingUnload {
            runtimeManager?.markUnarchived(sessionID: sessionID)
        }
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist {
                $0.setSessionArchived(sessionID, archived: false)
            }
            if !persisted, cancelsPendingUnload {
                coordinator.runtimeManager?.markArchived(
                    sessionID: sessionID
                )
            }
        }
    }

    func archiveProject(_ projectID: String) {
        let sessionIDs = summaries
            .filter { $0.projectID == projectID }
            .map(\.id)
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist {
                $0.setProjectArchived(projectID, archived: true)
            }
            if persisted {
                sessionIDs.forEach {
                    coordinator.runtimeManager?.markArchived(sessionID: $0)
                }
            }
        }
    }

    func unarchiveProject(_ projectID: String) {
        let sessionIDs = summaries
            .filter {
                $0.projectID == projectID
                    && !metadata.isSessionArchived($0.id)
            }
            .map(\.id)
        sessionIDs.forEach {
            runtimeManager?.markUnarchived(sessionID: $0)
        }
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist {
                $0.setProjectArchived(projectID, archived: false)
            }
            if !persisted {
                sessionIDs.forEach {
                    coordinator.runtimeManager?.markArchived(sessionID: $0)
                }
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
        hookCoordinator?.stop()
        hookCoordinator = nil
        runtimeManager?.shutdown()
        runtimeManager = nil
        let control = controlClient
        controlClient = nil
        let leaderSocket = activeLeaderSocket
        activeLeaderSocket = nil
        metadataStore = nil
        roster.removeAll()
        attentionNotifiedSessionIDs.removeAll()
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
                "Coinor could not stop its private Grok leader: "
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
        URL(
            fileURLWithPath: mainCheckout(for: projectID),
            isDirectory: true
        ).lastPathComponent
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
        if let runtime = runtimeManager?.runtime(sessionID: sessionID) {
            return runtime.aggregateActivity
        }
        return authoritativeActivity(for: sessionID) ?? .idle
    }

    private var summaries: [SessionSummary] {
        let persisted = persistedSessions.map { session in
            SessionSummary(
                id: session.id.rawValue,
                projectID: projectIDBySessionID[session.id.rawValue]
                    ?? fallbackProjectID(for: session),
                title: session.title ?? "Untitled Conversation"
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
        _ transform: @Sendable @escaping (inout MetadataDocument) -> Void
    ) async -> Bool {
        guard let metadataStore else { return false }
        do {
            metadata = try await metadataStore.update(transform)
            rebuildCatalog()
            return true
        } catch {
            warningMessage = error.localizedDescription
            return false
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
                case .notification(let method, _):
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
            if runtime.aggregateActivity == .needsInput {
                if attentionNotifiedSessionIDs.insert(runtime.id).inserted {
                    let title = summaries.first(where: {
                        $0.id == runtime.id
                    })?.title ?? "Grok Conversation"
                    Task {
                        await notifications.notifyIfNeeded(
                            sessionID: runtime.id,
                            conversationTitle: title
                        )
                    }
                }
            } else {
                attentionNotifiedSessionIDs.remove(runtime.id)
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
                    "Coinor could not restore subagent panels: \(error.localizedDescription)"
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
                try? await Task.sleep(for: .seconds(3))
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
                    continue
                }
                guard self.isCurrent(
                    controlClient,
                    generation: generation
                ) else {
                    break
                }
                self.reconcileRuntimeActivity()
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
}
