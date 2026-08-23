import Foundation
import Testing

@testable import Coinor

// MARK: - Fixtures and doubles

private enum GrokFixture {
    static func json(_ name: String) throws -> GrokJSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Grok/\(name).json")
        return try GrokJSONValue.decode(Data(contentsOf: url))
    }
}

/// An in-memory stand-in for the Grok child process. Requests are answered
/// synchronously from the send path, so no test has to wait on a real pipe.
private final class FakeGrokTransport: GrokTransport, @unchecked Sendable {
    typealias Handler = @Sendable (GrokJSONValue, FakeGrokTransport) -> Void

    private let lock = NSLock()
    private var continuation: AsyncStream<GrokTransportEvent>.Continuation?
    private var handler: Handler = { _, _ in }
    private var sent: [GrokJSONValue] = []
    private var terminated = false

    func handle(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    var requests: [GrokJSONValue] {
        lock.withLock { sent }
    }

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func request(_ method: String) -> GrokJSONValue? {
        requests.last { $0["method"]?.stringValue == method }
    }

    func start() throws -> AsyncStream<GrokTransportEvent> {
        let (stream, continuation) = AsyncStream<GrokTransportEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func send(_ payload: Data) throws {
        #expect(payload.last == 0x0A, "every outbound message is newline framed")
        let message = try GrokJSONValue.decode(Data(payload.dropLast()))
        lock.lock()
        sent.append(message)
        let handler = self.handler
        lock.unlock()
        handler(message, self)
    }

    func terminate() {
        lock.withLock { terminated = true }
    }

    func shutdown() async {
        terminate()
    }

    func emit(_ message: GrokJSONValue) {
        guard let payload = try? message.encoded() else { return }
        emit(GrokFraming.encode(payload))
    }

    func emit(_ data: Data) {
        lock.withLock { continuation }?.yield(.output(data))
    }

    func emitDiagnostic(_ text: String) {
        lock.withLock { continuation }?.yield(.diagnostic(Data(text.utf8)))
    }

    func end(status: Int32) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(.ended(status: status))
        continuation?.finish()
    }

    /// Waits for the client's reader task to produce `count` outbound
    /// messages, which is how a test observes work the client starts on its
    /// own rather than in response to a call.
    func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0 ..< 400 {
            if requests.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private func result(for request: GrokJSONValue, _ value: GrokJSONValue) -> GrokJSONValue {
    ["jsonrpc": "2.0", "id": request["id"] ?? .null, "result": value]
}

private func failure(
    for request: GrokJSONValue,
    code: Int,
    message: String,
    data: GrokJSONValue? = nil
) -> GrokJSONValue {
    var error: [String: GrokJSONValue] = [
        "code": .int(code),
        "message": .string(message),
    ]
    if let data {
        error["data"] = data
    }
    return [
        "jsonrpc": "2.0",
        "id": request["id"] ?? .null,
        "error": .object(error),
    ]
}

private final class FakeCompatibilityProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = [
        GrokMethod.sessionUpdates,
        GrokMethod.sessionRename,
    ]

    func consume(_ method: String) -> Bool {
        lock.withLock {
            guard remaining.first == method else { return false }
            remaining.removeFirst()
            return true
        }
    }
}

private func makeLaunch() throws -> GrokControlLaunch {
    GrokControlLaunch(
        executable: try GrokExecutable.resolve(configuredPath: "/bin/echo"),
        leaderSocket: try GrokLeaderSocket(path: "/tmp/coinor-grok-tests/grok-leader.sock"),
        workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        environment: ["PATH": "/usr/bin:/bin"]
    )
}

/// A connected client whose agent answers the handshake and then defers to
/// `handler` for everything else.
private func connectedClient(
    configuration: GrokControlClient.Configuration = GrokControlClient.Configuration(),
    initialize: GrokJSONValue? = nil,
    authenticationFailureMessage: String? = nil,
    unsupportedProbeMethods: Set<String> = [],
    missingSessionProbeMethods: Set<String> = [
        GrokMethod.sessionUpdates,
        GrokMethod.sessionRename,
    ],
    handler: @escaping FakeGrokTransport.Handler = { _, _ in }
) async throws -> (GrokControlClient, FakeGrokTransport, GrokAgentHandshake) {
    let initializeResult = try initialize ?? GrokFixture.json("initialize-response")
    let transport = FakeGrokTransport()
    let compatibility = FakeCompatibilityProbeState()
    transport.handle { request, transport in
        let method = request["method"]?.stringValue ?? ""
        let extensionMethod = GrokMethod.extensionName(forWire: method) ?? method
        switch method {
        case GrokMethod.initialize:
            transport.emit(result(for: request, initializeResult))
        case GrokMethod.authenticate:
            if let authenticationFailureMessage {
                transport.emit(
                    failure(
                        for: request,
                        code: -32001,
                        message: authenticationFailureMessage
                    )
                )
            } else {
                transport.emit(result(for: request, .object([:])))
            }
        case _ where compatibility.consume(extensionMethod):
            if unsupportedProbeMethods.contains(extensionMethod) {
                transport.emit(
                    failure(
                        for: request,
                        code: GrokRPC.methodNotFoundCode,
                        message: "Method not found"
                    )
                )
                return
            }
            if missingSessionProbeMethods.contains(extensionMethod) {
                transport.emit(
                    failure(
                        for: request,
                        code: -32600,
                        message: "Invalid request",
                        data: .string("session not found: compatibility probe")
                    )
                )
                return
            }
            let response: GrokJSONValue = extensionMethod == GrokMethod.sessionUpdates
                ? ["updates": [], "totalCount": 0, "hasMore": false]
                : ["sessions": []]
            transport.emit(result(for: request, response))
        default:
            handler(request, transport)
        }
    }
    let client = GrokControlClient(
        launch: try makeLaunch(),
        configuration: configuration,
        transport: { _ in transport },
        executableVersionProbe: { _, _ in "grok test-0.2.117" }
    )
    let handshake = try await client.connect()
    return (client, transport, handshake)
}

// MARK: - Launch validation

@Test
func startsGrokOnCoinorsOwnLeaderSocket() throws {
    let launch = try makeLaunch()

    #expect(launch.arguments == [
        "--leader-socket",
        "/tmp/coinor-grok-tests/grok-leader.sock",
        "agent",
        "--leader",
        "stdio",
    ])
    // The socket is a flag, never an exported variable, so nothing outside
    // this process tree inherits Coinor's leader.
    #expect(launch.environment == ["PATH": "/usr/bin:/bin"])
}

@Test
func requiresAnAbsoluteExecutablePath() {
    #expect(throws: GrokControlError.executablePathNotAbsolute("bin/grok")) {
        _ = try GrokExecutable.resolve(configuredPath: "bin/grok")
    }
}

@Test
func requiresTheExecutableToExistAndBeRunnable() throws {
    #expect(throws: GrokControlError.executableNotFound("/nonexistent/grok")) {
        _ = try GrokExecutable.resolve(configuredPath: "/nonexistent/grok")
    }

    let plain = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("coinor-not-executable-\(UUID().uuidString)")
    try Data("x".utf8).write(to: plain)
    defer { try? FileManager.default.removeItem(at: plain) }

    #expect(throws: GrokControlError.executableNotExecutable(plain.path)) {
        _ = try GrokExecutable.resolve(configuredPath: plain.path)
    }
}

@Test
func rejectsALeaderSocketPathTheKernelCannotBind() {
    let long = "/tmp/" + String(repeating: "a", count: 120) + ".sock"

    #expect(throws: GrokControlError.self) {
        _ = try GrokLeaderSocket(path: long)
    }
    #expect(throws: GrokControlError.leaderSocketPathNotAbsolute("grok.sock")) {
        _ = try GrokLeaderSocket(path: "grok.sock")
    }
}

// MARK: - Handshake

@Test
func handshakeIdentifiesTheAgentAndAuthenticates() async throws {
    let (client, transport, handshake) = try await connectedClient()
    defer { Task { await client.shutdown() } }

    #expect(await client.executableVersion == "grok test-0.2.117")
    #expect(handshake.protocolVersion == 1)
    #expect(handshake.agentVersion == "0.2.117")
    #expect(handshake.agentID == "agent-7f3c1a")
    #expect(handshake.authMethodIDs == ["xai.api_key", "grok.com", "cached_token"])
    #expect(handshake.authentication == .succeeded(methodID: "cached_token"))

    let requests = transport.requests
    #expect(requests.count == 4)
    #expect(requests[0]["id"]?.stringValue == "coinor-1")
    #expect(requests[0]["method"]?.stringValue == "initialize")
    #expect(requests[0]["params"]?["protocolVersion"]?.intValue == 1)
    #expect(
        requests[0]["params"]?["_meta"]?["clientVersion"]?.stringValue
            == GrokControlClient.Configuration().clientVersion
    )
    #expect(requests[1]["id"]?.stringValue == "coinor-2")
    #expect(requests[1]["params"]?["methodId"]?.stringValue == "cached_token")
    #expect(requests.dropFirst(2).compactMap { $0["method"]?.stringValue } == [
        "_x.ai/session/updates",
        "_x.ai/session/rename",
    ])
    #expect(
        requests[2]["params"]?["sessionId"]?.stringValue
            == "00000000-0000-0000-0000-000000000000"
    )
    #expect(
        requests[3]["params"]?["sessionId"]?.stringValue
            == "00000000-0000-0000-0000-000000000000"
    )
}

@Test
func derivesTheACPClientVersionFromBundleValuesWithAStableFallback() {
    #expect(
        GrokControlClient.Configuration.resolveClientVersion(
            shortVersion: " 0.1.0 ",
            buildVersion: "17"
        ) == "0.1.0"
    )
    #expect(
        GrokControlClient.Configuration.resolveClientVersion(
            shortVersion: nil,
            buildVersion: "17"
        ) == "17"
    )
    #expect(
        GrokControlClient.Configuration.resolveClientVersion(
            shortVersion: " ",
            buildVersion: nil
        ) == "0.0.0"
    )
}

@Test(arguments: [nil, 0, 2])
func refusesAnUnsupportedACPProtocolVersion(_ protocolVersion: Int?) async throws {
    let initializeResult: GrokJSONValue = [
        "protocolVersion": protocolVersion.map(GrokJSONValue.int) ?? .null,
        "_meta": ["grokShell": true],
        "authMethods": [],
    ]
    let transport = FakeGrokTransport()
    transport.handle { request, transport in
        transport.emit(result(for: request, initializeResult))
    }
    let client = GrokControlClient(
        launch: try makeLaunch(),
        transport: { _ in transport },
        executableVersionProbe: { _, _ in "grok test-version" }
    )

    await #expect(throws: GrokControlError.self) {
        _ = try await client.connect()
    }
    #expect(transport.isTerminated)
}

@Test
func nonCatalogRequiredExtensionFailuresAreAggregated() async {
    do {
        _ = try await connectedClient(
            unsupportedProbeMethods: [
                GrokMethod.sessionUpdates,
                GrokMethod.sessionRename,
            ],
            missingSessionProbeMethods: []
        )
        Issue.record("expected the compatibility probe to fail")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains(GrokMethod.sessionUpdates))
        #expect(message.contains(GrokMethod.sessionRename))
        #expect(message.contains("not support"))
    }
}

@Test
func refusesAnAgentThatIsNotAGrokShell() async throws {
    let transport = FakeGrokTransport()
    transport.handle { request, transport in
        transport.emit(result(for: request, ["protocolVersion": 1, "_meta": ["agentVersion": "0.0.0"]]))
    }
    let client = GrokControlClient(
        launch: try makeLaunch(),
        transport: { _ in transport },
        executableVersionProbe: { _, _ in "grok test-version" }
    )

    await #expect(throws: GrokControlError.self) {
        _ = try await client.connect()
    }
    // A failed handshake must not leave a Grok process behind.
    #expect(transport.isTerminated)
}

@Test
func reportsAuthenticationFailureWithoutFailingStartup() async throws {
    let (client, _, handshake) = try await connectedClient(
        authenticationFailureMessage: "no cached credentials"
    )

    guard case let .failed(methodID, message) = handshake.authentication else {
        Issue.record("expected a reported authentication failure")
        return
    }
    #expect(methodID == "cached_token")
    #expect(message.contains("no cached credentials"))
    await client.shutdown()
}

// MARK: - Session catalog

@Test
func pagesTheCatalogAndDropsRowsRepeatedAcrossPages() async throws {
    let pageOne = try GrokFixture.json("session-list-page-1")
    let pageTwo = try GrokFixture.json("session-list-page-2")
    let (client, transport, _) = try await connectedClient { request, transport in
        let cursor = request["params"]?["cursor"]?.stringValue
        transport.emit(result(for: request, cursor == nil ? pageOne : pageTwo))
    }

    let sessions = try await client.listPersistedSessions()

    #expect(sessions.map(\.id.rawValue) == [
        "00000000-0000-7000-8000-000000000001",
        "00000000-0000-7000-8000-000000000002",
        "00000000-0000-7000-8000-000000000003",
    ])

    let listRequests = transport.requests.filter {
        $0["method"]?.stringValue == "_x.ai/session/list"
            && $0["params"]?["limit"]?.intValue == 100
    }
    #expect(listRequests.count == 2)
    #expect(listRequests[0]["params"]?["cursor"] == nil)
    #expect(listRequests[0]["params"]?["limit"]?.intValue == 100)
    #expect(
        listRequests[0]["params"]?["_meta"]?["x.ai/facetFilters"]?["kind"]
            == .array([.string("build")])
    )
    #expect(listRequests[1]["params"]?["cursor"]?.stringValue == "cursor-page-2")
    #expect(listRequests.map { $0["id"]?.stringValue } == ["coinor-5", "coinor-6"])
    await client.shutdown()
}

@Test
func decodesCatalogFieldsAndKeepsWhatItDoesNotModel() async throws {
    let pageOne = try GrokFixture.json("session-list-page-1")
    let pageTwo = try GrokFixture.json("session-list-page-2")
    let (client, _, _) = try await connectedClient { request, transport in
        let cursor = request["params"]?["cursor"]?.stringValue
        transport.emit(result(for: request, cursor == nil ? pageOne : pageTwo))
    }

    let sessions = try await client.listPersistedSessions()

    let main = sessions[0]
    #expect(main.title == "Normalize the rent roll importer")
    #expect(main.cwd == "/Users/example/projects/rent-roll-normalizer")
    #expect(main.listKind == "build")
    #expect(main.messageCount == 42)
    #expect(main.gitRemotes == ["git@github.com:example/rent-roll-normalizer.git"])
    #expect(main.isSubagent == false)
    #expect(main.lastActiveAt?.timeIntervalSince1970 == 1785954135.482)

    let worktree = sessions[1]
    #expect(worktree.worktreeLabel == "teams-sync")
    #expect(worktree.sessionKind == "worktree")
    // A worktree conversation still belongs to the checkout it came from.
    #expect(worktree.projectDirectory == "/Users/example/projects/rent-roll-normalizer")
    // An empty summary must not win over the real title.
    #expect(worktree.title == "Investigate the Teams integration")
    // Fields Coinor does not model yet survive on the row.
    #expect(worktree.raw["experimentalRelevance"]?.doubleValue == 0.87)

    let bare = sessions[2]
    #expect(bare.title == nil)
    #expect(bare.updatedAt == nil)
    #expect(bare.gitRemotes.isEmpty)
    #expect(bare.cwd == "/Users/example/projects/coinor")
    await client.shutdown()
}

@Test
func stopsWhenTheCatalogCursorRepeats() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["sessions": [], "nextCursor": "stuck"]))
    }

    await #expect(throws: GrokControlError.paginationStalled(cursor: "stuck")) {
        _ = try await client.listPersistedSessions()
    }
    await client.shutdown()
}

@Test
func rejectsACatalogRowWithoutASessionIdentifier() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["sessions": [["cwd": "/tmp"]]]))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionList,
            detail: "a session row has no sessionId"
        )
    ) {
        _ = try await client.listPersistedSessions()
    }
    await client.shutdown()
}

@Test(arguments: [
    GrokJSONValue.object([:]),
    GrokJSONValue.object(["sessions": .null]),
    GrokJSONValue.object(["sessions": "not-an-array"]),
    GrokJSONValue.object(["sessions": [:]]),
])
func rejectsACatalogWithoutASessionsArray(_ payload: GrokJSONValue) async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, payload))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionList,
            detail: "sessions must be an array"
        )
    ) {
        _ = try await client.listPersistedSessions()
    }
    await client.shutdown()
}

@Test
func rejectsACatalogCursorWithAnInvalidType() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, [
            "sessions": [],
            "nextCursor": 42,
        ]))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionList,
            detail: "nextCursor must be a string or null"
        )
    ) {
        _ = try await client.listPersistedSessions()
    }
    await client.shutdown()
}

// MARK: - Roster

@Test
func decodesTheRosterIncludingAnActivityItDoesNotKnow() async throws {
    let roster = try GrokFixture.json("sessions-list-roster")
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, roster))
    }

    let entries = try await client.listRoster()

    #expect(entries.count == 3)
    #expect(entries[0].activity == .working)
    #expect(entries[0].isResident)
    #expect(entries[0].lastChange?.timeIntervalSince1970 == 1786120935.482)
    #expect(entries[1].activity == .needsInput)
    #expect(entries[1].activity.needsAttention)
    #expect(entries[1].isWorktree)
    #expect(entries[2].activity == .unknown("hibernating"))
    #expect(entries[2].originKind == "remote")
    #expect(transport.request("_x.ai/sessions/list") != nil)
    #expect(await client.inFlightRequestCount == 0)
    #expect(await client.scheduledTimeoutCount == 0)
    await client.shutdown()
}

@Test(arguments: [
    GrokJSONValue.object([:]),
    GrokJSONValue.object(["sessions": .null]),
    GrokJSONValue.object(["sessions": "not-an-array"]),
    GrokJSONValue.object(["sessions": [:]]),
])
func rejectsARosterWithoutASessionsArray(_ payload: GrokJSONValue) async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, payload))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionsList,
            detail: "sessions must be an array"
        )
    ) {
        _ = try await client.listRoster()
    }
    await client.shutdown()
}

@Test
func rejectsDuplicateRosterSessionIdentifiers() async throws {
    let duplicateID = "00000000-0000-7000-8000-000000000001"
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, [
            "sessions": [
                ["sessionId": .string(duplicateID)],
                ["sessionId": .string(duplicateID)],
            ],
        ]))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionsList,
            detail: "duplicate roster sessionId \(duplicateID)"
        )
    ) {
        _ = try await client.listRoster()
    }
    await client.shutdown()
}

@Test
func fansRosterChangesOutToEveryListener() async throws {
    let (client, transport, _) = try await connectedClient()
    let params = try GrokFixture.json("sessions-changed")

    var first = await client.events().makeAsyncIterator()
    var second = await client.events().makeAsyncIterator()
    transport.emit([
        "jsonrpc": "2.0",
        "method": "_x.ai/sessions/changed",
        "params": params,
    ])

    for iterator in [{ await first.next() }, { await second.next() }] {
        guard case let .rosterChanged(change)? = await iterator() else {
            Issue.record("a listener did not receive the roster change")
            return
        }
        #expect(change.upserted.map(\.id.rawValue) == ["00000000-0000-7000-8000-000000000002"])
        #expect(change.upserted.first?.activity == .dormant)
        #expect(change.removed == [GrokSessionID("00000000-0000-7000-8000-000000000009")])
    }
    await client.shutdown()
}

@Test
func directAndWrappedLifecycleNotificationsDecodeIdentically() async throws {
    let (client, transport, _) = try await connectedClient()
    var events = await client.events().makeAsyncIterator()
    let payload: GrokJSONValue = [
        "sessionId": "root",
        "update": [
            "sessionUpdate": "subagent_spawned",
            "child_session_id": "child",
            "parent_session_id": "root",
            "subagent_type": "explore",
            "description": "Inspect the catalog",
        ],
        "_meta": ["agentTimestampMs": 1_786_120_000_000],
    ]

    transport.emit([
        "jsonrpc": "2.0",
        "method": "_x.ai/session_notification",
        "params": payload,
    ])
    guard case let .subagentLifecycle(direct)? = await events.next() else {
        Issue.record("the direct lifecycle notification was not decoded")
        return
    }

    transport.emit([
        "jsonrpc": "2.0",
        "method": "_x.ai/session_notification",
        "params": [
            "method": "x.ai/session_notification",
            "params": payload,
        ],
    ])
    guard case let .subagentLifecycle(wrapped)? = await events.next() else {
        Issue.record("the wrapped lifecycle notification was not decoded")
        return
    }

    #expect(direct == wrapped)
    #expect(direct.kind == .started)
    #expect(direct.childSessionID == "child")
    #expect(direct.parentSessionID == "root")
    #expect(direct.subagentType == "explore")
    await client.shutdown()
}

@Test
func pagesPersistedLifecycleAndKeepsStorageOrder() async throws {
    var configuration = GrokControlClient.Configuration()
    configuration.pageSize = 2
    let envelopes: [GrokJSONValue] = [
        [
            "timestamp": 1_786_120_000,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "root",
                "update": [
                    "sessionUpdate": "subagent_spawned",
                    "child_session_id": "child",
                    "parent_session_id": "root",
                ],
            ],
        ],
        [
            "timestamp": 1_786_120_001,
            "method": "session/update",
            "params": [
                "sessionId": "root",
                "update": ["sessionUpdate": "agent_message_chunk"],
            ],
        ],
        [
            "timestamp": 1_786_120_002,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "root",
                "update": [
                    "sessionUpdate": "subagent_finished",
                    "child_session_id": "child",
                    "status": "completed",
                ],
            ],
        ],
    ]
    let (client, transport, _) = try await connectedClient(
        configuration: configuration
    ) { request, transport in
        let offset = request["params"]?["offset"]?.intValue ?? 0
        let page = Array(envelopes.dropFirst(offset).prefix(2))
        transport.emit(result(for: request, [
            "updates": .array(page),
            "totalCount": 3,
            "hasMore": .bool(offset + page.count < envelopes.count),
        ]))
    }

    let observations = try await client.listSubagentLifecycle(
        sessionID: "root",
        cwd: "/tmp/project"
    )

    let kinds = observations.map { $0.kind }
    let childIDs = observations.map { $0.childSessionID }
    #expect(
        kinds == [
            GrokSubagentLifecycleObservation.Kind.started,
            GrokSubagentLifecycleObservation.Kind.finished,
        ]
    )
    #expect(childIDs == ["child", "child"])
    let requests = transport.requests.filter {
        $0["method"]?.stringValue == "_x.ai/session/updates"
            && $0["params"]?["sessionId"]?.stringValue == "root"
    }
    #expect(requests.count == 2)
    #expect(requests.map { $0["params"]?["offset"]?.intValue } == [0, 2])
    let requestParamsAreCorrect = requests.allSatisfy { request in
        let params = request["params"]
        return params?["sessionId"]?.stringValue == "root"
            && params?["cwd"]?.stringValue == "/tmp/project"
            && params?["limit"]?.intValue == 2
    }
    #expect(requestParamsAreCorrect)
    await client.shutdown()
}

@Test
func persistedChildFailureBecomesATerminalObservation() async throws {
    let failed: GrokJSONValue = [
        "timestamp": 1_786_120_003,
        "method": "_x.ai/session/update",
        "params": [
            "sessionId": "child",
            "update": [
                "sessionUpdate": "retry_state",
                "type": "failed",
            ],
        ],
    ]
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, [
            "updates": .array([failed]),
            "totalCount": 1,
            "hasMore": false,
        ]))
    }

    let observations = try await client.listSubagentLifecycle(
        sessionID: "child",
        cwd: "/tmp/project",
        parentSessionID: "root"
    )

    #expect(observations.count == 1)
    #expect(observations.first?.kind == .finished)
    #expect(observations.first?.childSessionID == "child")
    #expect(observations.first?.parentSessionID == "root")
    #expect(observations.first?.status == "failed")
    await client.shutdown()
}

@Test(arguments: [
    GrokJSONValue.object([:]),
    GrokJSONValue.object(["updates": .null]),
    GrokJSONValue.object(["updates": "not-an-array"]),
    GrokJSONValue.object(["updates": [:]]),
])
func rejectsAnUpdatesPageWithoutAnUpdatesArray(
    _ payload: GrokJSONValue
) async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        var page = payload
        if case var .object(members) = page {
            members["hasMore"] = .bool(false)
            page = .object(members)
        }
        transport.emit(result(for: request, page))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionUpdates,
            detail: "updates must be an array"
        )
    ) {
        _ = try await client.listSubagentLifecycle(
            sessionID: "root",
            cwd: "/tmp/project"
        )
    }
    await client.shutdown()
}

@Test(arguments: [
    GrokJSONValue.object([:]),
    GrokJSONValue.object(["hasMore": .null]),
    GrokJSONValue.object(["hasMore": 1]),
    GrokJSONValue.object(["hasMore": "no"]),
])
func rejectsAnUpdatesPageWithoutABooleanHasMore(
    _ payload: GrokJSONValue
) async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        var page = payload
        if case var .object(members) = page {
            members["updates"] = .array([])
            page = .object(members)
        }
        transport.emit(result(for: request, page))
    }

    await #expect(
        throws: GrokControlError.malformedPayload(
            method: GrokMethod.sessionUpdates,
            detail: "hasMore must be a bool"
        )
    ) {
        _ = try await client.listSubagentLifecycle(
            sessionID: "root",
            cwd: "/tmp/project"
        )
    }
    await client.shutdown()
}

// MARK: - Rename

@Test
func renamesARootConversation() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["success": true]))
    }

    try await client.rename(
        GrokSessionID("00000000-0000-7000-8000-000000000001"),
        to: "Rent roll intake",
        inDirectory: "/Users/example/projects/rent-roll-normalizer"
    )

    let request = try #require(transport.request("_x.ai/session/rename"))
    #expect(request["params"]?["sessionId"]?.stringValue == "00000000-0000-7000-8000-000000000001")
    #expect(request["params"]?["title"]?.stringValue == "Rent roll intake")
    #expect(request["params"]?["cwd"]?.stringValue == "/Users/example/projects/rent-roll-normalizer")
    await client.shutdown()
}

@Test
func surfacesAnExtensionLevelFailure() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["result": .null, "error": "session not found: abc"]))
    }

    await #expect(
        throws: GrokControlError.extensionFailed(
            method: GrokMethod.sessionRename,
            message: "session not found: abc"
        )
    ) {
        try await client.rename(GrokSessionID("abc"), to: "Nope")
    }
    await client.shutdown()
}

@Test
func reportsAnExtensionThisGrokBuildDoesNotHave() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(failure(for: request, code: -32601, message: "Method not found"))
    }

    await #expect(throws: GrokControlError.unsupportedMethod(GrokMethod.sessionsList)) {
        _ = try await client.listRoster()
    }
    await client.shutdown()
}

@Test
func reportsAMissingPersistedSessionCatalogExtension() async throws {
    let (client, _, _) = try await connectedClient { request, transport in
        transport.emit(
            failure(
                for: request,
                code: -32601,
                message: "Method not found"
            )
        )
    }

    await #expect(
        throws: GrokControlError.unsupportedMethod(GrokMethod.sessionList)
    ) {
        _ = try await client.listPersistedSessions()
    }
    await client.shutdown()
}

// MARK: - Lifecycle

@Test
func answersReverseRequestsItCannotServe() async throws {
    let (client, transport, _) = try await connectedClient()
    let expectedRequestCount = transport.requests.count + 1

    transport.emit([
        "jsonrpc": "2.0",
        "id": 7,
        "method": "fs/read_text_file",
        "params": ["path": "/etc/hosts"],
    ])

    #expect(await transport.waitForRequests(expectedRequestCount))
    let reply = try #require(transport.requests.last)
    #expect(reply["id"]?.intValue == 7)
    #expect(reply["error"]?["code"]?.intValue == -32601)
    await client.shutdown()
}

@Test
func ignoresSharedInteractionRequestsSoTheTerminalCanAnswer() async throws {
    let (client, transport, _) = try await connectedClient()
    let requestCount = transport.requests.count

    transport.emit([
        "jsonrpc": "2.0",
        "id": 8,
        "method": "_x.ai/ask_user_question",
        "params": [
            "method": "x.ai/ask_user_question",
            "params": [
                "sessionId": "root",
                "toolCallId": "question-1",
                "questions": [],
            ],
        ],
    ])
    try? await Task.sleep(for: .milliseconds(50))

    #expect(transport.requests.count == requestCount)
    await client.shutdown()
}

@Test
func failsInFlightWorkWhenGrokExits() async throws {
    let (client, _, _) = try await connectedClient { _, transport in
        transport.emitDiagnostic("leader refused: sandbox profile is not off\n")
        transport.end(status: 2)
    }

    let events = await client.events()

    await #expect(
        throws: GrokControlError.transportEnded(
            status: 2,
            diagnostics: "leader refused: sandbox profile is not off"
        )
    ) {
        _ = try await client.listRoster()
    }

    var iterator = events.makeAsyncIterator()
    guard case let .terminated(error)? = await iterator.next() else {
        Issue.record("listeners were not told the connection ended")
        return
    }
    #expect(error.errorDescription?.contains("sandbox profile is not off") == true)
}

@Test
func timesOutARequestGrokNeverAnswers() async throws {
    var configuration = GrokControlClient.Configuration()
    configuration.requestTimeout = .milliseconds(50)
    let (client, _, _) = try await connectedClient(configuration: configuration)

    await #expect(throws: GrokControlError.self) {
        _ = try await client.listRoster()
    }
    await client.shutdown()
}

@Test
func cancellingARequestClearsItsContinuationAndTimeout() async throws {
    let (client, transport, _) = try await connectedClient()
    let expectedRequestCount = transport.requests.count + 1
    let task = Task {
        try await client.listRoster()
    }
    #expect(await transport.waitForRequests(expectedRequestCount))

    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(await client.inFlightRequestCount == 0)
    #expect(await client.scheduledTimeoutCount == 0)
    await client.shutdown()
}

// MARK: - Session drive

@Test
func createsASessionThroughACP() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(
            result(for: request, ["sessionId": "00000000-0000-7000-8000-000000000099"])
        )
    }

    try await client.createSession(
        id: GrokSessionID("00000000-0000-7000-8000-000000000099"),
        cwd: "/tmp/coinor"
    )

    let request = try #require(transport.request("session/new"))
    #expect(request["params"]?["cwd"]?.stringValue == "/tmp/coinor")
    #expect(
        request["params"]?["_meta"]?["sessionId"]?.stringValue
            == "00000000-0000-7000-8000-000000000099"
    )
    await client.shutdown()
}

@Test
func createsASessionWithRulesYoloModeAndAModelOverride() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["sessionId": "session-a"]))
    }

    try await client.createSession(
        id: GrokSessionID("session-a"),
        cwd: "/tmp/coinor",
        modelID: "claude-sonnet-5",
        rules: "you are an automation",
        yoloMode: true
    )

    let meta = try #require(transport.request("session/new")?["params"]?["_meta"])
    #expect(meta["modelId"]?.stringValue == "claude-sonnet-5")
    #expect(meta["rules"]?.stringValue == "you are an automation")
    #expect(meta["yoloMode"]?.boolValue == true)
    await client.shutdown()
}

@Test
func createSessionOmitsUnsetOptionalMetaFields() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["sessionId": "session-a"]))
    }

    try await client.createSession(id: GrokSessionID("session-a"), cwd: "/tmp/coinor")

    let meta = try #require(transport.request("session/new")?["params"]?["_meta"])
    #expect(meta["modelId"] == nil)
    #expect(meta["rules"] == nil)
    #expect(meta["yoloMode"] == nil)
    await client.shutdown()
}

@Test
func loadsAnExistingSessionThroughACPWithCwd() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, [:]))
    }

    try await client.loadSession(
        GrokSessionID("00000000-0000-7000-8000-000000000099"),
        cwd: "/tmp/coinor"
    )

    let request = try #require(transport.request("session/load"))
    #expect(request["params"]?["sessionId"]?.stringValue
        == "00000000-0000-7000-8000-000000000099")
    #expect(request["params"]?["cwd"]?.stringValue == "/tmp/coinor")
    #expect(request["params"]?["mcpServers"]?.arrayValue?.isEmpty == true)
    await client.shutdown()
}

@Test
func collectsPromptChunksUntilTheTurnCompletes() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        guard request["method"]?.stringValue == "session/prompt" else {
            transport.emit(result(for: request, [:]))
            return
        }
        transport.emit([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "session-a",
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": [
                        "type": "text",
                        "text": "Hello ",
                    ],
                ],
            ],
        ])
        transport.emit([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "session-a",
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": [
                        "type": "text",
                        "text": "from Grok.",
                    ],
                ],
            ],
        ])
        transport.emit(result(for: request, ["stopReason": "end_turn"]))
    }

    let text = try await client.prompt(
        sessionID: GrokSessionID("session-a"),
        text: "hi"
    )
    #expect(text == "Hello from Grok.")
    let request = try #require(transport.request("session/prompt"))
    #expect(request["params"]?["sessionId"]?.stringValue == "session-a")
    await client.shutdown()
}

@Test
func interruptingAPromptDoesNotWipeTheReplacementTurn() async throws {
    final class PromptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }
    let counter = PromptCounter()
    let (client, transport, _) = try await connectedClient { request, transport in
        guard request["method"]?.stringValue == "session/prompt" else {
            transport.emit(result(for: request, [:]))
            return
        }
        if counter.next() == 2 {
            transport.emit([
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": [
                    "sessionId": "session-a",
                    "update": [
                        "sessionUpdate": "agent_message_chunk",
                        "content": [
                            "type": "text",
                            "text": "replacement-turn",
                        ],
                    ],
                ],
            ])
            transport.emit(result(for: request, ["stopReason": "end_turn"]))
        }
    }

    let afterHandshake = transport.requests.count
    let first = Task {
        try await client.prompt(
            sessionID: GrokSessionID("session-a"),
            text: "first"
        )
    }
    #expect(await transport.waitForRequests(afterHandshake + 1))
    #expect(
        transport.requests.filter { $0["method"]?.stringValue == "session/prompt" }.count
            == 1
    )

    let second = Task {
        try await client.prompt(
            sessionID: GrokSessionID("session-a"),
            text: "second"
        )
    }

    await #expect(throws: CancellationError.self) {
        _ = try await first.value
    }
    let text = try await second.value
    #expect(text == "replacement-turn")
    await client.shutdown()
}

@Test
func promptSendsProvidedBlocksOnTheACPWire() async throws {
    let pixels = Data([0xFF, 0xD8, 0x00])
    let blocks: [GrokJSONValue] = [
        ["type": "text", "text": .string("see this")],
        [
            "type": "image",
            "mimeType": "image/jpeg",
            "data": .string(pixels.base64EncodedString()),
        ],
    ]
    let (client, transport, _) = try await connectedClient { request, transport in
        transport.emit(result(for: request, ["stopReason": "end_turn"]))
    }

    _ = try await client.prompt(
        sessionID: GrokSessionID("session-a"),
        blocks: blocks
    )

    let request = try #require(transport.request("session/prompt"))
    let sent = request["params"]?["prompt"]?.arrayValue ?? []
    #expect(sent == blocks)
    #expect(sent[1]["data"]?.stringValue == pixels.base64EncodedString())
    await client.shutdown()
}

@Test
func answersPermissionRequestsWhileAPromptIsInFlight() async throws {
    let (client, transport, _) = try await connectedClient { request, transport in
        guard request["method"]?.stringValue == "session/prompt" else {
            transport.emit(result(for: request, [:]))
            return
        }
        transport.emit([
            "jsonrpc": "2.0",
            "id": 42,
            "method": "session/request_permission",
            "params": [
                "sessionId": "session-a",
                "toolCall": ["title": "Run git push"],
                "options": [
                    [
                        "optionId": "allow-once",
                        "name": "Allow once",
                    ],
                ],
            ],
        ])
    }

    let expectedCount = transport.requests.count + 2
    let prompt = Task {
        try await client.prompt(
            sessionID: GrokSessionID("session-a"),
            text: "push"
        ) { update in
            guard case let .permission(value) = update else { return }
            Task {
                await client.answerPermission(
                    sessionID: value.sessionID,
                    optionID: "allow-once"
                )
            }
        }
    }

    #expect(await transport.waitForRequests(expectedCount))
    let answer = try #require(
        transport.requests.last { $0["id"]?.intValue == 42 }
    )
    #expect(answer["result"]?["outcome"]?["optionId"]?.stringValue == "allow-once")

    let promptRequest = try #require(transport.request("session/prompt"))
    transport.emit(result(for: promptRequest, ["stopReason": "end_turn"]))
    _ = try await prompt.value
    await client.shutdown()
}

@Test
func refusesToRunTwiceAndRefusesWorkAfterShutdown() async throws {
    let (client, _, _) = try await connectedClient()

    await #expect(throws: GrokControlError.alreadyConnected) {
        _ = try await client.connect()
    }

    await client.shutdown()
    await #expect(throws: GrokControlError.notConnected) {
        _ = try await client.listRoster()
    }
}

/// A thread-safe single-value box, for capturing one request out of a
/// `@Sendable` `FakeGrokTransport.Handler` closure without a data race.
private final class Captured<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value? = nil) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    func get() -> Value? {
        lock.withLock { value }
    }
}

// MARK: - AppCoordinator integration (real entry points)

/// Wires an `AppCoordinator` to a fake transport via
/// `AppCoordinator.seedForTesting`, so the tests below drive the
/// coordinator's real `renameConversation` / `runAutomationLive` entry
/// points end to end — not the pure helpers they call into — against a
/// scripted Grok control connection.
@MainActor
private func seededCoordinator(
    metadata: MetadataDocument = .empty,
    handler: @escaping FakeGrokTransport.Handler
) async throws -> (
    coordinator: AppCoordinator,
    client: GrokControlClient,
    transport: FakeGrokTransport,
    supportDirectory: URL
) {
    let (client, transport, _) = try await connectedClient(handler: handler)
    let supportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "AppCoordinatorSeed-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: supportDirectory,
        withIntermediateDirectories: true
    )
    let coordinator = AppCoordinator()
    coordinator.seedForTesting(
        controlClient: client,
        metadata: metadata,
        supportDirectory: supportDirectory
    )
    return (coordinator, client, transport, supportDirectory)
}

/// The session/list handler tracks `title` as a live value rather than a
/// fixed string, so a test that lets a rename succeed can update it exactly
/// when a real Grok backend would — synchronously, before its RPC responds —
/// and a subsequent `refresh()` genuinely reflects the rename instead of
/// artificially reverting it the way a static fixture would.
private func oneSessionCatalogHandler(
    sessionID: String,
    title: Captured<String>,
    cwd: String,
    onRename: @escaping @Sendable (GrokJSONValue, FakeGrokTransport) -> Void
) -> FakeGrokTransport.Handler {
    { request, transport in
        switch request["method"]?.stringValue {
        case "_x.ai/session/list":
            transport.emit(result(for: request, [
                "sessions": [[
                    "sessionId": .string(sessionID),
                    "title": .string(title.get() ?? ""),
                    "cwd": .string(cwd),
                ]],
                "nextCursor": .null,
            ]))
        case "_x.ai/sessions/list":
            transport.emit(result(for: request, ["sessions": []]))
        case "_x.ai/session/rename":
            onRename(request, transport)
        default:
            transport.emit(result(for: request, .object([:])))
        }
    }
}

@Test
@MainActor
func renameConversationUpdatesTheSidebarBeforeTheRpcCompletes() async throws {
    let sessionCwd = FileManager.default.temporaryDirectory.path
    let renameRequestID = Captured<GrokJSONValue>()
    let title = Captured<String>("Old title")
    let seeded = try await seededCoordinator(
        handler: oneSessionCatalogHandler(
            sessionID: "session-a",
            title: title,
            cwd: sessionCwd
        ) { request, _ in
            // Deliberately withheld: the test controls exactly when this
            // resolves, to prove the sidebar updates before it does.
            renameRequestID.set(request["id"] ?? .null)
        }
    )
    defer { try? FileManager.default.removeItem(at: seeded.supportDirectory) }

    try await seeded.coordinator.refresh()
    #expect(
        seeded.coordinator.summaries.first { $0.id == "session-a" }?.title
            == "Old title"
    )

    seeded.coordinator.renameConversation("session-a", title: "New title")

    // `renameConversation` is synchronous up to the point it starts its
    // background rename `Task`; the optimistic update must already be
    // visible here, before the RPC this test is still withholding resolves.
    #expect(
        seeded.coordinator.summaries.first { $0.id == "session-a" }?.title
            == "New title"
    )
    #expect(
        seeded.coordinator.catalog.projects
            .flatMap(\.conversations)
            .first { $0.id == "session-a" }?
            .session.title == "New title"
    )

    // The RPC itself runs on the background Task `renameConversation`
    // starts; give it a chance to actually run and reach the (deliberately
    // withheld) transport call.
    for _ in 0 ..< 200 {
        if renameRequestID.get() != nil { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    let requestID = try #require(
        renameRequestID.get(),
        "the rename RPC never reached the fake transport"
    )
    // A real Grok backend durably applies the rename before its RPC
    // responds, so a session/list call issued afterward already reflects
    // it; model that here instead of leaving the fixture stale.
    title.set("New title")
    seeded.transport.emit([
        "jsonrpc": "2.0",
        "id": requestID,
        "result": ["success": true],
    ])

    // Let the background Task's remaining awaits settle; the title must
    // still read "New title" once the RPC it was withholding completes.
    for _ in 0 ..< 50 {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(
        seeded.coordinator.summaries.first { $0.id == "session-a" }?.title
            == "New title"
    )
    #expect(seeded.coordinator.warningMessage == nil)

    await seeded.client.shutdown()
}

@Test
@MainActor
func aFailedRenameRpcRevertsTheOptimisticTitle() async throws {
    let sessionCwd = FileManager.default.temporaryDirectory.path
    let seeded = try await seededCoordinator(
        handler: oneSessionCatalogHandler(
            sessionID: "session-a",
            title: Captured<String>("Old title"),
            cwd: sessionCwd
        ) { request, transport in
            transport.emit(failure(for: request, code: -32000, message: "boom"))
        }
    )
    defer { try? FileManager.default.removeItem(at: seeded.supportDirectory) }

    try await seeded.coordinator.refresh()
    seeded.coordinator.renameConversation("session-a", title: "New title")
    #expect(
        seeded.coordinator.summaries.first { $0.id == "session-a" }?.title
            == "New title"
    )

    var reverted = false
    for _ in 0 ..< 200 {
        if seeded.coordinator.summaries.first(where: { $0.id == "session-a" })?
            .title == "Old title" {
            reverted = true
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(reverted, "the title must revert once the rename RPC fails")
    #expect(seeded.coordinator.warningMessage != nil)

    await seeded.client.shutdown()
}

@Test
@MainActor
func runAutomationLiveDrivesTheControlConnectionAndRecordsTheRun() async throws {
    let newSessionRequest = Captured<GrokJSONValue>()
    let promptRequest = Captured<GrokJSONValue>()
    var metadata = MetadataDocument.empty
    metadata.upsertAutomation(Automation(
        id: "auto-1",
        name: "Nightly review",
        schedule: "0 9 * * *",
        workingDirectory: FileManager.default.temporaryDirectory.path,
        prompt: "review open PRs",
        model: "claude-sonnet-5"
    ))
    let seeded = try await seededCoordinator(metadata: metadata) { request, transport in
        switch request["method"]?.stringValue {
        case "session/new":
            newSessionRequest.set(request)
            transport.emit(result(for: request, ["sessionId": "session-live"]))
        case "session/prompt":
            promptRequest.set(request)
            transport.emit(result(for: request, ["stopReason": "end_turn"]))
        case "_x.ai/session/list":
            transport.emit(result(for: request, ["sessions": [], "nextCursor": .null]))
        case "_x.ai/sessions/list":
            transport.emit(result(for: request, ["sessions": []]))
        default:
            transport.emit(result(for: request, .object([:])))
        }
    }
    defer { try? FileManager.default.removeItem(at: seeded.supportDirectory) }

    let request = AutomationRunRequest(
        automationID: "auto-1",
        runID: "run-1",
        sessionID: "session-live",
        trigger: .scheduled
    )
    await seeded.coordinator.runAutomationLive(request)

    let newSession = try #require(newSessionRequest.get())
    #expect(
        newSession["params"]?["_meta"]?["sessionId"]?.stringValue
            == "session-live"
    )
    #expect(
        newSession["params"]?["_meta"]?["modelId"]?.stringValue
            == "claude-sonnet-5"
    )
    #expect(newSession["params"]?["_meta"]?["yoloMode"]?.boolValue == true)
    #expect(
        newSession["params"]?["_meta"]?["rules"]?.stringValue?.isEmpty == false
    )

    let prompt = try #require(promptRequest.get())
    let promptText = prompt["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue
    #expect(promptText == "review open PRs")

    let runLogURL = seeded.supportDirectory
        .appendingPathComponent(AutomationJob.runLogFileName)
    let runs = AutomationRunLog.runs(at: runLogURL)
    let run = try #require(runs.first { $0.id == "run-1" })
    #expect(run.status == .succeeded)
    #expect(run.sessionID == "session-live")

    #expect(seeded.coordinator.automationSessionIDs.contains("session-live"))

    await seeded.client.shutdown()
}

@Test
@MainActor
func runAutomationLiveRecordsAFailureWhenThePromptRpcFails() async throws {
    var metadata = MetadataDocument.empty
    metadata.upsertAutomation(Automation(
        id: "auto-2",
        name: "Broken automation",
        schedule: "0 9 * * *",
        workingDirectory: FileManager.default.temporaryDirectory.path,
        prompt: "do the thing"
    ))
    let seeded = try await seededCoordinator(metadata: metadata) { request, transport in
        switch request["method"]?.stringValue {
        case "session/new":
            transport.emit(result(for: request, ["sessionId": "session-fail"]))
        case "session/prompt":
            transport.emit(failure(for: request, code: -32000, message: "boom"))
        case "_x.ai/session/list":
            transport.emit(result(for: request, ["sessions": [], "nextCursor": .null]))
        case "_x.ai/sessions/list":
            transport.emit(result(for: request, ["sessions": []]))
        default:
            transport.emit(result(for: request, .object([:])))
        }
    }
    defer { try? FileManager.default.removeItem(at: seeded.supportDirectory) }

    let request = AutomationRunRequest(
        automationID: "auto-2",
        runID: "run-2",
        sessionID: "session-fail",
        trigger: .forced
    )
    await seeded.coordinator.runAutomationLive(request)

    let runLogURL = seeded.supportDirectory
        .appendingPathComponent(AutomationJob.runLogFileName)
    let run = try #require(
        AutomationRunLog.runs(at: runLogURL).first { $0.id == "run-2" }
    )
    #expect(run.status == .failed)
    #expect(run.trigger == .forced)

    await seeded.client.shutdown()
}
