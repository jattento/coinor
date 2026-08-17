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

/// What the fake Grok saw of the workspace it was started in.
private struct FakeGrokReport: Decodable {
    let cwd: String
    let prompt: String
    let index: String
    let workspaceMode: String
    let transcriptsMode: String
    let indexMode: String
    let transcripts: [String: String]
}

/// A fake Grok that records its arguments and everything reachable from the
/// workspace it was handed, so a test can assert what the finder exposes.
private let reportingGrokScript = #"""
#!/usr/bin/env python3
import json
import os
import stat
import sys

argv = sys.argv[1:]
with open(os.environ["FAKE_GROK_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(argv) + "\n")
if argv[:2] == ["sessions", "delete"]:
    sys.exit(0)

cwd = os.getcwd()
prompt = argv[argv.index("-p") + 1]
index_path = [
    line.strip() for line in prompt.splitlines()
    if line.strip().endswith("conversations.jsonl")
][0]
with open(index_path, encoding="utf-8") as index:
    index_body = index.read()

transcripts_dir = os.path.join(cwd, "transcripts")
transcripts = {}
for name in sorted(os.listdir(transcripts_dir)):
    with open(os.path.join(transcripts_dir, name), encoding="utf-8") as handle:
        transcripts[name] = handle.read()

def mode(path):
    return oct(stat.S_IMODE(os.stat(path).st_mode))

with open(
    os.path.join(os.environ["FAKE_GROK_HOME"], "report.json"),
    "w",
    encoding="utf-8",
) as out:
    json.dump({
        "cwd": cwd,
        "prompt": prompt,
        "index": index_body,
        "workspaceMode": mode(cwd),
        "transcriptsMode": mode(transcripts_dir),
        "indexMode": mode(index_path),
        "transcripts": transcripts,
    }, out)

if os.environ.get("FAKE_GROK_FAIL") == "1":
    sys.stderr.write("fake grok refused to search\n")
    sys.exit(1)

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

private struct TestGrokFixture {
    let directory: URL
    let executable: GrokExecutable

    /// Where the finder puts one search's workspace, so a test can prove the
    /// workspace is gone once the search is over.
    var finderRoot: URL {
        directory.appendingPathComponent("AgenticFinder", isDirectory: true)
    }

    func remainingWorkspaces() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: finderRoot,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    func report() throws -> FakeGrokReport {
        try JSONDecoder().decode(
            FakeGrokReport.self,
            from: Data(
                contentsOf: directory.appendingPathComponent("report.json")
            )
        )
    }

    func writeTranscript(_ name: String, body: String) throws -> String {
        let url = directory.appendingPathComponent(
            "\(name)-chat_history.jsonl",
            isDirectory: false
        )
        try Data(body.utf8).write(to: url)
        return url.path
    }

    func finder(failing: Bool = false) -> GrokAgenticConversationFinder {
        GrokAgenticConversationFinder(
            executable: executable,
            supportDirectory: directory,
            environment: [
                "FAKE_GROK_LOG": directory
                    .appendingPathComponent("fake-grok.log").path,
                "FAKE_GROK_HOME": directory.path,
                "FAKE_GROK_FAIL": failing ? "1" : "0",
            ]
        )
    }

    func invocations() throws -> [[String]] {
        try String(
            contentsOf: directory.appendingPathComponent("fake-grok.log"),
            encoding: .utf8
        )
        .split(separator: "\n")
        .map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

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
    let fixture = try TestGrokFixture.make(script: reportingGrokScript)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let transcript = try fixture.writeTranscript(
        "slow-tabs",
        body: #"{"type":"user","content":"changing tabs got slow"}"# + "\n"
    )
    let finder = fixture.finder()

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
                    transcriptPath: transcript
                ),
            ]
        )
    )

    #expect(response.matches.first?.sessionID == "session-real-path")
    let invocations = try fixture.invocations()
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

    let report = try fixture.report()
    let indexed = try JSONDecoder().decode(
        AgenticFinderCandidate.self,
        from: Data(report.index.split(separator: "\n")[0].utf8)
    )
    #expect(indexed.id == "session-real-path")
    #expect(indexed.title == "Slow tabs")
    // The index names the copy inside the workspace, never the transcript
    // where it lives: a path outside the workspace is a path the agent could
    // be talked into following.
    let indexedPath = try #require(indexed.transcriptPath)
    #expect(indexedPath.hasPrefix(fixture.finderRoot.path + "/"))
    #expect(indexedPath != transcript)
    #expect(!report.index.contains(transcript))
    #expect(!prompt.contains(transcript))
}

/// The denylist alone was fail-open: `read_file`, `grep`, and `list_dir`
/// survived it, so any transcript could talk the agent into reading a secret
/// somewhere else on disk. The allowlist is the control that closes it.
@Test
func finderStartsGrokWithTheToolAllowlistAndKeepsTheDenylist() async throws {
    let fixture = try TestGrokFixture.make(script: reportingGrokScript)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    _ = try await fixture.finder().find(
        AgenticFinderRequest(
            query: "the slow tabs one",
            candidates: [
                AgenticFinderCandidate(
                    id: "session-real-path",
                    title: "Slow tabs",
                    project: "Conan Code",
                    lastActivity: nil,
                    archived: false,
                    pinned: false,
                    transcriptPath: try fixture.writeTranscript(
                        "slow-tabs",
                        body: "{}\n"
                    )
                ),
            ]
        )
    )

    let search = try #require(fixture.invocations().first)
    let allowlist = try #require(search.firstIndex(of: "--tools"))
    #expect(
        search[search.index(after: allowlist)]
            == GrokAgenticConversationFinder.allowedTools
                .joined(separator: ",")
    )
    let denylist = try #require(search.firstIndex(of: "--disallowed-tools"))
    let denied = search[search.index(after: denylist)]
        .split(separator: ",")
        .map { String($0) }
    for tool in ["run_terminal_cmd", "web_fetch", "search_replace", "Agent"] {
        #expect(denied.contains(tool))
    }
    for tool in GrokAgenticConversationFinder.allowedTools {
        #expect(!denied.contains(tool))
    }
}

@Test
func finderWorkspaceIsPrivateHoldsOnlyCopiesAndIsRemovedAfterwards() async throws {
    let fixture = try TestGrokFixture.make(script: reportingGrokScript)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let body = #"{"type":"user","content":"changing tabs got slow"}"# + "\n"
    let transcript = try fixture.writeTranscript("slow-tabs", body: body)

    _ = try await fixture.finder().find(
        AgenticFinderRequest(
            query: "the slow tabs one",
            candidates: [
                AgenticFinderCandidate(
                    id: "session-real-path",
                    title: "Slow tabs",
                    project: "Conan Code",
                    lastActivity: nil,
                    archived: false,
                    pinned: false,
                    transcriptPath: transcript
                ),
                AgenticFinderCandidate(
                    id: "session-unreadable",
                    title: "Gone",
                    project: "Conan Code",
                    lastActivity: nil,
                    archived: false,
                    pinned: false,
                    transcriptPath: fixture.directory
                        .appendingPathComponent("missing.jsonl").path
                ),
            ]
        )
    )

    let report = try fixture.report()
    // Explicit 0700/0600, not whatever the process umask happened to be: the
    // workspace holds copies of the user's conversations.
    #expect(report.workspaceMode == "0o700")
    #expect(report.transcriptsMode == "0o700")
    #expect(report.indexMode == "0o600")
    // Exactly one copy — the candidate whose transcript could not be read is
    // indexed without a path rather than pointed at a file that is not there.
    #expect(report.transcripts.count == 1)
    #expect(report.transcripts.values.first == body)
    let indexed = try report.index
        .split(separator: "\n")
        .map {
            try JSONDecoder().decode(
                AgenticFinderCandidate.self,
                from: Data($0.utf8)
            )
        }
    #expect(indexed.count == 2)
    #expect(indexed[0].transcriptPath != nil)
    #expect(indexed[1].transcriptPath == nil)

    #expect(fixture.remainingWorkspaces().isEmpty)
}

@Test
func finderRemovesItsWorkspaceWhenTheSearchFails() async throws {
    let fixture = try TestGrokFixture.make(script: reportingGrokScript)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    await #expect(throws: AgenticFinderError.self) {
        try await fixture.finder(failing: true).find(
            AgenticFinderRequest(
                query: "the slow tabs one",
                candidates: [
                    AgenticFinderCandidate(
                        id: "session-real-path",
                        title: "Slow tabs",
                        project: "Conan Code",
                        lastActivity: nil,
                        archived: false,
                        pinned: false,
                        transcriptPath: try fixture.writeTranscript(
                            "slow-tabs",
                            body: "{}\n"
                        )
                    ),
                ]
            )
        )
    }

    #expect(fixture.remainingWorkspaces().isEmpty)
}

@Test
func finderBoundsTheTranscriptCopiesItPlacesInItsWorkspace() async throws {
    let fixture = try TestGrokFixture.make(script: reportingGrokScript)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let line = #"{"type":"user","content":"padding padding padding padding"}"#
    let huge = Array(repeating: line, count: 6_000).joined(separator: "\n")
        + "\n"
    #expect(
        huge.utf8.count
            > AgenticFinderTranscriptExcerpt.maximumTranscriptBytes * 4
    )

    _ = try await fixture.finder().find(
        AgenticFinderRequest(
            query: "the padded one",
            candidates: [
                AgenticFinderCandidate(
                    id: "session-real-path",
                    title: "Padded",
                    project: "Conan Code",
                    lastActivity: nil,
                    archived: false,
                    pinned: false,
                    transcriptPath: try fixture.writeTranscript(
                        "padded",
                        body: huge
                    )
                ),
            ]
        )
    )

    let copied = try #require(fixture.report().transcripts.values.first)
    #expect(
        copied.utf8.count
            <= AgenticFinderTranscriptExcerpt.maximumTranscriptBytes
                + AgenticFinderTranscriptExcerpt.truncationNotice.utf8.count
                + 2
    )
    let lines = copied.split(separator: "\n")
    // Cut on a line boundary and said so, so the copy stays parseable as JSONL
    // and the finder can report that it did not see everything.
    #expect(
        String(lines.last ?? "")
            == AgenticFinderTranscriptExcerpt.truncationNotice
    )
    #expect(lines.dropLast().allSatisfy { String($0) == line })
}

@Test
func transcriptCopyNamesCannotEscapeTheWorkspace() {
    for hostile in [
        "../../../etc/passwd",
        "..",
        "/absolute/secret",
        "a/b",
        "",
        "session id with spaces",
    ] {
        let name = AgenticFinderTranscriptExcerpt.fileName(
            order: 3,
            sessionID: hostile
        )
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
        #expect(name.hasPrefix("0003"))
        #expect(name.hasSuffix(".jsonl"))
    }
}

@Test
func transcriptExcerptsAreStrippedOfControlCharacters() {
    let bounded = AgenticFinderTranscriptExcerpt.bounded(
        "clean\u{1B}[31m text\u{0}\u{7}\nsecond\tline\n",
        maximumBytes: 1_000
    )

    #expect(bounded == "clean[31m text\nsecond\tline\n")
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
