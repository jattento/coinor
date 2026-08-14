import Foundation
import Testing

@testable import Coinor

/// Grok offloads any prompt past this many bytes to a file and instructs the
/// model to read it back (`LARGE_PROMPT_THRESHOLD` in
/// `crates/codegen/xai-grok-shell/src/session/acp_session_impl/prompt_build.rs`).
/// The finder used to sail past it with the whole catalog inlined, so hundreds
/// of conversations arrived truncated and it answered from the fragment.
private let grokLargePromptThreshold = 25_000

private func candidate(
    _ index: Int,
    transcript: Bool = true
) -> AgenticFinderCandidate {
    AgenticFinderCandidate(
        id: "0199f000-0000-7000-8000-\(String(format: "%012d", index))",
        title: "Conversation number \(index) about deployments and rent rolls",
        project: "project-\(index % 30)",
        lastActivity: "2026-08-\(String(format: "%02d", index % 28 + 1))T12:00:00Z",
        archived: index % 7 == 0,
        pinned: index % 11 == 0,
        transcriptPath: transcript
            ? "/Users/someone/.grok/sessions/%2Fwork/session-\(index)/chat_history.jsonl"
            : nil
    )
}

@Test
func finderPromptSizeDoesNotGrowWithTheConversationCatalog() {
    let indexPath = "/Users/someone/Library/Application Support/Coinor"
        + "/AgenticFinder/0199/conversations.jsonl"
    let query = "find yesterday's remote-host conversation and open it"

    let small = AgenticFinderPrompt.text(query: query, indexPath: indexPath)
    let large = AgenticFinderPrompt.text(query: query, indexPath: indexPath)

    // Same prompt regardless of how many conversations exist, because the
    // catalog is named rather than carried.
    #expect(small == large)
    #expect(small.utf8.count < grokLargePromptThreshold / 2)
    #expect(small.contains(indexPath))
    #expect(small.contains(query))
}

@Test
func aHugeCatalogStaysOutOfThePromptAndInsideTheIndexFile() {
    let candidates = (0..<500).map { candidate($0) }
    let lines = AgenticFinderIndex.lines(for: candidates)
    let prompt = AgenticFinderPrompt.text(
        query: "the daily standup one",
        indexPath: "/tmp/x/conversations.jsonl"
    )

    // The catalog is genuinely large — this is the payload that used to be
    // pasted into the prompt.
    #expect(lines.utf8.count > grokLargePromptThreshold)
    // And the prompt is nowhere near the offload threshold.
    #expect(prompt.utf8.count < grokLargePromptThreshold / 2)
    #expect(!prompt.contains(candidates[0].id))
}

@Test
func indexIsOneParseableJSONObjectPerCandidate() throws {
    let candidates = (0..<25).map { candidate($0) }
    let lines = AgenticFinderIndex.lines(for: candidates)
        .split(separator: "\n", omittingEmptySubsequences: true)

    #expect(lines.count == candidates.count)
    let decoder = JSONDecoder()
    for (line, expected) in zip(lines, candidates) {
        // Each line stands alone, which is what makes the file greppable and
        // parseable a row at a time.
        #expect(!line.contains("\n"))
        let decoded = try decoder.decode(
            AgenticFinderCandidate.self,
            from: Data(line.utf8)
        )
        #expect(decoded == expected)
    }
}

@Test
func remoteConversationsCarryAnExcerptBecauseTheirTranscriptIsNotLocal() throws {
    let local = candidate(1)
    let remote = AgenticFinderCandidate(
        id: "0199f000-0000-7000-8000-000000009999",
        title: "Deploy on the work mac",
        project: "work-mac:/srv/app",
        lastActivity: "2026-08-13T12:00:00Z",
        archived: false,
        pinned: false,
        remoteHost: "work-mac",
        excerpt: "We restarted the SSH leader after the deployment."
    )

    let lines = AgenticFinderIndex.lines(for: [local, remote])
        .split(separator: "\n", omittingEmptySubsequences: true)
    let decoder = JSONDecoder()
    let decodedLocal = try decoder.decode(
        AgenticFinderCandidate.self,
        from: Data(lines[0].utf8)
    )
    let decodedRemote = try decoder.decode(
        AgenticFinderCandidate.self,
        from: Data(lines[1].utf8)
    )

    #expect(decodedLocal.transcriptPath != nil)
    #expect(decodedLocal.remoteHost == nil)
    #expect(decodedLocal.excerpt == nil)

    #expect(decodedRemote.transcriptPath == nil)
    #expect(decodedRemote.remoteHost == "work-mac")
    #expect(
        decodedRemote.excerpt
            == "We restarted the SSH leader after the deployment."
    )
}

/// The finder is allowed to look and nothing else. Reading is the feature; the
/// process additionally runs with `--permission-mode plan`, no memory, no
/// subagents, and no web search.
@Test
func finderMayOnlyReadAndSearch() {
    let allowed = Set(GrokAgenticConversationFinder.allowedTools)

    #expect(allowed == ["read_file", "grep", "list_dir"])
    for denied in [
        "bash", "run_terminal_cmd", "write", "edit", "search_replace",
        "task", "Agent", "web_search", "web_fetch", "workflow", "use_tool",
    ] {
        #expect(!allowed.contains(denied))
    }
}

@Test
func transcriptLocatorMapsSessionIdentifiersToTheirChatHistory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CoinorSessions-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }

    // Grok keys these directories by URL-encoded working directory, which is
    // exactly why the path cannot be derived from a session ID.
    let withTranscript = root
        .appendingPathComponent("%2Fwork%2Fapp", isDirectory: true)
        .appendingPathComponent("session-a", isDirectory: true)
    let otherWorkingDirectory = root
        .appendingPathComponent("%2Fhome%2Fother", isDirectory: true)
        .appendingPathComponent("session-b", isDirectory: true)
    let withoutTranscript = root
        .appendingPathComponent("%2Fwork%2Fapp", isDirectory: true)
        .appendingPathComponent("session-c", isDirectory: true)
    for directory in [withTranscript, otherWorkingDirectory, withoutTranscript] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
    for directory in [withTranscript, otherWorkingDirectory] {
        try "{}\n".write(
            to: directory.appendingPathComponent(
                GrokSessionTranscriptLocator.transcriptFileName
            ),
            atomically: true,
            encoding: .utf8
        )
    }

    let paths = GrokSessionTranscriptLocator(root: root).transcriptPaths()

    #expect(paths.count == 2)
    // Compared by suffix and readability: under `/var/folders` the enumerated
    // path comes back `/private`-prefixed while the constructed URL does not.
    let sessionA = try #require(paths["session-a"])
    let sessionB = try #require(paths["session-b"])
    #expect(sessionA.hasSuffix("/%2Fwork%2Fapp/session-a/chat_history.jsonl"))
    #expect(sessionB.hasSuffix("/%2Fhome%2Fother/session-b/chat_history.jsonl"))
    #expect(FileManager.default.isReadableFile(atPath: sessionA))
    #expect(FileManager.default.isReadableFile(atPath: sessionB))
    #expect(paths["session-c"] == nil)
}

@Test
func transcriptLocatorRootFollowsGrokHome() {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    let standard = GrokSessionTranscriptLocator.defaultRoot(
        environment: [:],
        homeDirectory: home
    )
    let relocated = GrokSessionTranscriptLocator.defaultRoot(
        environment: ["GROK_HOME": "/opt/grok-home"],
        homeDirectory: home
    )
    let ignoredRelative = GrokSessionTranscriptLocator.defaultRoot(
        environment: ["GROK_HOME": "relative/path"],
        homeDirectory: home
    )

    #expect(standard.path == "/Users/someone/.grok/sessions")
    #expect(relocated.path == "/opt/grok-home/sessions")
    #expect(ignoredRelative.path == "/Users/someone/.grok/sessions")
}

@Test
func transcriptLocatorSurvivesAMissingSessionsRoot() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoinorMissing-\(UUID().uuidString)")

    #expect(GrokSessionTranscriptLocator(root: missing).transcriptPaths().isEmpty)
}
