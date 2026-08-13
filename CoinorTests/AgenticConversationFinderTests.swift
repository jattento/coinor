import Foundation
import Testing

@testable import Coinor

private actor FinderStub: AgenticConversationFinding {
    let response: AgenticFinderResponse
    private(set) var requests: [AgenticFinderRequest] = []

    init(response: AgenticFinderResponse) {
        self.response = response
    }

    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse {
        requests.append(request)
        return response
    }

    nonisolated func cancel() {}
}

private final class LateFinderStub: AgenticConversationFinding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgenticFinderResponse, Never>?
    private var didStart = false
    private var didCancel = false

    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse {
        markStarted()
        return await withCheckedContinuation { continuation in
            store(continuation)
        }
    }

    func cancel() {
        markCancelled()
    }

    func waitUntilStarted() async throws {
        for _ in 0..<100 {
            if hasStarted { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Finder did not start")
    }

    func resolve(_ response: AgenticFinderResponse) {
        takeContinuation()?.resume(returning: response)
    }

    var cancelWasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    private var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    private func markStarted() {
        lock.lock()
        didStart = true
        lock.unlock()
    }

    private func markCancelled() {
        lock.lock()
        didCancel = true
        lock.unlock()
    }

    private func store(
        _ continuation: CheckedContinuation<AgenticFinderResponse, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func takeContinuation()
        -> CheckedContinuation<AgenticFinderResponse, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

private struct TestGrokFixture {
    let directory: URL
    let executable: GrokExecutable

    static func make(script: String) throws -> TestGrokFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgenticFinderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let executableURL = directory.appendingPathComponent("fake-grok.py")
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        return TestGrokFixture(
            directory: directory,
            executable: try GrokExecutable.resolve(
                configuredPath: executableURL.path
            )
        )
    }
}

@Test
func listingAnArchivedMatchDoesNotMutateMetadata() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("session", archived: true)
    let before = metadata
    let summary = SessionSummary(
        id: "session",
        projectID: "project",
        title: "Remote host reconnect"
    )
    let match = AgenticFinderMatch(
        sessionID: "session",
        reason: "It discusses reconnection.",
        confidence: 0.9,
        open: false,
        pin: false
    )

    let plan = AgenticFinderActionPlan.resolve(
        match: match,
        summary: summary,
        metadata: metadata
    )
    plan.apply(to: &metadata)

    #expect(metadata == before)
    #expect(!plan.shouldOpen)
    #expect(!plan.shouldUnarchiveConversation)
}

@Test
func rowOpeningActionNeverPinsAndRestoresArchivedItems() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("session", archived: true)
    metadata.setProjectArchived("project", archived: true)
    let summary = SessionSummary(
        id: "session",
        projectID: "project",
        title: "Remote host reconnect"
    )
    let modelMatch = AgenticFinderMatch(
        sessionID: "session",
        reason: "It discusses reconnection.",
        confidence: 0.9,
        open: true,
        pin: true
    )

    let plan = AgenticFinderActionPlan.resolve(
        match: modelMatch.openingAction,
        summary: summary,
        metadata: metadata
    )
    plan.apply(to: &metadata)

    #expect(plan.shouldOpen)
    #expect(!plan.shouldPin)
    #expect(!metadata.isSessionArchived("session"))
    #expect(!metadata.isProjectArchived("project"))
    #expect(!metadata.isSessionPinned("session"))
}

@Test
func explicitPinActionPinsWithoutOpeningOrUnarchiving() {
    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("session", archived: true)
    metadata.setProjectArchived("project", archived: true)
    let summary = SessionSummary(
        id: "session",
        projectID: "project",
        title: "Remote host reconnect"
    )
    let modelMatch = AgenticFinderMatch(
        sessionID: "session",
        reason: "It discusses reconnection.",
        confidence: 0.9,
        open: true,
        pin: true
    )

    let plan = AgenticFinderActionPlan.resolve(
        match: modelMatch.pinningAction,
        summary: summary,
        metadata: metadata
    )
    plan.apply(to: &metadata)

    #expect(!plan.shouldOpen)
    #expect(plan.shouldPin)
    #expect(metadata.isSessionArchived("session"))
    #expect(metadata.isProjectArchived("project"))
    #expect(metadata.isSessionPinned("session"))
}

@Test
func finderResponseDiscardsUnknownAndDuplicateIDsAndClampsConfidence() {
    let response = AgenticFinderResponse(
        message: "Matches",
        matches: [
            AgenticFinderMatch(
                sessionID: "unknown",
                reason: "Invented",
                confidence: 0.8,
                open: false,
                pin: false
            ),
            AgenticFinderMatch(
                sessionID: "first",
                reason: "First valid result",
                confidence: 2.5,
                open: false,
                pin: false
            ),
            AgenticFinderMatch(
                sessionID: "first",
                reason: "Duplicate",
                confidence: 0.4,
                open: true,
                pin: true
            ),
            AgenticFinderMatch(
                sessionID: "second",
                reason: "Second valid result",
                confidence: .nan,
                open: false,
                pin: false
            ),
        ]
    )

    let sanitized = response.sanitized(
        for: [
            AgenticFinderCandidate(
                id: "first",
                title: "First",
                project: "Conan Code",
                lastActivity: nil,
                archived: false,
                pinned: false,
                excerpt: nil
            ),
            AgenticFinderCandidate(
                id: "second",
                title: "Second",
                project: "Conan Code",
                lastActivity: nil,
                archived: false,
                pinned: false,
                excerpt: nil
            ),
        ]
    )

    #expect(sanitized.matches.map(\.sessionID) == ["first", "second"])
    #expect(sanitized.matches[0].confidence == 1)
    #expect(sanitized.matches[1].confidence == 0)
    #expect(sanitized.matches[0].reason == "First valid result")
}

@Test
func finderResponseCapsSanitizedMatchesAtFive() {
    let candidates = (0..<7).map { index in
        AgenticFinderCandidate(
            id: "session-\(index)",
            title: "Session \(index)",
            project: "Conan Code",
            lastActivity: nil,
            archived: false,
            pinned: false,
            excerpt: nil
        )
    }
    let response = AgenticFinderResponse(
        message: "Matches",
        matches: candidates.map { candidate in
            AgenticFinderMatch(
                sessionID: candidate.id,
                reason: "Match",
                confidence: 0.8,
                open: false,
                pin: false
            )
        }
    )

    let sanitized = response.sanitized(for: candidates)

    #expect(sanitized.matches.count == 5)
}

@Test
func explicitActionsContainOnlyModelRequestedMutations() {
    let response = AgenticFinderResponse(
        message: "Matches",
        matches: [
            AgenticFinderMatch(
                sessionID: "list",
                reason: "List only",
                confidence: 0.8,
                open: false,
                pin: false
            ),
            AgenticFinderMatch(
                sessionID: "open",
                reason: "Open",
                confidence: 0.9,
                open: true,
                pin: false
            ),
            AgenticFinderMatch(
                sessionID: "pin",
                reason: "Pin",
                confidence: 0.9,
                open: false,
                pin: true
            ),
        ]
    )

    #expect(response.explicitActions.map(\.sessionID) == ["open", "pin"])
}

@Test
func finderResponseWithOnlyUnknownIDsBecomesNoMatch() {
    let response = AgenticFinderResponse(
        message: "I found something.",
        matches: [
            AgenticFinderMatch(
                sessionID: "unknown",
                reason: "Invented",
                confidence: 0.8,
                open: true,
                pin: true
            ),
        ]
    )

    let sanitized = response.sanitized(for: [])

    #expect(sanitized.matches.isEmpty)
    #expect(sanitized.message == "No matching conversations were found.")
}

@Test
@MainActor
func finderModelLoadsCandidatesAndPublishesTheRealResponse() async throws {
    let response = AgenticFinderResponse(
        message: "I found one conversation.",
        matches: [
            AgenticFinderMatch(
                sessionID: "session",
                reason: "The first prompt mentions tabs.",
                confidence: 0.95,
                open: false,
                pin: false
            ),
        ]
    )
    let finder = FinderStub(response: response)
    let model = AgenticConversationFinderModel(finder: finder)
    model.query = "where did I debug slow tabs?"

    model.submit {
        [
            AgenticFinderCandidate(
                id: "session",
                title: "Slow tabs",
                project: "Conan Code",
                lastActivity: nil,
                archived: true,
                pinned: false,
                excerpt: "Changing tabs gets slower in old conversations."
            ),
        ]
    }

    for _ in 0..<100 {
        if model.state == .results(response) { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.state == .results(response))
    let requests = await finder.requests
    #expect(requests.first?.query == "where did I debug slow tabs?")
    #expect(requests.first?.candidates.first?.archived == true)
}

@Test
func realFinderProcessUsesStructuredOutputAndDeletesItsSession() async throws {
    let fixture = try TestGrokFixture.make(
        script: #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys

        with open(os.environ["FAKE_GROK_LOG"], "a", encoding="utf-8") as log:
            log.write(json.dumps(sys.argv[1:]) + "\n")
        if sys.argv[1:3] == ["sessions", "delete"]:
            sys.exit(0)
        print(json.dumps({
            "structuredOutput": {
                "message": "I found one conversation.",
                "matches": [{
                    "sessionID": "session-real-path",
                    "reason": "The first prompt mentions slow tabs.",
                    "confidence": 0.9,
                    "open": True,
                    "pin": False
                }]
            }
        }))
        """#
    )
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let log = fixture.directory.appendingPathComponent("fake-grok.log")
    let finder = GrokAgenticConversationFinder(
        executable: fixture.executable,
        supportDirectory: fixture.directory,
        environment: ["FAKE_GROK_LOG": log.path]
    )

    let response = try await finder.find(
        AgenticFinderRequest(
            query: "open the slow tabs conversation",
            candidates: [
                AgenticFinderCandidate(
                    id: "session-real-path",
                    title: "Slow tabs",
                    project: "Conan Code",
                    lastActivity: nil,
                    archived: true,
                    pinned: false,
                    excerpt: "Changing tabs gets slower."
                ),
            ]
        )
    )

    #expect(response.matches.first?.sessionID == "session-real-path")
    let invocations = try String(contentsOf: log, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    #expect(invocations.count == 2)
    #expect(invocations[0].contains("--json-schema"))
    #expect(invocations[0].contains("--no-memory"))
    #expect(invocations[0].contains("--no-subagents"))
    #expect(invocations[0].contains("--disable-web-search"))
    #expect(invocations[0].contains("--disallowed-tools"))
    #expect(!invocations[0].contains("--always-approve"))
    #expect(invocations[1].prefix(2) == ["sessions", "delete"])
}

@Test
func remoteExcerptLoadingRunsQuotedGrokExportAndUsesTranscriptContext() {
    final class Runner: RemoteCommandRunning, @unchecked Sendable {
        private(set) var commands: [String] = []
        func run(
            remoteCommand: String,
            timeout: Duration
        ) throws -> RemoteCommandResult {
            commands.append(remoteCommand)
            return RemoteCommandResult(
                standardOutput: """
                ## User
                Find the remote deployment issue.

                ## Assistant
                We traced it to the SSH leader.
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
    }
    let runner = Runner()

    let excerpts = GrokConversationExcerptLoader.remoteExcerpts(
        for: ["session-remote"],
        executablePath: "/Users/test/bin/grok",
        runner: runner
    )

    #expect(runner.commands == [
        "'/Users/test/bin/grok' 'export' 'session-remote'",
    ])
    #expect(excerpts["session-remote"]?.contains("remote deployment") == true)
    #expect(excerpts["session-remote"]?.contains("SSH leader") == true)
}

@Test
func excerptLoadingIsBoundedDrainsPipesAndCanBeCancelled() async throws {
    let fixture = try TestGrokFixture.make(
        script: #"""
        #!/usr/bin/env python3
        import fcntl
        import os
        import sys
        import time

        state_path = os.environ["FAKE_EXPORT_STATE"]
        with open(state_path, "a+", encoding="utf-8") as state:
            fcntl.flock(state, fcntl.LOCK_EX)
            state.seek(0)
            values = [int(value) for value in state.read().split() or ["0", "0"]]
            active = values[0] + 1
            maximum = max(values[1], active)
            state.seek(0)
            state.truncate()
            state.write(f"{active} {maximum}")
            state.flush()
            fcntl.flock(state, fcntl.LOCK_UN)
        try:
            sys.stderr.write("e" * 131072)
            sys.stderr.flush()
            print("## User")
            print(f"first prompt for {sys.argv[2]}")
            print("## Assistant")
            time.sleep(10)
        finally:
            with open(state_path, "r+", encoding="utf-8") as state:
                fcntl.flock(state, fcntl.LOCK_EX)
                values = [int(value) for value in state.read().split()]
                state.seek(0)
                state.truncate()
                state.write(f"{max(0, values[0] - 1)} {values[1]}")
                state.flush()
                fcntl.flock(state, fcntl.LOCK_UN)
        """#
    )
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let state = fixture.directory.appendingPathComponent("state.txt")
    try Data("0 0".utf8).write(to: state)
    let loader = GrokConversationExcerptLoader(
        executable: fixture.executable,
        environment: ["FAKE_EXPORT_STATE": state.path]
    )

    let task = Task {
        await loader.excerpts(for: (0..<12).map { "session-\($0)" })
    }
    for _ in 0..<200 {
        let values = try String(contentsOf: state, encoding: .utf8)
            .split(separator: " ")
            .compactMap { Int($0) }
        if values.first == 4 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    let result = await task.value

    #expect(result.isEmpty)
    let values = try String(contentsOf: state, encoding: .utf8)
        .split(separator: " ")
        .compactMap { Int($0) }
    #expect(values.last == 4)
}

@Test
@MainActor
func closingFinderClearsItsEphemeralTranscriptState() {
    let finder = FinderStub(
        response: AgenticFinderResponse(message: "Done", matches: [])
    )
    let model = AgenticConversationFinderModel(finder: finder)
    model.query = "temporary question"

    model.reset()

    #expect(model.query.isEmpty)
    #expect(model.state == .idle)
}

@Test
@MainActor
func resetGenerationRejectsALateFinderResponse() async throws {
    let finder = LateFinderStub()
    let model = AgenticConversationFinderModel(finder: finder)
    model.query = "temporary question"
    model.submit { [] }
    try await finder.waitUntilStarted()

    model.reset()
    finder.resolve(
        AgenticFinderResponse(
            message: "Late result",
            matches: [
                AgenticFinderMatch(
                    sessionID: "session",
                    reason: "Late",
                    confidence: 0.8,
                    open: false,
                    pin: false
                ),
            ]
        )
    )
    try await Task.sleep(for: .milliseconds(20))

    #expect(finder.cancelWasCalled)
    #expect(model.query.isEmpty)
    #expect(model.state == .idle)
}
