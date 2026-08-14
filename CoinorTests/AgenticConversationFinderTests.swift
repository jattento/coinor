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
        argv = sys.argv[1:]
        prompt = argv[argv.index("-p") + 1]
        index_path = [
            line.strip() for line in prompt.splitlines()
            if line.strip().endswith("conversations.jsonl")
        ][0]
        with open(index_path, encoding="utf-8") as index:
            body = index.read()
        with open(
            os.path.join(os.environ["FAKE_GROK_HOME"], "captured-index"),
            "w",
            encoding="utf-8",
        ) as out:
            out.write(body)
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
        environment: [
            "FAKE_GROK_LOG": log.path,
            "FAKE_GROK_HOME": fixture.directory.path,
        ]
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
                    transcriptPath: "/tmp/does-not-matter/chat_history.jsonl"
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

    // The catalog must reach the finder as a file it can grep, never inlined in
    // the prompt: Grok offloads an oversized prompt to disk and asks the model
    // to read it back, which this finder used to be forbidden from doing.
    let promptIndex = try #require(invocations[0].firstIndex(of: "-p"))
    let prompt = invocations[0][invocations[0].index(after: promptIndex)]
    #expect(prompt.contains(AgenticFinderIndex.fileName))
    #expect(!prompt.contains("Changing tabs gets slower."))
    #expect(prompt.utf8.count < 8_000)

    let capturedIndex = try String(
        contentsOf: fixture.directory.appendingPathComponent("captured-index"),
        encoding: .utf8
    )
    let indexed = try JSONDecoder().decode(
        AgenticFinderCandidate.self,
        from: Data(capturedIndex.split(separator: "\n")[0].utf8)
    )
    #expect(indexed.id == "session-real-path")
    #expect(indexed.title == "Slow tabs")
    #expect(indexed.transcriptPath == "/tmp/does-not-matter/chat_history.jsonl")
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "COINOR_RUN_LIVE_AGENTIC_FINDER"
        ] == "1"
    ),
    .timeLimit(.minutes(5))
)
func liveInstalledGrokFinderListsOpensPinsAndCleansWorkspaces() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let grokURL = home
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("grok")
    let executable = try GrokExecutable.resolve(
        configuredPath: grokURL.path
    )
    let supportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CoinorLiveAgenticFinder-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: supportDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: supportDirectory) }

    let finder = GrokAgenticConversationFinder(
        executable: executable,
        supportDirectory: supportDirectory
    )
    let token = "coinor-live-finder-\(UUID().uuidString.lowercased())"
    // Real transcripts on disk, so the live run exercises what the finder
    // actually does now: read the index, then grep the files it names.
    func writeTranscript(_ name: String, body: String) throws -> String {
        let url = supportDirectory.appendingPathComponent(
            "\(name)-chat_history.jsonl",
            isDirectory: false
        )
        try #"{"type":"user","content":"\#(body)"}"# .replacingOccurrences(
            of: "\n",
            with: " "
        ).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
    let candidates = [
        AgenticFinderCandidate(
            id: "active-live-candidate",
            title: "Active \(token)",
            project: "Coinor",
            lastActivity: "2026-08-13T05:00:00Z",
            archived: false,
            pinned: false,
            transcriptPath: try writeTranscript(
                "active",
                body: "Active conversation about \(token)."
            )
        ),
        AgenticFinderCandidate(
            id: "archived-live-candidate",
            title: "Archived \(token)",
            project: "Coinor",
            lastActivity: "2026-08-12T05:00:00Z",
            archived: true,
            pinned: false,
            transcriptPath: try writeTranscript(
                "archived",
                body: "Archived conversation about \(token)."
            )
        ),
    ]

    var metadata = MetadataDocument.empty
    metadata.setSessionArchived("archived-live-candidate", archived: true)
    metadata.setProjectArchived("coinor-live-project", archived: true)
    let archivedSummary = SessionSummary(
        id: "archived-live-candidate",
        projectID: "coinor-live-project",
        title: "Archived \(token)"
    )
    let activeSummary = SessionSummary(
        id: "active-live-candidate",
        projectID: "coinor-live-project",
        title: "Active \(token)"
    )

    let listing = try await finder.find(
        AgenticFinderRequest(
            query: "Find the conversations about \(token), but do not open or pin anything.",
            candidates: candidates
        )
    )
    #expect(
        Set(listing.matches.map(\.sessionID)).isSuperset(
            of: ["active-live-candidate", "archived-live-candidate"]
        )
    )
    #expect(listing.matches.allSatisfy { !$0.open && !$0.pin })
    let beforeListing = metadata
    listing.matches.forEach {
        AgenticFinderActionPlan.resolve(
            match: $0,
            summary: $0.sessionID == archivedSummary.id
                ? archivedSummary
                : activeSummary,
            metadata: metadata
        ).apply(to: &metadata)
    }
    #expect(metadata == beforeListing)

    let opening = try await finder.find(
        AgenticFinderRequest(
            query: "Open the archived conversation about \(token).",
            candidates: candidates
        )
    )
    let archived = try #require(
        opening.matches.first { $0.sessionID == "archived-live-candidate" }
    )
    #expect(archived.open)
    #expect(!archived.pin)
    let openingPlan = AgenticFinderActionPlan.resolve(
        match: archived,
        summary: archivedSummary,
        metadata: metadata
    )
    #expect(openingPlan.shouldOpen)
    #expect(openingPlan.shouldUnarchiveConversation)
    #expect(openingPlan.shouldUnarchiveProject)
    openingPlan.apply(to: &metadata)
    #expect(!metadata.isSessionArchived(archivedSummary.id))
    #expect(!metadata.isProjectArchived(archivedSummary.projectID))
    #expect(!metadata.isSessionPinned(archivedSummary.id))

    let pinning = try await finder.find(
        AgenticFinderRequest(
            query: "Pin the active conversation about \(token), but do not open it.",
            candidates: candidates
        )
    )
    let active = try #require(
        pinning.matches.first { $0.sessionID == "active-live-candidate" }
    )
    #expect(!active.open)
    #expect(active.pin)
    let pinningPlan = AgenticFinderActionPlan.resolve(
        match: active,
        summary: activeSummary,
        metadata: metadata
    )
    #expect(!pinningPlan.shouldOpen)
    #expect(pinningPlan.shouldPin)
    pinningPlan.apply(to: &metadata)
    #expect(metadata.isSessionPinned(activeSummary.id))

    let finderRoot = supportDirectory.appendingPathComponent(
        "AgenticFinder",
        isDirectory: true
    )
    let remainingWorkspaces = try FileManager.default.contentsOfDirectory(
        at: finderRoot,
        includingPropertiesForKeys: nil
    )
    #expect(remainingWorkspaces.isEmpty)
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
