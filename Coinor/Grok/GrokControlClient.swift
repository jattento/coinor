import Foundation

/// Something the control connection reported on its own initiative.
enum GrokPromptUpdate: Sendable {
    case draft(String)
    case status(String)
    case permission(GrokPermissionPrompt)
}

struct GrokPermissionPrompt: Sendable, Equatable {
    var sessionID: String
    var title: String
    var options: [GrokPermissionOption]
}

struct GrokPermissionOption: Sendable, Equatable {
    var id: String
    var title: String
}

enum GrokControlEvent: Sendable {
    case rosterChanged(GrokRosterChange)
    case subagentLifecycle(GrokSubagentLifecycleObservation)
    case workflowUpdated(GrokWorkflowRun)
    case notification(method: String, params: GrokJSONValue)
    case terminated(GrokControlError)
}

/// Coinor's long-lived ACP client for the Grok control plane.
///
/// It runs one `grok --leader-socket <coinor-socket> agent --leader stdio`
/// child for the lifetime of the application and uses it for the session
/// catalog, the live roster, and conversation renames. It never renders,
/// drives, or parses a terminal: panes attach to the same leader on their own.
actor GrokControlClient {
    struct Configuration: Sendable {
        static let supportedProtocolVersion = 1
        static let fallbackClientVersion = "0.0.0"

        var requestTimeout: Duration = .seconds(30)
        var executableVersionTimeout: Duration = .seconds(5)
        var pageSize = 100
        /// A page walk over a few thousand sessions ends long before this; the
        /// bound only stops a cursor that never terminates.
        var maximumPages = 200
        var diagnosticsCapacity = 8 * 1024
        var clientType = "coinor"
        var clientVersion = Self.currentClientVersion()
        var preferredAuthMethodIDs = ["cached_token", "grok.com", "xai.api_key"]

        static func resolveClientVersion(
            shortVersion: String?,
            buildVersion: String?
        ) -> String {
            for candidate in [shortVersion, buildVersion] {
                let value = candidate?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value, !value.isEmpty {
                    return value
                }
            }
            return fallbackClientVersion
        }

        private static func currentClientVersion(
            bundle: Bundle = .main
        ) -> String {
            resolveClientVersion(
                shortVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                buildVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
            )
        }
    }

    private enum State {
        case idle
        case running
        case finished(GrokControlError)
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<GrokJSONValue, any Error>
    }

    private let launch: GrokControlLaunch
    private let configuration: Configuration
    private let makeTransport: @Sendable (GrokControlLaunch) -> any GrokTransport
    private let probeExecutableVersion:
        @Sendable (GrokControlLaunch, Duration) async throws -> String

    private var state: State = .idle
    private var transport: (any GrokTransport)?
    private var readerTask: Task<Void, Never>?
    private var decoder = GrokFrameDecoder()
    private var pending: [String: PendingRequest] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<GrokControlEvent>.Continuation] = [:]
    private var requestCounter = 0
    private var diagnostics = Data()

    private(set) var handshake: GrokAgentHandshake?
    private(set) var executableVersion: String?
    private var promptAccumulators: [String: PromptAccumulation] = [:]
    private var pendingPermissions: [String: PendingPermission] = [:]
    private var inFlightPromptRequestIDs: [String: String] = [:]
    private var promptFinishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    var inFlightRequestCount: Int {
        pending.count
    }

    var scheduledTimeoutCount: Int {
        timeouts.count
    }

    init(
        launch: GrokControlLaunch,
        configuration: Configuration = Configuration(),
        transport: @escaping @Sendable (GrokControlLaunch) -> any GrokTransport = {
            GrokSubprocessTransport(launch: $0)
        },
        executableVersionProbe:
            @escaping @Sendable (GrokControlLaunch, Duration) async throws -> String = {
                launch,
                timeout in
                try await GrokExecutableVersionProbe().run(
                    launch: launch,
                    timeout: timeout
                )
        }
    ) {
        self.launch = launch
        self.configuration = configuration
        makeTransport = transport
        probeExecutableVersion = executableVersionProbe
    }

    // MARK: - Lifecycle

    @discardableResult
    func connect() async throws -> GrokAgentHandshake {
        guard case .idle = state else {
            throw GrokControlError.alreadyConnected
        }
        let executableVersion = try await probeExecutableVersion(
            launch,
            configuration.executableVersionTimeout
        )
        let transport = makeTransport(launch)
        let stream = try transport.start()
        self.transport = transport
        state = .running
        readerTask = Task { [weak self] in
            for await event in stream {
                await self?.receive(event)
            }
        }

        do {
            let handshake = try await performHandshake()
            try await probeRequiredExtensions()
            self.executableVersion = executableVersion
            self.handshake = handshake
            return handshake
        } catch {
            await shutdown()
            throw error
        }
    }

    /// Stops the child process and releases every waiter. Safe to call twice.
    func shutdown() async {
        readerTask?.cancel()
        readerTask = nil
        await transport?.shutdown()
        transport = nil
        if case .finished = state {} else {
            state = .finished(.notConnected)
        }
        failAllPending(with: .notConnected)
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    /// A private stream of control-plane events. Every caller gets its own, so
    /// the sidebar, the runtime manager, and diagnostics can all listen.
    func events() -> AsyncStream<GrokControlEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
            if case let .finished(error) = state {
                continuation.yield(.terminated(error))
                continuation.finish()
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Requests

    /// Every persisted Grok session, paged to exhaustion.
    ///
    /// The `kind` facet is restricted to local build sessions: Coinor lists
    /// conversations that live in a checkout on this machine, and the filter
    /// also keeps Grok from calling its remote conversation backend.
    func listPersistedSessions(inDirectory directory: String? = nil) async throws -> [GrokPersistedSession] {
        var sessions: [GrokPersistedSession] = []
        var seen: Set<GrokSessionID> = []
        var cursor: String?
        var page = 0

        while page < configuration.maximumPages {
            page += 1
            var params: [String: GrokJSONValue] = [
                "limit": .int(configuration.pageSize),
                "_meta": ["x.ai/facetFilters": ["kind": ["build"]]],
            ]
            if let directory {
                params["cwd"] = .string(directory)
            }
            if let cursor {
                params["cursor"] = .string(cursor)
            }

            let result = try await callExtension(GrokMethod.sessionList, params: .object(params))
            for row in try sessionRows(
                in: result,
                method: GrokMethod.sessionList
            ) {
                let session = try GrokPersistedSession(raw: row)
                // The local lane re-scans an overlapping window per page, so a
                // row can legitimately appear twice across a page walk.
                guard seen.insert(session.id).inserted else { continue }
                sessions.append(session)
            }

            guard let next = try nextCatalogCursor(in: result), !next.isEmpty else {
                return sessions
            }
            guard next != cursor else {
                throw GrokControlError.paginationStalled(cursor: next)
            }
            cursor = next
        }
        throw GrokControlError.paginationStalled(cursor: cursor ?? "")
    }

    /// The live roster: resident sessions plus recently touched dormant ones.
    func listRoster() async throws -> [GrokRosterEntry] {
        let result = try await callExtension(GrokMethod.sessionsList, params: .object([:]))
        var entries: [GrokRosterEntry] = []
        var seen: Set<GrokSessionID> = []
        for row in try sessionRows(
            in: result,
            method: GrokMethod.sessionsList
        ) {
            let entry = try GrokRosterEntry(
                raw: row,
                method: GrokMethod.sessionsList
            )
            guard seen.insert(entry.id).inserted else {
                throw GrokControlError.malformedPayload(
                    method: GrokMethod.sessionsList,
                    detail: "duplicate roster sessionId \(entry.id.rawValue)"
                )
            }
            entries.append(entry)
        }
        return entries
    }

    func listWorkflows(sessionID: String) async throws -> [GrokWorkflowDefinition] {
        let result = try await callExtension(
            GrokMethod.workflowsList,
            params: ["sessionId": .string(sessionID)]
        )
        guard let workflows = result.objectValue?["workflows"],
              case let .array(rows) = workflows else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.workflowsList,
                detail: "workflows must be an array"
            )
        }
        return try rows.map(GrokWorkflowDefinition.init(raw:))
    }

    func snapshotWorkflows(sessionID: String) async throws -> [GrokWorkflowRun] {
        let result = try await callExtension(
            GrokMethod.workflowsSnapshot,
            params: ["sessionId": .string(sessionID)]
        )
        guard let runs = result.objectValue?["runs"],
              case let .array(rows) = runs else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.workflowsSnapshot,
                detail: "runs must be an array"
            )
        }
        return try rows.map {
            try GrokWorkflowRun.parseSnapshotRow(sessionID: sessionID, raw: $0)
        }
    }

    func launchWorkflow(
        sessionID: String,
        name: String,
        args: GrokJSONValue?,
        agentBudget: Int?
    ) async throws -> GrokWorkflowLaunchResult {
        try validateAgentBudget(agentBudget, method: GrokMethod.workflowsLaunch)
        var params: [String: GrokJSONValue] = [
            "sessionId": .string(sessionID),
            "name": .string(name),
        ]
        if let args {
            params["args"] = args
        }
        if let agentBudget {
            params["agentBudget"] = .int(agentBudget)
        }
        let result = try await callExtension(
            GrokMethod.workflowsLaunch,
            params: .object(params)
        )
        guard let runID = result["runId"]?.stringValue, !runID.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.workflowsLaunch,
                detail: "runId must be a nonempty string"
            )
        }
        guard let resultName = result["name"]?.stringValue, !resultName.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.workflowsLaunch,
                detail: "name must be a nonempty string"
            )
        }
        return GrokWorkflowLaunchResult(runID: runID, name: resultName)
    }

    func controlWorkflow(
        sessionID: String,
        runID: String,
        operation: GrokWorkflowControlOperation,
        agentBudget: Int?
    ) async throws -> GrokWorkflowRun {
        try validateAgentBudget(agentBudget, method: GrokMethod.workflowsControl)
        var params: [String: GrokJSONValue] = [
            "sessionId": .string(sessionID),
            "runId": .string(runID),
            "operation": .string(operation.rawValue),
        ]
        if let agentBudget {
            params["agentBudget"] = .int(agentBudget)
        }
        let result = try await callExtension(
            GrokMethod.workflowsControl,
            params: .object(params)
        )
        guard let run = result.objectValue?["run"], case .object = run else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.workflowsControl,
                detail: "run must be an object"
            )
        }
        return try GrokWorkflowRun.parseSnapshotRow(sessionID: sessionID, raw: run)
    }

    private func validateAgentBudget(_ agentBudget: Int?, method: String) throws {
        guard let agentBudget else { return }
        guard (1 ... 1024).contains(agentBudget) else {
            throw GrokControlError.malformedPayload(
                method: method,
                detail: "agentBudget must be between 1 and 1024"
            )
        }
    }

    private func sessionRows(
        in result: GrokJSONValue,
        method: String
    ) throws -> [GrokJSONValue] {
        guard let sessions = result.objectValue?["sessions"],
              case let .array(rows) = sessions else {
            throw GrokControlError.malformedPayload(
                method: method,
                detail: "sessions must be an array"
            )
        }
        return rows
    }

    private func nextCatalogCursor(
        in result: GrokJSONValue
    ) throws -> String? {
        guard let cursor = result.objectValue?["nextCursor"] else {
            return nil
        }
        switch cursor {
        case .null:
            return nil
        case let .string(value):
            return value
        default:
            throw GrokControlError.malformedPayload(
                method: GrokMethod.sessionList,
                detail: "nextCursor must be a string or null"
            )
        }
    }

    /// Renames a root conversation. Grok owns the title, so this is the only
    /// way a Coinor rename becomes visible outside Coinor.
    func rename(
        _ session: GrokSessionID,
        to title: String,
        inDirectory directory: String? = nil
    ) async throws {
        var params: [String: GrokJSONValue] = [
            "sessionId": .string(session.rawValue),
            "title": .string(title),
        ]
        if let directory {
            params["cwd"] = .string(directory)
        }
        _ = try await callExtension(GrokMethod.sessionRename, params: .object(params))
    }

    /// Creates a durable Grok session that this control client can drive.
    func createSession(id: GrokSessionID, cwd: String) async throws {
        _ = try await call(
            GrokMethod.sessionNew,
            params: [
                "cwd": .string(cwd),
                "mcpServers": .array([]),
                "_meta": ["sessionId": .string(id.rawValue)],
            ]
        )
    }

    /// Makes an existing session current on this control connection.
    func loadSession(_ id: GrokSessionID, cwd: String) async throws {
        _ = try await call(
            GrokMethod.sessionLoad,
            params: [
                "sessionId": .string(id.rawValue),
                "cwd": .string(cwd),
                "mcpServers": .array([]),
            ]
        )
    }

    /// Sends one user turn and returns the concatenated assistant text.
    func prompt(
        sessionID: GrokSessionID,
        text: String,
        onUpdate: (@Sendable (GrokPromptUpdate) -> Void)? = nil
    ) async throws -> String {
        try await prompt(
            sessionID: sessionID,
            blocks: [
                [
                    "type": "text",
                    "text": .string(text),
                ],
            ],
            onUpdate: onUpdate
        )
    }

    func prompt(
        sessionID: GrokSessionID,
        blocks: [GrokJSONValue],
        onUpdate: (@Sendable (GrokPromptUpdate) -> Void)? = nil
    ) async throws -> String {
        let key = sessionID.rawValue
        await interruptExistingPrompt(key)
        let accumulation = PromptAccumulation(onUpdate: onUpdate)
        promptAccumulators[key] = accumulation
        defer { finishPrompt(sessionID: key, accumulation: accumulation) }
        _ = try await send(
            wireMethod: GrokMethod.sessionPrompt,
            method: GrokMethod.sessionPrompt,
            params: [
                "sessionId": .string(sessionID.rawValue),
                "prompt": .array(blocks),
            ],
            timeout: .seconds(1_800),
            promptSessionID: key
        )
        return accumulation.text
    }

    func answerPermission(sessionID: String, optionID: String?) {
        guard let pending = pendingPermissions.removeValue(forKey: sessionID) else {
            return
        }
        let result: GrokJSONValue
        if let optionID {
            result = [
                "outcome": [
                    "outcome": "selected",
                    "optionId": .string(optionID),
                ],
            ]
        } else {
            result = ["outcome": ["outcome": "cancelled"]]
        }
        respond(to: pending.requestID, result: result)
    }

    /// Replays the persisted lifecycle of a root session in storage order.
    ///
    /// The caller waits until the interactive TUI is resident before invoking
    /// this method so this observer never becomes the session driver.
    func listSubagentLifecycle(
        sessionID: String,
        cwd: String,
        parentSessionID: String? = nil
    ) async throws -> [GrokSubagentLifecycleObservation] {
        var observations: [GrokSubagentLifecycleObservation] = []
        var offset = 0
        var page = 0

        while page < configuration.maximumPages {
            page += 1
            let result = try await callExtension(
                GrokMethod.sessionUpdates,
                params: [
                    "sessionId": .string(sessionID),
                    "cwd": .string(cwd),
                    "offset": .int(offset),
                    "limit": .int(configuration.pageSize),
                ]
            )
            guard let updates = result["updates"]?.arrayValue else {
                throw GrokControlError.malformedPayload(
                    method: GrokMethod.sessionUpdates,
                    detail: "updates must be an array"
                )
            }
            for update in updates {
                if let observation = GrokSubagentLifecycleObservation
                    .parsePersistedEnvelope(update) {
                    observations.append(observation)
                    continue
                }
                guard let parentSessionID,
                      let termination = PersistedSessionTermination.detect(
                          in: update
                      ) else {
                    continue
                }
                observations.append(
                    GrokSubagentLifecycleObservation(
                        kind: .finished,
                        childSessionID: sessionID,
                        parentSessionID: parentSessionID,
                        description: nil,
                        subagentType: nil,
                        status: termination == .cancelled
                            ? "cancelled" : "failed",
                        timestamp: update["timestamp"]?.stringValue
                    )
                )
            }

            let hasMore = try hasMore(in: result)
            guard hasMore else {
                return observations
            }
            guard !updates.isEmpty else {
                throw GrokControlError.paginationStalled(cursor: String(offset))
            }
            offset += updates.count
        }
        throw GrokControlError.paginationStalled(cursor: String(offset))
    }

    /// Grok answers `x.ai/session/updates` with `"hasMore": true|false` on
    /// every page, so a present-but-wrong-typed value is a compatibility
    /// error rather than a silent last-page.
    private func hasMore(in result: GrokJSONValue) throws -> Bool {
        guard let hasMore = result["hasMore"]?.boolValue else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.sessionUpdates,
                detail: "hasMore must be a bool"
            )
        }
        return hasMore
    }

    // MARK: - Handshake

    private func performHandshake() async throws -> GrokAgentHandshake {
        let initializeParams: GrokJSONValue = [
            "protocolVersion": .int(Configuration.supportedProtocolVersion),
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
            "_meta": [
                "clientType": .string(configuration.clientType),
                "clientVersion": .string(configuration.clientVersion),
                "startupHints": [
                    "nonInteractive": true,
                    "skipGitStatus": true,
                    "skipProjectLayout": true,
                ],
            ],
        ]
        let result = try await call(GrokMethod.initialize, params: initializeParams)

        guard result["_meta"]?["grokShell"]?.boolValue == true else {
            throw GrokControlError.incompatibleAgent(
                "the agent at \(launch.executable.path) did not identify itself as a Grok shell"
            )
        }
        guard result["protocolVersion"]?.intValue
                == Configuration.supportedProtocolVersion
        else {
            let reported = result["protocolVersion"]?.intValue
                .map(String.init) ?? "missing"
            throw GrokControlError.incompatibleAgent(
                "ACP protocol version \(reported) was reported; "
                    + "Conan Code requires version "
                    + "\(Configuration.supportedProtocolVersion)"
            )
        }

        let authMethodIDs = (result["authMethods"]?.arrayValue ?? [])
            .compactMap { $0["id"]?.stringValue }
        let defaultAuthMethodID = result["_meta"]?["defaultAuthMethodId"]?.stringValue

        return GrokAgentHandshake(
            protocolVersion: result["protocolVersion"]?.intValue,
            agentVersion: result["_meta"]?["agentVersion"]?.stringValue,
            agentID: result["_meta"]?["agentId"]?.stringValue,
            authMethodIDs: authMethodIDs,
            defaultAuthMethodID: defaultAuthMethodID,
            authentication: await authenticate(
                methodIDs: authMethodIDs,
                preferred: defaultAuthMethodID
            ),
            raw: result
        )
    }

    /// Proves the required non-catalog extension surface exists without
    /// loading or mutating any real session.
    ///
    /// `x.ai/session/list` and `x.ai/sessions/list` are exercised by the
    /// startup catalog refresh before Coinor becomes ready. Probing them here
    /// would make Grok scan the persisted catalog twice on every launch.
    /// Grok creates UUIDv7 session IDs, so the nil UUID is a reserved sentinel
    /// that cannot identify a persisted Grok session.
    private func probeRequiredExtensions() async throws {
        let missingSessionID = "00000000-0000-0000-0000-000000000000"
        let probes: [(String, GrokJSONValue, Bool)] = [
            (
                GrokMethod.sessionUpdates,
                [
                    "sessionId": .string(missingSessionID),
                    "cwd": .string(launch.workingDirectory.path),
                    "offset": 0,
                    "limit": 1,
                ],
                true
            ),
            (
                GrokMethod.sessionRename,
                [
                    "sessionId": .string(missingSessionID),
                    "title": "Conan Code compatibility probe",
                    "cwd": .string(launch.workingDirectory.path),
                ],
                true
            ),
        ]
        var failures: [String] = []

        for (method, params, acceptsMissingSession) in probes {
            do {
                _ = try await callExtension(method, params: params)
            } catch let error as GrokControlError
                where acceptsMissingSession
                    && error.provesExtensionExistsForMissingSession(method: method) {
                continue
            } catch {
                failures.append(
                    "\(method): "
                        + ((error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription)
                )
            }
        }

        guard failures.isEmpty else {
            throw GrokControlError.incompatibleAgent(
                "required extension checks failed: "
                    + failures.joined(separator: "; ")
            )
        }
    }

    /// Listing and renaming local sessions do not need credentials, so a
    /// failure here is reported to the UI instead of failing startup.
    private func authenticate(methodIDs: [String], preferred: String?) async -> GrokAuthentication {
        let candidates = [preferred].compactMap { $0 } + configuration.preferredAuthMethodIDs
        guard let methodID = candidates.first(where: methodIDs.contains) ?? methodIDs.first else {
            return .unavailable
        }
        do {
            _ = try await call(
                GrokMethod.authenticate,
                params: ["methodId": .string(methodID), "_meta": ["headless": true]]
            )
            return .succeeded(methodID: methodID)
        } catch {
            return .failed(
                methodID: methodID,
                message: (error as? GrokControlError)?.errorDescription ?? "\(error)"
            )
        }
    }

    // MARK: - Transport plumbing

    private func call(_ method: String, params: GrokJSONValue) async throws -> GrokJSONValue {
        try await send(wireMethod: method, method: method, params: params)
    }

    /// Sends an `x.ai/*` extension request and unwraps its result envelope.
    private func callExtension(_ method: String, params: GrokJSONValue) async throws -> GrokJSONValue {
        let response = try await send(
            wireMethod: GrokMethod.wireName(forExtension: method),
            method: method,
            params: params
        )
        if let failure = response["error"] {
            throw GrokControlError.extensionFailed(
                method: method,
                message: failure.stringValue
                    ?? failure["message"]?.stringValue
                    ?? String(describing: failure)
            )
        }
        // Most extensions answer `{ result, error? }`; a few answer with the
        // payload itself, which Grok's own client also accepts unwrapped.
        return response["result"] ?? response
    }

    private func interruptExistingPrompt(_ sessionID: String) async {
        if let requestID = inFlightPromptRequestIDs[sessionID] {
            cancel(id: requestID)
        }
        while promptAccumulators[sessionID] != nil {
            await withCheckedContinuation { continuation in
                promptFinishWaiters[sessionID, default: []].append(continuation)
            }
        }
    }

    private func finishPrompt(
        sessionID: String,
        accumulation: PromptAccumulation
    ) {
        if promptAccumulators[sessionID] === accumulation {
            promptAccumulators.removeValue(forKey: sessionID)
            pendingPermissions.removeValue(forKey: sessionID)
            inFlightPromptRequestIDs.removeValue(forKey: sessionID)
        }
        let waiters = promptFinishWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func send(
        wireMethod: String,
        method: String,
        params: GrokJSONValue,
        timeout: Duration? = nil,
        promptSessionID: String? = nil
    ) async throws -> GrokJSONValue {
        switch state {
        case .idle:
            throw GrokControlError.notConnected
        case let .finished(error):
            throw error
        case .running:
            break
        }
        guard let transport else {
            throw GrokControlError.notConnected
        }

        requestCounter += 1
        let id = "\(configuration.clientType)-\(requestCounter)"
        if let promptSessionID {
            inFlightPromptRequestIDs[promptSessionID] = id
        }
        let payload = try GrokRPC.request(id: id, method: wireMethod, params: params).encoded()
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(
                    method: method,
                    continuation: continuation
                )
                startTimeout(
                    for: id,
                    method: method,
                    timeout: timeout ?? configuration.requestTimeout
                )
                do {
                    try transport.send(GrokFraming.encode(payload))
                } catch {
                    timeouts.removeValue(forKey: id)?.cancel()
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    private func startTimeout(for id: String, method: String, timeout: Duration) {
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(
                id: id,
                with: .requestTimedOut(
                    method: method,
                    seconds: Double(timeout.components.seconds)
                )
            )
        }
    }

    private func fail(id: String, with error: GrokControlError) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: error)
    }

    private func cancel(id: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CancellationError())
    }

    private func failAllPending(with error: GrokControlError) {
        let requests = pending
        pending.removeAll()
        for task in timeouts.values {
            task.cancel()
        }
        timeouts.removeAll()
        for request in requests.values {
            request.continuation.resume(throwing: error)
        }
    }

    private func receive(_ event: GrokTransportEvent) {
        switch event {
        case let .output(data):
            do {
                for frame in try decoder.append(data) {
                    handle(frame: frame)
                }
            } catch let error as GrokControlError {
                finish(with: error)
            } catch {
                finish(with: .malformedFrame("\(error)"))
            }
        case let .diagnostic(data):
            record(diagnostic: data)
        case let .ended(status):
            finish(with: .transportEnded(status: status, diagnostics: diagnosticsText()))
        }
    }

    private func handle(frame: Data) {
        guard let message = GrokRPC.classify(frame) else {
            // Not a JSON-RPC message. Keep it for the exit diagnostic rather
            // than tearing down a connection that is otherwise healthy.
            record(diagnostic: frame)
            return
        }
        switch message {
        case let .response(id, result, error):
            complete(id: id, result: result, error: error)
        case let .notification(method, params):
            publish(method: method, params: params)
        case let .request(id, wireMethod, params):
            // Shared interactions stay ignored unless this client is driving
            // the session with session/prompt, so the Ghostty TUI can still
            // answer when it is the driver.
            let normalized = GrokMethod.normalize(
                wireMethod: wireMethod,
                params: params
            )
            if GrokMethod.isSharedInteraction(normalized.method) {
                handleSharedInteraction(
                    id: id,
                    method: normalized.method,
                    params: normalized.params
                )
                return
            }
            reject(id: id, method: normalized.method)
        }
    }

    private func handleSharedInteraction(
        id: GrokJSONValue,
        method: String,
        params: GrokJSONValue
    ) {
        guard method == GrokMethod.requestPermission else {
            return
        }
        let sessionID = params["sessionId"]?.stringValue ?? ""
        guard promptAccumulators[sessionID] != nil else {
            return
        }
        let options = (params["options"]?.arrayValue ?? []).compactMap {
            option -> GrokPermissionOption? in
            guard let optionID = option["optionId"]?.stringValue
                    ?? option["option_id"]?.stringValue else {
                return nil
            }
            return GrokPermissionOption(
                id: optionID,
                title: option["name"]?.stringValue ?? optionID
            )
        }
        let title = params["toolCall"]?["title"]?.stringValue
            ?? params["tool_call"]?["title"]?.stringValue
            ?? "Grok needs permission."
        pendingPermissions[sessionID] = PendingPermission(requestID: id)
        promptAccumulators[sessionID]?.permission(
            GrokPermissionPrompt(
                sessionID: sessionID,
                title: title,
                options: options
            )
        )
    }

    private func respond(to id: GrokJSONValue, result: GrokJSONValue) {
        guard let transport,
              let payload = try? GrokRPC.resultResponse(id: id, result: result)
                .encoded()
        else {
            return
        }
        try? transport.send(GrokFraming.encode(payload))
    }

    private func complete(id: String, result: GrokJSONValue?, error: GrokRPCError?) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let request = pending.removeValue(forKey: id) else { return }
        if let error {
            let structuredMessage = error.data?["message"]?.stringValue
            let failure: GrokControlError = error.code == GrokRPC.methodNotFoundCode
                ? .unsupportedMethod(request.method)
                : .requestFailed(
                    method: request.method,
                    code: error.code,
                    message: structuredMessage ?? error.message,
                    data: structuredMessage == nil
                        ? error.data.flatMap {
                            $0.stringValue ?? (try? $0.encoded()).map {
                                String(decoding: $0, as: UTF8.self)
                            }
                        }
                        : nil
                )
            request.continuation.resume(throwing: failure)
            return
        }
        request.continuation.resume(returning: result ?? .object([:]))
    }

    private func publish(method wireMethod: String, params: GrokJSONValue) {
        let normalized = GrokMethod.normalize(
            wireMethod: wireMethod,
            params: params
        )
        let method = normalized.method
        let params = normalized.params
        let event: GrokControlEvent
        if method == GrokMethod.sessionsChanged {
            guard let change = try? GrokRosterChange(params: params) else {
                return
            }
            event = .rosterChanged(change)
        } else if method == GrokMethod.sessionNotification
                    || method == GrokMethod.sessionUpdate,
                  let observation = GrokSubagentLifecycleObservation
                    .parseNotification(params: params) {
            event = .subagentLifecycle(observation)
        } else if let run = GrokWorkflowRun.parseNotification(
            method: method,
            params: params
        ) {
            event = .workflowUpdated(run)
        } else {
            event = .notification(method: method, params: params)
        }
        if let chunk = Self.agentMessageChunk(in: params) {
            promptAccumulators[chunk.sessionID]?.append(chunk.text)
        }
        if let status = Self.toolStatus(in: params) {
            promptAccumulators[status.sessionID]?.status(status.title)
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private static func toolStatus(
        in params: GrokJSONValue
    ) -> (sessionID: String, title: String)? {
        let sessionID = params["sessionId"]?.stringValue
        let update = params["update"] ?? params
        let kind = update["sessionUpdate"]?.stringValue
        guard kind == "tool_call" || kind == "tool_call_update",
              let sessionID else {
            return nil
        }
        let title = update["title"]?.stringValue
            ?? update["kind"]?.stringValue
            ?? "Working"
        return (sessionID, title)
    }

    private static func agentMessageChunk(
        in params: GrokJSONValue
    ) -> (sessionID: String, text: String)? {
        let sessionID = params["sessionId"]?.stringValue
        let update = params["update"] ?? params
        guard update["sessionUpdate"]?.stringValue == "agent_message_chunk",
              let sessionID,
              let text = update["content"]?["text"]?.stringValue,
              !text.isEmpty else {
            return nil
        }
        return (sessionID, text)
    }

    private func reject(id: GrokJSONValue, method: String) {
        guard let transport,
              let payload = try? GrokRPC.errorResponse(
                  id: id,
                  code: GrokRPC.methodNotFoundCode,
                  message: "Conan Code's control client does not serve \(method)"
              ).encoded()
        else { return }
        try? transport.send(GrokFraming.encode(payload))
    }

    private func finish(with error: GrokControlError) {
        if case .finished = state { return }
        state = .finished(error)
        transport?.terminate()
        transport = nil
        failAllPending(with: error)
        for continuation in subscribers.values {
            continuation.yield(.terminated(error))
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func record(diagnostic data: Data) {
        diagnostics.append(data)
        if diagnostics.count > configuration.diagnosticsCapacity {
            diagnostics.removeFirst(diagnostics.count - configuration.diagnosticsCapacity)
        }
    }

    private func diagnosticsText() -> String {
        String(decoding: diagnostics, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PendingPermission {
    let requestID: GrokJSONValue
}

private final class PromptAccumulation: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    private let onUpdate: (@Sendable (GrokPromptUpdate) -> Void)?

    init(onUpdate: (@Sendable (GrokPromptUpdate) -> Void)?) {
        self.onUpdate = onUpdate
    }

    func append(_ text: String) {
        let draft: String = lock.withLock {
            chunks.append(text)
            return chunks.joined()
        }
        onUpdate?(.draft(draft))
    }

    func status(_ title: String) {
        onUpdate?(.status(title))
    }

    func permission(_ prompt: GrokPermissionPrompt) {
        onUpdate?(.permission(prompt))
    }

    var text: String {
        lock.withLock { chunks.joined() }
    }
}

private extension GrokControlError {
    func provesExtensionExistsForMissingSession(method expectedMethod: String) -> Bool {
        let method: String
        let detail: String
        switch self {
        case let .extensionFailed(reportedMethod, message):
            method = reportedMethod
            detail = message
        case let .requestFailed(reportedMethod, _, message, data):
            method = reportedMethod
            detail = [message, data].compactMap { $0 }.joined(separator: " ")
        default:
            return false
        }

        guard method == expectedMethod else { return false }
        let normalized = detail.lowercased()
        guard !normalized.contains("method not found") else { return false }
        return normalized.contains("session not found")
            || normalized.contains("session does not exist")
            || normalized.contains("unknown session")
    }
}
