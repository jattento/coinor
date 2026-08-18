import AppKit
import Foundation

private struct ProjectLocationSnapshot: Sendable {
    let projectIDBySessionID: [String: String]
    let mainCheckoutByProjectID: [String: String]
}

private struct DetachedRuntimeState {
    let controlClient: GrokControlClient?
    let leaderSocket: GrokLeaderSocket?
    let remoteHosts: [RemoteHostRuntime]
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
    private static let conversationTabsPersistenceDelay =
        Duration.milliseconds(400)

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
    /// Set by the sidebar while the add/manage remote-computer interface is
    /// presented, so a disconnect can interrupt only where it is relevant.
    @Published var isRemoteHostsInterfacePresented = false

    func presentTelegramWarning(_ message: String) {
        warningMessage = message
    }

    private(set) var runtimeManager: ConversationRuntimeManager?

    let telegram = TelegramBridge()
    var controlClient: GrokControlClient?
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
    var pendingSessions: [String: SessionSummary] = [:]
    private var projectIDBySessionID: [String: String] = [:]
    private var mainCheckoutByProjectID: [String: String] = [:]
    private var localPersistedSessions: [GrokPersistedSession] = []
    private var localRoster: [String: GrokRosterEntry] = [:]
    private var localProjectIDBySessionID: [String: String] = [:]
    private var localMainCheckoutByProjectID: [String: String] = [:]
    private var remoteHosts: [RemoteHostAlias: RemoteHostRuntime] = [:]
    private var remoteEventTasks: [RemoteHostAlias: Task<Void, Never>] = [:]
    private var remoteHostConnectionStates:
        [RemoteHostAlias: RemoteHostConnectionState] = [:]
    private var cachedSSHConfigAliases: [RemoteHostAlias] = []
    private var worktreeConversationTask: Task<Void, Never>?
    private var addProjectTask: Task<Void, Never>?
    private var renameConversationTask: Task<Void, Never>?
    /// Why a registered host has no runtime, so the interface can explain a
    /// computer that is away instead of showing nothing.
    @Published private(set) var unreachableRemoteHostReasons:
        [RemoteHostAlias: String] = [:]
    /// Which computer owns each conversation, so control-plane work is routed
    /// to the leader that actually holds the session.
    var hostAliasBySessionID: [String: RemoteHostAlias] = [:]
    private var localGrokVersion: GrokForkVersion?
    private var supportDirectory: URL?
    @Published private var pendingAttention:
        [String: ConversationAttentionReason] = [:]
    private var lastAggregateActivity: [String: RuntimeActivity] = [:]
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
    /// Tab selection changes arrive on every switch, so they are coalesced per
    /// conversation and written once the burst settles.
    private var pendingConversationTabs: [String: ConversationTabMetadata] = [:]
    private var conversationTabsPersistenceTask: Task<Void, Never>?
    private var activeLeaderSocket: GrokLeaderSocket?
    private var visibleConversationNavigationIDs: [String] = []
    private var reorderGeneration = 0
    private var lifecycleGeneration = 0
    private var started = false
    private let notifications = AttentionNotificationService()
    private var remoteDisconnectEpisodes = RemoteDisconnectNotificationEpisodes()
    var agenticFinder: GrokAgenticConversationFinder?
    private let sessionTranscriptLocator = GrokSessionTranscriptLocator(
        root: GrokSessionTranscriptLocator.defaultRoot()
    )
    private let isApplicationActive: () -> Bool = { NSApp.isActive }
    private var activationObserver: (any NSObjectProtocol)?
    private let leaderProcessManager = GrokLeaderProcessManager()
    private let terminalControlAuthorizer =
        TerminalControlInvocationAuthorizer()

    func start() async {
        guard !started else { return }
        started = true
        InheritedTerminalEnvironment.removeColorSuppression()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        observeApplicationActivation()
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

            self.supportDirectory = supportDirectory
            let store = try MetadataStore(directoryURL: supportDirectory)
            metadataStore = store
            metadata = await store.currentDocument
            localMainCheckoutByProjectID = metadata.projects.compactMapValues {
                $0.checkoutPath
            }
            reloadSSHConfigAliases()

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
            let finder = GrokAgenticConversationFinder(
                executable: executable,
                supportDirectory: supportDirectory
            )
            agenticFinder = finder
            await finder.cleanupPendingSessions()
            let leaderSocket = try GrokLeaderSocket.coinorDefault(
                supportDirectory: supportDirectory
            )
            _ = try await leaderProcessManager.stop(
                leaderSocket: leaderSocket
            )
            var leaderEnvironment = ProcessInfo.processInfo.environment
            leaderEnvironment[
                TerminalControlContract.EnvironmentVariable
                    .controlSocket
            ] = terminalControlSocket.path
            leaderEnvironment[
                TerminalControlContract.EnvironmentVariable
                    .controlToken
            ] = terminalControlToken
            leaderEnvironment[
                TerminalControlContract.EnvironmentVariable
                    .controlClient
            ] = clientURL.path
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

            let lastVisible = metadata.lastVisibleSessionID
            if let lastVisible, isConversationVisible(lastVisible) {
                selectConversation(lastVisible)
            }

            telegram.attach(worker: self, metadata: metadata)
            telegram.startPolling()

            await connectRegisteredRemoteHosts()

            if let lastVisible,
               selectedSessionID != lastVisible,
               isConversationVisible(lastVisible) {
                selectConversation(lastVisible)
            }
        } catch is CancellationError {
            guard generation == lifecycleGeneration else { return }
            let detached = detachRuntimeState(remoteHostEvent: .shutdown)
            await stop(detached)
            status = .failed("Conan Code startup was cancelled.")
        } catch {
            guard generation == lifecycleGeneration else { return }
            let message = error.localizedDescription
            let detached = detachRuntimeState(remoteHostEvent: .shutdown)
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
        var refreshedMainCheckouts = localMainCheckoutByProjectID
        refreshedMainCheckouts.merge(
            locations.mainCheckoutByProjectID,
            uniquingKeysWith: { _, refreshed in refreshed }
        )
        let refreshedRoster = Dictionary(
            uniqueKeysWithValues: rosterEntries.map {
                ($0.id.rawValue, $0)
            }
        )

        localPersistedSessions = sessions
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
        localProjectIDBySessionID = locations.projectIDBySessionID
        localMainCheckoutByProjectID = refreshedMainCheckouts
        localRoster = refreshedRoster
        reloadSSHConfigAliases()
        mergeCatalogState()
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
            tabMetadata: metadata.conversationTabs(sessionID),
            execution: execution(forSession: sessionID)
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

    // MARK: - Remote hosts

    /// Aliases from `~/.ssh/config` that are not registered yet. Conan Code
    /// offers these instead of asking for connection details, so it never
    /// stores a credential of its own.
    var availableRemoteHostAliases: [RemoteHostAlias] {
        AvailableRemoteHostAliases.fromCache(
            cachedSSHConfigAliases,
            registered: metadata.remoteHostAliases
        )
    }

    var registeredRemoteHosts: [RemoteHostAlias] {
        metadata.remoteHostAliases
    }

    func remoteHost(_ alias: RemoteHostAlias) -> RemoteHostRuntime? {
        remoteHosts[alias]
    }

    /// Whether remote projects are currently kept out of the sidebar.
    var remoteProjectsHidden: Bool {
        metadata.remoteProjectsHidden
    }

    /// Shows or hides every remote project. Registered computers, their
    /// runtimes, and any conversation running on them are untouched.
    func setRemoteProjectsHidden(_ hidden: Bool) {
        guard hidden != metadata.remoteProjectsHidden else { return }
        metadata.setRemoteProjectsHidden(hidden)
        rebuildCatalog()
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.setRemoteProjectsHidden(hidden)
            }
        }
    }

    /// Registers a computer after it passes the same compatibility contract
    /// the local runtime passes at start-up. Returns an English diagnostic on
    /// failure; a host is never half-registered.
    @discardableResult
    func addRemoteHost(_ alias: RemoteHostAlias) async -> String? {
        if let failure = await connectRemoteHost(alias) {
            return failure
        }
        metadata.registerRemoteHost(alias)
        reloadSSHConfigAliases()
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.registerRemoteHost(alias)
            }
        }
        return nil
    }

    func removeRemoteHost(_ alias: RemoteHostAlias) {
        remoteDisconnectEpisodes.remove(alias)
        applyRemoteHostEvent(alias, .remove)
        let host = uninstallRemoteHostArtifacts(alias)
        metadata.unregisterRemoteHost(alias)
        reloadSSHConfigAliases()
        mergeCatalogState()
        rebuildCatalog()
        schedulePersistence { coordinator in
            await coordinator.persist {
                $0.unregisterRemoteHost(alias)
            }
        }
        Task { await host?.shutdown() }
    }

    /// Ends the Grok runtime on a remote computer. Every agent still working
    /// there stops, so callers confirm first.
    func stopRemoteRuntime(_ alias: RemoteHostAlias) async -> String? {
        if let host = remoteHosts[alias] {
            do {
                try await host.stopRemoteRuntime()
            } catch {
                return error.localizedDescription
            }
        }
        applyRemoteHostEvent(alias, .stop)
        _ = uninstallRemoteHostArtifacts(alias)
        mergeCatalogState()
        rebuildCatalog()
        return nil
    }

    private func connectRemoteHost(
        _ alias: RemoteHostAlias,
        reportsFailure: Bool = true,
        isExplicitRetry: Bool = false
    ) async -> String? {
        if remoteHostConnectionStates[alias] == .connecting {
            return nil
        }
        if let host = remoteHosts[alias],
           host.unreachableReason == nil,
           remoteHostConnectionStates[alias] == .connected {
            return nil
        }
        if remoteHosts[alias] != nil {
            await shutdownUninstalledRemoteHost(
                uninstallRemoteHostArtifacts(alias)
            )
        }
        applyRemoteHostEvent(
            alias,
            isExplicitRetry ? .retry : .connect
        )
        guard remoteHostConnectionStates[alias] == .connecting else {
            return nil
        }
        guard let supportDirectory else {
            applyRemoteHostEvent(alias, .fail)
            return "Conan Code has not finished starting."
        }
        let generation = lifecycleGeneration
        guard let localVersion = await resolvedLocalGrokVersion() else {
            if generation == lifecycleGeneration,
               remoteHostConnectionStates[alias] == .connecting {
                applyRemoteHostEvent(alias, .fail)
            }
            return "Conan Code could not determine this computer's Grok version."
        }
        var connected: RemoteHostRuntime?
        do {
            let host = try await RemoteHostRuntime.connect(
                alias: alias,
                supportDirectory: supportDirectory,
                localVersion: localVersion
            )
            connected = host
            try await loadRemoteHostCatalog(host)
            guard generation == lifecycleGeneration,
                  remoteHostConnectionStates[alias] == .connecting
            else {
                await host.shutdown()
                return nil
            }
            publishRemoteHost(host, generation: generation)
            return nil
        } catch {
            await connected?.shutdown()
            if generation == lifecycleGeneration,
               remoteHostConnectionStates[alias] == .connecting {
                applyRemoteHostEvent(alias, .fail)
                _ = uninstallRemoteHostArtifacts(alias)
                mergeCatalogState()
            }
            let message = error.localizedDescription
            if !reportsFailure {
                // Keep the sidebar badge red and the management view honest
                // without interrupting the user on every retry.
                unreachableRemoteHostReasons[alias] = message
                rebuildCatalog()
            }
            return message
        }
    }

    private func resolvedLocalGrokVersion() async -> GrokForkVersion? {
        if let localGrokVersion { return localGrokVersion }
        guard let controlClient,
              let text = await controlClient.executableVersion,
              let version = GrokForkVersion(text: text) else {
            return nil
        }
        localGrokVersion = version
        return version
    }

    /// Reconnects every registered host that is not explicitly stopped.
    /// Connections run in a task group bounded to 4 so a dead host's SSH
    /// timeout cannot stall every other computer.
    private func connectRegisteredRemoteHosts() async {
        let aliases = RemoteHostConnectionMachine.aliasesEligibleForAutoConnect(
            registered: metadata.remoteHostAliases,
            states: remoteHostConnectionStates
        )
        guard !aliases.isEmpty else { return }
        let bound = RemoteHostConnectionMachine.connectionConcurrencyLimit
        var index = aliases.startIndex
        while index < aliases.endIndex {
            let end = aliases.index(
                index,
                offsetBy: bound,
                limitedBy: aliases.endIndex
            ) ?? aliases.endIndex
            let batch = Array(aliases[index..<end])
            await withTaskGroup(of: Void.self) { group in
                for alias in batch {
                    group.addTask {
                        await self.connectRemoteHost(
                            alias,
                            reportsFailure: false
                        )
                    }
                }
            }
            index = end
        }
    }

    /// Loads one host's catalog into that host only. The merged maps stay
    /// untouched until the caller publishes the host or refreshes an already
    /// published one.
    private func loadRemoteHostCatalog(
        _ host: RemoteHostRuntime
    ) async throws {
        async let persistedRequest = host.control.listPersistedSessions()
        async let rosterRequest = host.control.listRoster()
        let (allSessions, rosterEntries) = try await (
            persistedRequest,
            rosterRequest
        )
        let sessions = allSessions.filter { !$0.isSubagent }
        let alias = host.alias
        let runner = host.commandRunner
        let locations = await Task.detached {
            Self.resolveRemoteProjectLocations(
                for: sessions,
                alias: alias,
                runner: runner
            )
        }.value

        host.persistedSessions = sessions
        host.roster = Dictionary(
            uniqueKeysWithValues: rosterEntries.map { ($0.id.rawValue, $0) }
        )
        host.projectIDBySessionID = locations.projectIDBySessionID
        host.mainCheckoutByProjectID.merge(
            locations.mainCheckoutByProjectID,
            uniquingKeysWith: { _, refreshed in refreshed }
        )
        host.unreachableReason = nil
    }

    private func publishRemoteHost(
        _ host: RemoteHostRuntime,
        generation: Int
    ) {
        let alias = host.alias
        remoteHosts[alias] = host
        unreachableRemoteHostReasons.removeValue(forKey: alias)
        if let versionWarning = host.host.versionWarning {
            warningMessage = versionWarning
        }
        listenForRemoteControlEvents(host, generation: generation)
        applyPublishedRemoteHostOwnership(host)
        applyRemoteHostEvent(alias, .succeed)
        mergeCatalogState()
        rebuildCatalog()
    }

    private func applyPublishedRemoteHostOwnership(_ host: RemoteHostRuntime) {
        let alias = host.alias
        remoteDisconnectEpisodes.markConnected(alias)
        for session in host.persistedSessions {
            hostAliasBySessionID[session.id.rawValue] = alias
        }
    }

    private func refreshRemoteHost(_ host: RemoteHostRuntime) async throws {
        try await loadRemoteHostCatalog(host)
        applyPublishedRemoteHostOwnership(host)
        mergeCatalogState()
        rebuildCatalog()
    }

    /// Republishes the merged view of every computer's catalog. Local state is
    /// kept separately so a local refresh cannot drop remote rows.
    private func mergeCatalogState() {
        let merged = CatalogStateMerge.merge(
            local: CatalogStateMerge.Slice(
                sessions: localPersistedSessions,
                roster: localRoster,
                projectIDs: localProjectIDBySessionID,
                checkouts: localMainCheckoutByProjectID
            ),
            remotes: remoteHosts.values.map { host in
                CatalogStateMerge.Slice(
                    sessions: host.persistedSessions,
                    roster: host.roster,
                    projectIDs: host.projectIDBySessionID,
                    checkouts: host.mainCheckoutByProjectID
                )
            }
        )
        persistedSessions = merged.sessions
        roster = merged.roster
        projectIDBySessionID = merged.projectIDs
        mainCheckoutByProjectID = merged.checkouts
    }

    private func applyRemoteHostEvent(
        _ alias: RemoteHostAlias,
        _ event: RemoteHostConnectionEvent
    ) {
        let next = RemoteHostConnectionMachine.apply(
            remoteHostConnectionStates[alias],
            event
        )
        if let next {
            remoteHostConnectionStates[alias] = next
        } else {
            remoteHostConnectionStates.removeValue(forKey: alias)
        }
    }

    /// Drops the published runtime, listener, and session ownership for one
    /// host. Connection intent is left to the caller.
    private func uninstallRemoteHostArtifacts(
        _ alias: RemoteHostAlias
    ) -> RemoteHostRuntime? {
        remoteEventTasks.removeValue(forKey: alias)?.cancel()
        let host = remoteHosts.removeValue(forKey: alias)
        hostAliasBySessionID = hostAliasBySessionID.filter {
            $0.value != alias
        }
        unreachableRemoteHostReasons.removeValue(forKey: alias)
        return host
    }

    private func shutdownUninstalledRemoteHost(
        _ host: RemoteHostRuntime?
    ) async {
        await host?.shutdown()
    }

    private func reloadSSHConfigAliases() {
        cachedSSHConfigAliases = SSHConfigHosts().aliases()
    }

    func applyMainCheckout(_ projectID: String, path: String) {
        if let alias = hostAlias(forProject: projectID),
           let host = remoteHosts[alias] {
            host.mainCheckoutByProjectID[projectID] = path
        } else {
            localMainCheckoutByProjectID[projectID] = path
        }
        mergeCatalogState()
    }

    private func applyRosterEntry(
        _ entry: GrokRosterEntry,
        sessionID: String
    ) {
        if let alias = hostAlias(forSession: sessionID),
           let host = remoteHosts[alias] {
            host.roster[sessionID] = entry
        } else {
            localRoster[sessionID] = entry
        }
        mergeCatalogState()
    }

    private func applyMaterializedSession(
        _ persisted: GrokPersistedSession,
        sessionID: String,
        locations: ProjectLocationSnapshot
    ) {
        if let alias = hostAlias(forSession: sessionID),
           let host = remoteHosts[alias] {
            host.persistedSessions.removeAll {
                $0.id.rawValue == sessionID
            }
            host.persistedSessions.append(persisted)
            host.projectIDBySessionID.merge(
                locations.projectIDBySessionID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
            host.mainCheckoutByProjectID.merge(
                locations.mainCheckoutByProjectID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
        } else {
            localPersistedSessions.removeAll {
                $0.id.rawValue == sessionID
            }
            localPersistedSessions.append(persisted)
            localProjectIDBySessionID.merge(
                locations.projectIDBySessionID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
            localMainCheckoutByProjectID.merge(
                locations.mainCheckoutByProjectID,
                uniquingKeysWith: { _, refreshed in refreshed }
            )
        }
        mergeCatalogState()
    }

    /// The context a remote disconnect would land in right now.
    var remoteDisconnectNotificationScope: RemoteDisconnectNotificationScope {
        RemoteDisconnectNotificationScope(
            selectedConversationHost: selectedSessionID
                .flatMap { hostAlias(forSession: $0) },
            isRemoteHostsInterfacePresented: isRemoteHostsInterfacePresented
        )
    }

    /// Notifies about a dropped remote computer only where the user can act on
    /// it. Out of scope the episode stays unclaimed, so the next retry raises
    /// it once the user is back in remote territory.
    private func notifyRemoteDisconnectIfInScope(
        _ alias: RemoteHostAlias
    ) async {
        guard remoteDisconnectNotificationScope.allowsDisconnectNotification,
              remoteDisconnectEpisodes.markUnavailable(alias) else {
            return
        }
        await notifications.notifyRemoteDisconnect(alias)
    }

    /// The computer that owns a conversation, or `nil` when it is local.
    func hostAlias(forSession sessionID: String) -> RemoteHostAlias? {
        if let alias = hostAliasBySessionID[sessionID] { return alias }
        guard let projectID = projectIDBySessionID[sessionID] else {
            return nil
        }
        return ProjectIdentity(rawValue: projectID).target.remoteAlias
    }

    func hostAlias(forProject projectID: String) -> RemoteHostAlias? {
        ProjectIdentity(rawValue: projectID).target.remoteAlias
    }

    /// Routes control-plane work to the leader that actually holds the
    /// session. A remote conversation is never driven by the local client.
    private func controlClient(
        forSession sessionID: String
    ) -> GrokControlClient? {
        guard let alias = hostAlias(forSession: sessionID) else {
            return controlClient
        }
        return remoteHosts[alias]?.control
    }

    private func execution(
        forProject projectID: String
    ) -> ConversationExecution? {
        guard let alias = hostAlias(forProject: projectID) else { return nil }
        return remoteHosts[alias]?.execution
    }

    private func execution(
        forSession sessionID: String
    ) -> ConversationExecution? {
        guard let alias = hostAlias(forSession: sessionID) else { return nil }
        return remoteHosts[alias]?.execution
    }

    /// Mirrors the local control-event loop for one remote computer. A remote
    /// stream ending marks that host unreachable instead of failing the
    /// application, because the rest of the sidebar keeps working.
    private func listenForRemoteControlEvents(
        _ host: RemoteHostRuntime,
        generation: Int
    ) {
        let alias = host.alias
        remoteEventTasks[alias]?.cancel()
        remoteEventTasks[alias] = Task { [weak self] in
            let events = await host.control.events()
            for await event in events {
                guard let self,
                      !Task.isCancelled,
                      self.remoteHosts[alias] === host,
                      self.lifecycleGeneration == generation else {
                    return
                }
                switch event {
                case .rosterChanged(let change):
                    for removed in change.removed {
                        host.roster.removeValue(forKey: removed.rawValue)
                    }
                    for entry in change.upserted {
                        host.roster[entry.id.rawValue] = entry
                        self.hostAliasBySessionID[entry.id.rawValue] = alias
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
                    self.mergeCatalogState()
                    self.reconcileRuntimeActivity()
                case .subagentLifecycle(let observation):
                    self.reconcileSubagentLifecycle(observation)
                    self.forwardSubagentToTelegram(observation)
                case .notification:
                    continue
                case .terminated(let error):
                    host.unreachableReason = error.localizedDescription
                    await self.notifyRemoteDisconnectIfInScope(alias)
                    return
                }
            }
        }
    }

    /// Refreshes every reachable host and quietly retries the ones that are
    /// not. A remote computer that was asleep, restarted, or off the network
    /// comes back on its own, without the user having to remove and add it.
    /// An explicitly stopped host is never probed again.
    private func refreshRemoteHosts() async {
        for host in remoteHosts.values {
            do {
                try await refreshRemoteHost(host)
            } catch {
                host.unreachableReason = error.localizedDescription
                await notifyRemoteDisconnectIfInScope(host.alias)
            }
        }

        for alias in metadata.remoteHostAliases {
            if remoteHostConnectionStates[alias] == .stopped
                || remoteHostConnectionStates[alias] == .connecting {
                continue
            }
            let host = remoteHosts[alias]
            guard host == nil || host?.unreachableReason != nil else {
                continue
            }
            // A failed retry is expected while the computer is away, so it
            // updates the badge instead of raising a warning.
            _ = await connectRemoteHost(alias, reportsFailure: false)
        }
    }

    /// Drops a host's runtime and connects to it again. Used by the explicit
    /// `Reconnect` action; the periodic refresh does the same on its own.
    @discardableResult
    func reconnectRemoteHost(_ alias: RemoteHostAlias) async -> String? {
        await shutdownUninstalledRemoteHost(
            uninstallRemoteHostArtifacts(alias)
        )
        return await connectRemoteHost(
            alias,
            isExplicitRetry: true
        )
    }

    // MARK: - Remote projects

    /// Repositories the picker offers for a host: the ones its Grok catalog
    /// already knows plus a bounded remote scan.
    func remoteRepositoryCandidates(
        _ alias: RemoteHostAlias
    ) async throws -> [RemoteRepositoryCandidate] {
        guard let host = remoteHosts[alias] else {
            throw RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: "it is not connected"
            )
        }
        let knownRoots = host.projectIDBySessionID.values.map {
            ProjectIdentity(rawValue: $0).path
        }
        let discovery = RemoteProjectDiscovery(
            runner: host.commandRunner,
            alias: alias
        )
        return try await Task.detached {
            try discovery.candidates(knownGitRoots: Array(Set(knownRoots)))
        }.value
    }

    /// Lists one remote directory for the picker's `Browse…` fallback.
    func remoteDirectoryEntries(
        _ alias: RemoteHostAlias,
        at path: String?
    ) async throws -> (path: String, entries: [RemoteDirectoryEntry]) {
        guard let host = remoteHosts[alias] else {
            throw RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: "it is not connected"
            )
        }
        let discovery = RemoteProjectDiscovery(
            runner: host.commandRunner,
            alias: alias
        )
        let directory = path ?? host.host.homeDirectory
        let entries = try await Task.detached {
            try discovery.directoryEntries(at: directory)
        }.value
        return (directory, entries)
    }

    /// Registers a repository that lives on a remote computer. Git runs there,
    /// so the path is never validated against this file system.
    @discardableResult
    func addRemoteProject(
        alias: RemoteHostAlias,
        path: String
    ) async -> String? {
        guard let host = remoteHosts[alias] else {
            return RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: "it is not connected"
            ).localizedDescription
        }
        let runner = host.commandRunner
        let checkout = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let resolution = try await Task.detached {
                try GitProjectResolver(remote: alias, runner: runner)
                    .resolve(checkout: checkout)
            }.value
            let projectID = resolution.identity.rawValue
            host.mainCheckoutByProjectID[projectID] =
                resolution.mainCheckout.path
            mergeCatalogState()
            schedulePersistence { coordinator in
                await coordinator.persist {
                    $0.registerProject(
                        projectID,
                        checkoutPath: resolution.mainCheckout.path
                    )
                }
            }
            rebuildCatalog()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private nonisolated static func resolveRemoteProjectLocations(
        for sessions: [GrokPersistedSession],
        alias: RemoteHostAlias,
        runner: any RemoteCommandRunning
    ) -> ProjectLocationSnapshot {
        let resolver = GitProjectResolver(remote: alias, runner: runner)
        var projectIDs: [String: String] = [:]
        var mainCheckouts: [String: String] = [:]
        for session in sessions {
            guard let resolution = try? resolver.resolve(
                projectFor: session
            ) else {
                continue
            }
            projectIDs[session.id.rawValue] = resolution.identity.rawValue
            mainCheckouts[resolution.identity.rawValue] =
                resolution.mainCheckout.path
        }
        return ProjectLocationSnapshot(
            projectIDBySessionID: projectIDs,
            mainCheckoutByProjectID: mainCheckouts
        )
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

    @discardableResult
    func createConversation(
        in projectID: String,
        workingDirectory: String,
        additionalArguments: [String]
    ) -> String {
        let sessionID = UUID().uuidString.lowercased()
        guard let runtimeManager else { return sessionID }
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
            tabMetadata: metadata.conversationTabs(sessionID),
            execution: execution(forProject: projectID)
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
        return sessionID
    }

    func addProject(url: URL) {
        let generation = lifecycleGeneration
        addProjectTask?.cancel()
        addProjectTask = Task { [weak self] in
            do {
                let resolution = try await Task.detached {
                    try GitProjectResolver().resolve(checkout: url)
                }.value
                guard let self,
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                let projectID = resolution.identity.rawValue
                self.applyMainCheckout(
                    projectID,
                    path: resolution.mainCheckout.path
                )
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
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
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
        let remoteRunner = hostAlias(forProject: projectID)
            .flatMap { remoteHosts[$0] }
            .map { (alias: $0.alias, runner: $0.commandRunner) }
        let generation = lifecycleGeneration
        worktreeConversationTask?.cancel()
        worktreeConversationTask = Task { [weak self] in
            do {
                let result = try await Task.detached {
                    let service = remoteRunner.map {
                        WorktreeService(remote: $0.alias, runner: $0.runner)
                    }
                    return try (service ?? WorktreeService()).prepareCreation(
                        named: trimmed,
                        from: checkout
                    )
                }.value
                guard let self,
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                self.applyMainCheckout(
                    projectID,
                    path: result.plan.project.mainCheckout.path
                )
                self.warningMessage = result.warning
                self.createConversation(
                    in: projectID,
                    workingDirectory: result.plan.workingDirectory.path,
                    additionalArguments: result.plan.grokArguments
                )
            } catch {
                guard let self,
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                self.warningMessage = error.localizedDescription
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
        performArchiveConversation(sessionID)
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
                Task {
                    await coordinator.telegram.closeTopic(for: sessionID)
                }
            }
        }
    }

    func unarchiveConversation(_ sessionID: String) {
        schedulePersistence { coordinator in
            _ = await coordinator.persist {
                $0.setSessionArchived(sessionID, archived: false)
            }
            await coordinator.telegram.reopenTopic(for: sessionID)
        }
    }

    func archiveProject(_ projectID: String) {
        performArchiveProject(projectID)
    }

    private func performArchiveProject(_ projectID: String) {
        let sessionIDs = summaries
            .filter { $0.projectID == projectID }
            .map(\.id)
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist { document in
                sessionIDs.forEach { document.unpin($0) }
                document.setProjectArchived(projectID, archived: true)
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
        guard !trimmed.isEmpty,
              let controlClient = controlClient(forSession: sessionID)
        else {
            return
        }
        let directory = session(sessionID)?.cwd
        let generation = lifecycleGeneration
        renameConversationTask?.cancel()
        renameConversationTask = Task { [weak self] in
            do {
                try await controlClient.rename(
                    GrokSessionID(sessionID),
                    to: trimmed,
                    inDirectory: directory
                )
                guard let self,
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                try await self.refresh()
                await self.telegram.syncTitle(trimmed, for: sessionID)
            } catch {
                guard let self,
                      CoordinatorMutationGate.allowsMutation(
                          capturedGeneration: generation,
                          currentGeneration: self.lifecycleGeneration,
                          isCancelled: Task.isCancelled
                      ) else {
                    return
                }
                self.warningMessage = error.localizedDescription
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
        let detached = detachRuntimeState(remoteHostEvent: .restart)
        await stop(detached)
        started = false
        status = .starting
        await start()
    }

    func shutdown() async {
        await drainPersistenceTasks()
        let detached = detachRuntimeState(remoteHostEvent: .shutdown)
        await stop(detached)
        applicationInstanceLock = nil
        started = false
    }

    private func detachRuntimeState(
        remoteHostEvent: RemoteHostConnectionEvent = .restart
    ) -> DetachedRuntimeState {
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
        cancelCoordinatorMutationTasks()
        remoteEventTasks.values.forEach { $0.cancel() }
        remoteEventTasks.removeAll()
        let remotes = Array(remoteHosts.values)
        remoteHosts.removeAll()
        hostAliasBySessionID.removeAll()
        unreachableRemoteHostReasons.removeAll()
        for alias in Array(remoteHostConnectionStates.keys) {
            applyRemoteHostEvent(alias, remoteHostEvent)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        mergeCatalogState()
        agenticFinder?.cancel()
        agenticFinder = nil
        terminalControlAuthorizer.reset()
        terminalControlServer?.stop()
        terminalControlServer = nil
        terminalControlConfiguration = nil
        hookCoordinator = nil
        runtimeManager?.shutdown()
        runtimeManager = nil
        let control = controlClient
        controlClient = nil
        let leaderSocket = activeLeaderSocket
        activeLeaderSocket = nil
        telegram.stopPolling()
        metadataStore = nil
        roster.removeAll()
        pendingAttention.removeAll()
        lastAggregateActivity.removeAll()
        return DetachedRuntimeState(
            controlClient: control,
            leaderSocket: leaderSocket,
            remoteHosts: remotes
        )
    }

    private func cancelCoordinatorMutationTasks() {
        worktreeConversationTask?.cancel()
        worktreeConversationTask = nil
        addProjectTask?.cancel()
        addProjectTask = nil
        renameConversationTask?.cancel()
        renameConversationTask = nil
    }

    private func stop(_ detached: DetachedRuntimeState) async {
        await detached.controlClient?.shutdown()
        for host in detached.remoteHosts {
            await host.shutdown()
        }
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

    func projectIndicator(_ project: ProjectRow) -> ConversationIndicator {
        ConversationIndicator.aggregate(
            summaries.lazy
                .filter {
                    $0.projectID == project.projectID
                        && !self.metadata.isSessionArchived($0.id)
                }
                .map { self.indicator(for: $0.id) }
                .filter(\.propagatesToProject)
        )
    }

    func indicator(for sessionID: String) -> ConversationIndicator {
        ConversationIndicator.resolve(
            activity: activity(for: sessionID),
            attention: pendingAttention[sessionID]
        )
    }

    func activity(for sessionID: String) -> RuntimeActivity {
        if let runtime = runtimeManager?.runtime(sessionID: sessionID) {
            return runtime.aggregateActivity
        }
        return authoritativeActivity(for: sessionID) ?? .idle
    }

    private func acknowledgeAttention(_ sessionID: String) {
        pendingAttention.removeValue(forKey: sessionID)
    }

    func searchConversations(_ query: String) -> [ConversationRow] {
        ConversationSearch.results(
            query: query,
            sessions: summaries,
            metadata: metadata
        )
    }

    func makeAgenticFinderModel() -> AgenticConversationFinderModel? {
        agenticFinder.map(AgenticConversationFinderModel.init(finder:))
    }

    /// Describes every conversation for the finder. A local conversation is
    /// described by the path to its transcript, which the finder greps itself;
    /// only a remote conversation, whose transcript lives on another computer,
    /// still carries a short excerpt fetched over SSH.
    func agenticFinderCandidates() async -> [AgenticFinderCandidate] {
        let current = summaries
        let locator = sessionTranscriptLocator
        async let transcripts = Task.detached(priority: .userInitiated) {
            locator.transcriptPaths()
        }.value
        async let remoteExcerpts = remoteAgenticFinderExcerpts(for: current)
        let (transcriptPaths, excerpts) = await (transcripts, remoteExcerpts)
        let formatter = ISO8601DateFormatter()
        return current.map { summary in
            let remoteHost = hostAlias(forSession: summary.id)
            return AgenticFinderCandidate(
                id: summary.id,
                title: summary.title,
                project: projectDisplayName(summary.projectID),
                lastActivity: summary.lastActivityAt.map {
                    formatter.string(from: $0)
                },
                archived: metadata.isSessionArchived(summary.id)
                    || metadata.isProjectArchived(summary.projectID),
                pinned: metadata.isSessionPinned(summary.id),
                transcriptPath: remoteHost == nil
                    ? transcriptPaths[summary.id]
                    : nil,
                remoteHost: remoteHost?.rawValue,
                excerpt: remoteHost == nil ? nil : excerpts[summary.id]
            )
        }
    }

    private func remoteAgenticFinderExcerpts(
        for summaries: [SessionSummary]
    ) async -> [String: String] {
        let grouped = Dictionary(grouping: summaries.compactMap { summary in
            hostAlias(forSession: summary.id).map { ($0, summary.id) }
        }, by: \.0)
        return await withTaskGroup(of: [String: String].self) { group in
            for (alias, values) in grouped {
                guard let host = remoteHosts[alias] else { continue }
                let sessionIDs = values.map(\.1)
                let runner = host.commandRunner
                let executable = host.host.grokExecutablePath
                group.addTask {
                    GrokConversationExcerptLoader.remoteExcerpts(
                        for: sessionIDs,
                        executablePath: executable,
                        runner: runner
                    )
                }
            }
            var result: [String: String] = [:]
            for await excerpts in group {
                result.merge(excerpts) { current, _ in current }
            }
            return result
        }
    }

    func isAgenticConversationPinned(_ sessionID: String) -> Bool {
        metadata.isSessionPinned(sessionID)
    }

    func agenticConversationSummary(
        _ sessionID: String
    ) -> (title: String, archived: Bool)? {
        guard let summary = summaries.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return (
            summary.title,
            metadata.isSessionArchived(sessionID)
                || metadata.isProjectArchived(summary.projectID)
        )
    }

    func applyAgenticFinderMatch(_ match: AgenticFinderMatch) {
        guard let summary = summaries.first(where: {
            $0.id == match.sessionID
        }) else {
            return
        }
        let plan = AgenticFinderActionPlan.resolve(
            match: match,
            summary: summary,
            metadata: metadata
        )
        schedulePersistence { coordinator in
            let persisted = await coordinator.persist { document in
                plan.apply(to: &document)
            }
            if persisted, plan.shouldOpen {
                coordinator.selectConversation(plan.sessionID)
            }
        }
    }

    var summaries: [SessionSummary] {
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

    func session(_ sessionID: String) -> GrokPersistedSession? {
        persistedSessions.first { $0.id.rawValue == sessionID }
    }

    /// Used when Git could not resolve a session's repository. A remote
    /// session keeps its host so it can never land inside a local project that
    /// happens to share the same path.
    private func fallbackProjectID(
        for session: GrokPersistedSession
    ) -> String {
        let value = session.projectDirectory ?? session.cwd ?? NSHomeDirectory()
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        guard let alias = hostAliasBySessionID[session.id.rawValue] else {
            return directory
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        return ProjectIdentity(
            target: .remote(alias),
            commonDirectory: directory
        ).rawValue
    }

    func mainCheckout(for projectID: String) -> String {
        mainCheckoutByProjectID[projectID]
            ?? metadata.projectCheckoutPath(projectID)
            ?? {
            // A remote project ID carries its host, so the fallback uses the
            // repository path on the computer that owns it.
            let projectURL = URL(
                fileURLWithPath: ProjectIdentity(rawValue: projectID).path,
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

    func rebuildCatalog() {
        guard metadata.remoteProjectsHidden else {
            catalog = SessionCatalog.build(
                sessions: summaries,
                metadata: metadata
            )
            telegram.scheduleCatalogSync()
            return
        }
        // Hiding is presentation only: the computers stay registered, their
        // runtimes keep running, and nothing is archived.
        var visibleMetadata = metadata
        visibleMetadata.projects = metadata.projects.filter {
            !ProjectIdentity(rawValue: $0.key).target.isRemote
        }
        catalog = SessionCatalog.build(
            sessions: summaries.filter {
                !ProjectIdentity(rawValue: $0.projectID).target.isRemote
            },
            metadata: visibleMetadata
        )
        telegram.scheduleCatalogSync()
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
        // Land any debounced tab metadata before draining, so a quit or
        // restart never drops the pending write.
        conversationTabsPersistenceTask?.cancel()
        conversationTabsPersistenceTask = nil
        flushPendingConversationTabs()
        while let task = persistenceTail {
            await task.value
            if persistenceTasks.isEmpty {
                persistenceTail = nil
            }
        }
    }

    @discardableResult
    func persist(
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
        pendingConversationTabs[sessionID] = tabs
        guard conversationTabsPersistenceTask == nil else { return }
        conversationTabsPersistenceTask = Task { [weak self] in
            try? await Task.sleep(
                for: Self.conversationTabsPersistenceDelay
            )
            guard !Task.isCancelled, let self else { return }
            self.conversationTabsPersistenceTask = nil
            self.flushPendingConversationTabs()
        }
    }

    private func flushPendingConversationTabs() {
        let pending = pendingConversationTabs
        guard !pending.isEmpty else { return }
        pendingConversationTabs.removeAll()
        schedulePersistence { coordinator in
            // Tab metadata never feeds the catalog, so skip the rebuild and
            // the sidebar re-render it triggers.
            await coordinator.persist({ document in
                for (sessionID, tabs) in pending {
                    document.setConversationTabs(sessionID, tabs: tabs)
                }
            }, rebuildCatalog: false)
        }
    }

    private func isCurrent(
        _ control: GrokControlClient,
        generation: Int
    ) -> Bool {
        guard lifecycleGeneration == generation else { return false }
        if controlClient === control { return true }
        return remoteHosts.values.contains { $0.control === control }
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
                        self.localRoster.removeValue(forKey: removed.rawValue)
                    }
                    for entry in change.upserted {
                        self.localRoster[entry.id.rawValue] = entry
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
                    self.mergeCatalogState()
                    self.reconcileRuntimeActivity()
                case .subagentLifecycle(let observation):
                    self.reconcileSubagentLifecycle(observation)
                    self.forwardSubagentToTelegram(observation)
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
        let detached = detachRuntimeState(remoteHostEvent: .restart)
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

        let reason: ConversationAttentionReason
        switch ConversationAttention.transition(
            from: previous,
            to: current
        ) {
        case .unchanged:
            return
        case .settled:
            pendingAttention.removeValue(forKey: sessionID)
            return
        case .raised(let raisedReason):
            reason = raisedReason
        }

        guard !isWatching(sessionID) else { return }
        guard pendingAttention[sessionID] != reason else { return }
        pendingAttention[sessionID] = reason

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
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let generation = lifecycleGeneration
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.lifecycleGeneration,
                      let sessionID = self.selectedSessionID else {
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
                    await self.refreshRemoteHosts()
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
                  let controlClient = self.controlClient(
                      forSession: rootSessionID
                  ) else {
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
                self.applyRosterEntry(entry, sessionID: rootSessionID)
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
              let controlClient = controlClient(forSession: rootSessionID),
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
              let controlClient = controlClient(forSession: rootSessionID)
        else {
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

    private func forwardSubagentToTelegram(
        _ observation: GrokSubagentLifecycleObservation
    ) {
        let rootSessionID = hookCoordinator?.rootSessionID(
            for: observation.childSessionID
        )
            ?? hookCoordinator?.rootSessionID(
                for: observation.parentSessionID
            )
            ?? observation.parentSessionID
        telegram.reportSubagent(
            rootSessionID: rootSessionID,
            observation: observation
        )
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
              let controlClient = controlClient(forSession: sessionID)
        else {
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
                    self.applyMaterializedSession(
                        persisted,
                        sessionID: sessionID,
                        locations: locations
                    )
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
            case TerminalControlContract.Method.create:
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
                        TerminalControlContract.Field.tabID:
                            .string(tab.id),
                        TerminalControlContract.Field.capability:
                            .string(tab.capability),
                        TerminalControlContract.Field.state:
                            .string(tab.state.wireValue),
                    ])
                )

            case TerminalControlContract.Method.execute:
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
                        TerminalControlContract.Field.tabID:
                            .string(tab.id),
                        TerminalControlContract.Field.commandID:
                            .string(commandID),
                        TerminalControlContract.Field.state:
                            .string(tab.state.wireValue),
                    ])
                )

            case TerminalControlContract.Method.read:
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
                        TerminalControlContract.Field.text:
                            .string(result.text),
                        TerminalControlContract.Field.cursor:
                            .string(result.cursor),
                        TerminalControlContract.Field.reset:
                            .bool(result.reset),
                        TerminalControlContract.Field.truncated:
                            .bool(result.truncated),
                    ])
                )

            case TerminalControlContract.Method.write:
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

            case TerminalControlContract.Method.key:
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

            case TerminalControlContract.Method.interrupt:
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                try tab.sendKey(.interrupt)
                return .success()

            case TerminalControlContract.Method.status:
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                return .success(tab.statusPayload)

            case TerminalControlContract.Method.close:
                let fields = try managedTerminalFields(request)
                try runtimeManager.closeManagedTab(
                    tabID: fields.tabID,
                    capability: fields.capability
                )
                return .success(
                    .object([
                        TerminalControlContract.Field.closed:
                            .bool(true)
                    ])
                )

            case TerminalControlContract.Method.shellReady:
                let tab = try managedTerminal(
                    request,
                    runtimeManager: runtimeManager
                )
                try tab.markShellReady()
                return .success(tab.statusPayload)

            case TerminalControlContract.Method.fetchCommand:
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
                        TerminalControlContract.Field.command:
                            .string(
                                try tab.command(
                                    commandID: commandID
                                )
                            ),
                    ])
                )

            case TerminalControlContract.Method.commandFinished:
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

/// Explicit per-host connection intent. Absence of a runtime is not enough to
/// decide whether a registered computer should be probed again.
enum RemoteHostConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case stopped
    case failed
}

enum RemoteHostConnectionEvent: Equatable, Sendable {
    case connect
    case succeed
    case fail
    case stop
    case retry
    case restart
    case shutdown
    case remove
}

struct RemoteHostConnectionArtifacts: Equatable, Sendable {
    var state: RemoteHostConnectionState?
    var hasRuntime: Bool
    var hasEventTask: Bool

    static let empty = RemoteHostConnectionArtifacts(
        state: nil,
        hasRuntime: false,
        hasEventTask: false
    )
}

enum RemoteHostConnectionMachine {
    /// Concurrent SSH probes share a bound so a few dead computers cannot
    /// serialize every other host behind their full timeout.
    static let connectionConcurrencyLimit = 4

    static func apply(
        _ state: RemoteHostConnectionState?,
        _ event: RemoteHostConnectionEvent
    ) -> RemoteHostConnectionState? {
        switch (state, event) {
        case (_, .remove), (_, .shutdown):
            return nil
        case (.stopped, .restart):
            return .stopped
        case (_, .restart):
            return nil
        case (.stopped, .connect),
             (.stopped, .succeed),
             (.stopped, .fail):
            return .stopped
        case (_, .stop):
            return .stopped
        case (.connecting, .succeed):
            return .connected
        case (.connecting, .fail), (.connected, .fail):
            return .failed
        case (_, .retry), (_, .connect):
            return .connecting
        case (.connected, .succeed):
            return .connected
        default:
            return state
        }
    }

    static func shouldAutoReconnect(
        _ state: RemoteHostConnectionState?
    ) -> Bool {
        switch state {
        case .none, .failed:
            return true
        case .connecting, .connected, .stopped:
            return false
        }
    }

    static func aliasesEligibleForAutoConnect(
        registered: [RemoteHostAlias],
        states: [RemoteHostAlias: RemoteHostConnectionState]
    ) -> [RemoteHostAlias] {
        registered.filter { shouldAutoReconnect(states[$0]) }
    }

    static func artifacts(
        after event: RemoteHostConnectionEvent,
        current: RemoteHostConnectionState?
    ) -> RemoteHostConnectionArtifacts {
        let state = apply(current, event)
        let published = state == .connected
        return RemoteHostConnectionArtifacts(
            state: state,
            hasRuntime: published,
            hasEventTask: published
        )
    }
}

/// Local refresh input plus each host's own catalog. The merged maps are
/// derived here; a refresh must never write the previous merge back into
/// `local`.
enum CatalogStateMerge {
    struct Slice: Equatable {
        var sessions: [GrokPersistedSession] = []
        var roster: [String: GrokRosterEntry] = [:]
        var projectIDs: [String: String] = [:]
        var checkouts: [String: String] = [:]
    }

    static func merge(local: Slice, remotes: [Slice]) -> Slice {
        var result = local
        for remote in remotes {
            result.sessions += remote.sessions
            result.roster.merge(
                remote.roster,
                uniquingKeysWith: { _, next in next }
            )
            result.projectIDs.merge(
                remote.projectIDs,
                uniquingKeysWith: { _, next in next }
            )
            result.checkouts.merge(
                remote.checkouts,
                uniquingKeysWith: { _, next in next }
            )
        }
        return result
    }
}

enum AvailableRemoteHostAliases {
    static func fromCache(
        _ cached: [RemoteHostAlias],
        registered: [RemoteHostAlias]
    ) -> [RemoteHostAlias] {
        let registeredIDs = Set(registered.map(\.rawValue))
        return cached.filter { !registeredIDs.contains($0.rawValue) }
    }
}

/// A detached coordinator task may mutate state only while its captured
/// lifecycle generation is still current and the task has not been cancelled.
enum CoordinatorMutationGate {
    static func allowsMutation(
        capturedGeneration: Int,
        currentGeneration: Int,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && capturedGeneration == currentGeneration
    }
}
