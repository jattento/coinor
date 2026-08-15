import Foundation

struct AgenticFinderCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let project: String
    let lastActivity: String?
    let archived: Bool
    let pinned: Bool
    /// Absolute path to this conversation's Grok chat history, when it lives on
    /// this computer. The finder greps and reads it instead of receiving the
    /// transcript through its prompt.
    let transcriptPath: String?
    /// Set when the conversation belongs to a remote computer, whose transcript
    /// is not readable from here.
    let remoteHost: String?
    /// Only carried for a remote conversation, where there is no local file to
    /// search. Local conversations leave this empty by design.
    let excerpt: String?

    init(
        id: String,
        title: String,
        project: String,
        lastActivity: String?,
        archived: Bool,
        pinned: Bool,
        transcriptPath: String? = nil,
        remoteHost: String? = nil,
        excerpt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.lastActivity = lastActivity
        self.archived = archived
        self.pinned = pinned
        self.transcriptPath = transcriptPath
        self.remoteHost = remoteHost
        self.excerpt = excerpt
    }
}

struct AgenticFinderRequest: Codable, Equatable, Sendable {
    let query: String
    let candidates: [AgenticFinderCandidate]
}

/// The candidate catalog, written to a file the finder reads for itself.
///
/// Conversations used to travel inside the prompt. That does not scale: Grok
/// offloads any prompt past a fixed size to a file and asks the model to read
/// it back, so a few hundred conversations silently arrived truncated and the
/// finder answered from whatever survived. The catalog is a file now, and the
/// prompt only names it, so prompt size no longer depends on how many
/// conversations exist.
enum AgenticFinderIndex {
    static let fileName = "conversations.jsonl"

    /// One JSON object per line: greppable as text, parseable line by line, and
    /// immune to the escaping problems a flat table would have with transcript
    /// titles.
    static func lines(for candidates: [AgenticFinderCandidate]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rows = candidates.compactMap { candidate -> String? in
            guard let data = try? encoder.encode(candidate) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

/// The finder's instructions. Fixed size: it names the index instead of
/// carrying it, so the prompt is the same length for ten conversations and for
/// ten thousand.
enum AgenticFinderPrompt {
    static func text(query: String, indexPath: String) -> String {
        """
        You are Conan Code's conversation finder.

        The user is looking for: \(query)

        Every candidate conversation is one JSON object per line in this file:
        \(indexPath)

        Fields: `id`, `title`, `project`, `lastActivity` (ISO 8601), `archived`, \
        `pinned`, and then either `transcriptPath` — an absolute path to that \
        conversation's chat history, which you may grep and read — or \
        `remoteHost` plus a short `excerpt`, for a conversation that lives on \
        another computer and whose transcript you cannot read from here.

        How to work:
        1. Read the index file.
        2. Shortlist on title, project, and recency.
        3. Grep the `transcriptPath` files to confirm a shortlisted candidate \
        or to find one whose title does not mention what the user asked for. \
        The transcripts are JSONL and the matches are noisy; that is expected.
        4. Read a transcript only when grep alone is not enough.

        Rules: return at most five matches, and only `id` values that appear in \
        the index. Never invent a session ID. Set `open` to true only when the \
        user explicitly asks to open, show, or take them to a conversation. Set \
        `pin` to true only when they explicitly ask to pin it. An archived match \
        may still be returned; Conan Code will unarchive it only when `open` is \
        true. Merely listing or finding results must not mutate anything.

        Write a concise English message. If some conversations could not be \
        searched — a remote host, or an unreadable transcript — say so rather \
        than implying the search was complete.
        """
    }
}

struct AgenticFinderMatch: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let reason: String
    let confidence: Double
    let open: Bool
    let pin: Bool

    var id: String { sessionID }
}

struct AgenticFinderResponse: Codable, Equatable, Sendable {
    let message: String
    let matches: [AgenticFinderMatch]
}

struct AgenticFinderActionPlan: Equatable, Sendable {
    let sessionID: String
    let projectID: String
    let shouldOpen: Bool
    let shouldPin: Bool
    let shouldUnarchiveConversation: Bool
    let shouldUnarchiveProject: Bool

    static func resolve(
        match: AgenticFinderMatch,
        summary: SessionSummary,
        metadata: MetadataDocument
    ) -> AgenticFinderActionPlan {
        AgenticFinderActionPlan(
            sessionID: summary.id,
            projectID: summary.projectID,
            shouldOpen: match.open,
            shouldPin: match.pin && !metadata.isSessionPinned(summary.id),
            shouldUnarchiveConversation: match.open
                && metadata.isSessionArchived(summary.id),
            shouldUnarchiveProject: match.open
                && metadata.isProjectArchived(summary.projectID)
        )
    }

    func apply(to document: inout MetadataDocument) {
        if shouldPin { document.pin(sessionID) }
        if shouldUnarchiveConversation {
            document.setSessionArchived(sessionID, archived: false)
        }
        if shouldUnarchiveProject {
            document.setProjectArchived(projectID, archived: false)
        }
    }
}

private struct AgenticFinderOutputEnvelope: Decodable {
    let structuredOutput: AgenticFinderResponse
}

enum AgenticFinderError: LocalizedError {
    case unavailable(String)
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): detail
        case .failed(let detail): detail
        case .invalidResponse:
            "Grok returned a result Conan Code could not read."
        }
    }
}

protocol AgenticConversationFinding: Sendable {
    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse
    func cancel()
}

private enum AgenticFinderProcessControl {
    static func requestTermination(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 1
        ) {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class AgenticFinderPipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private let maximumBytes: Int
    private var data = Data()
    private var finished = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                finish(handle)
            } else {
                append(chunk)
            }
        }
    }

    func waitForEOF() {
        completion.wait()
    }

    func stop(_ handle: FileHandle) {
        handle.readabilityHandler = nil
    }

    func value() -> String {
        lock.lock()
        let current = data
        lock.unlock()
        return String(decoding: current, as: UTF8.self)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        let remaining = maximumBytes - data.count
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        lock.unlock()
    }

    private func finish(_ handle: FileHandle) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        handle.readabilityHandler = nil
        completion.signal()
    }
}

private struct AgenticFinderProcessResult {
    let status: Int32
    let output: String
    let error: String
}

/// Reads the first exchanges of a conversation that lives on another
/// computer, where the finder cannot grep a local transcript.
///
/// Local conversations deliberately have no equivalent: exporting hundreds
/// of them was both slow and pointless once the finder learned to search the
/// transcripts on disk itself.
enum GrokConversationExcerptLoader {
    static func remoteExcerpts(
        for sessionIDs: [String],
        executablePath: String,
        runner: any RemoteCommandRunning
    ) -> [String: String] {
        var result: [String: String] = [:]
        for sessionID in sessionIDs where !Task.isCancelled {
            let command = ShellQuoting.command(
                [executablePath, "export", sessionID]
            )
            guard let export = try? runner.run(
                remoteCommand: command,
                timeout: .seconds(30)
            ), export.succeeded,
                  let excerpt = transcriptExcerpt(export.standardOutput) else {
                continue
            }
            result[sessionID] = excerpt
        }
        return result
    }

    private static func transcriptExcerpt(_ transcript: String) -> String? {
        let sections = transcript.components(separatedBy: "\n## ")
        let text = sections.compactMap { section -> String? in
            let normalized = section.hasPrefix("## ")
                ? String(section.dropFirst(3))
                : section
            guard normalized.hasPrefix("User\n")
                    || normalized.hasPrefix("Assistant\n") else {
                return nil
            }
            guard let newline = normalized.firstIndex(of: "\n") else {
                return nil
            }
            return normalized[normalized.index(after: newline)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(2_000))
    }
}

extension AgenticFinderResponse {
    func sanitized(
        for candidates: [AgenticFinderCandidate]
    ) -> AgenticFinderResponse {
        let candidateIDs = Set(candidates.map(\.id))
        var seen = Set<String>()
        let validMatches = matches.compactMap { match -> AgenticFinderMatch? in
            guard candidateIDs.contains(match.sessionID),
                  seen.insert(match.sessionID).inserted else {
                return nil
            }
            let confidence = match.confidence.isFinite
                ? min(max(match.confidence, 0), 1)
                : 0
            return AgenticFinderMatch(
                sessionID: match.sessionID,
                reason: match.reason,
                confidence: confidence,
                open: match.open,
                pin: match.pin
            )
        }
        if !matches.isEmpty, validMatches.isEmpty {
            return AgenticFinderResponse(
                message: "No matching conversations were found.",
                matches: []
            )
        }
        let trimmedMessage = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let safeMessage: String
        if !trimmedMessage.isEmpty {
            safeMessage = trimmedMessage
        } else if validMatches.isEmpty {
            safeMessage = "No matching conversations were found."
        } else {
            safeMessage = "Matching conversations were found."
        }
        return AgenticFinderResponse(
            message: safeMessage,
            matches: Array(validMatches.prefix(5))
        )
    }
}

extension AgenticFinderResponse {
    var explicitActions: [AgenticFinderMatch] {
        matches.filter { $0.open || $0.pin }
    }
}

extension AgenticFinderMatch {
    var requestedAction: AgenticFinderMatch {
        AgenticFinderMatch(
            sessionID: sessionID,
            reason: reason,
            confidence: confidence,
            open: open,
            pin: pin
        )
    }

    var openingAction: AgenticFinderMatch {
        AgenticFinderMatch(
            sessionID: sessionID,
            reason: reason,
            confidence: confidence,
            open: true,
            pin: false
        )
    }

    var pinningAction: AgenticFinderMatch {
        AgenticFinderMatch(
            sessionID: sessionID,
            reason: reason,
            confidence: confidence,
            open: false,
            pin: true
        )
    }
}

final class GrokAgenticConversationFinder: AgenticConversationFinding, @unchecked Sendable {
    private let executable: GrokExecutable
    private let supportDirectory: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Process?

    init(
        executable: GrokExecutable,
        supportDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.supportDirectory = supportDirectory
        self.environment = environment
    }

    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse {
        let sessionID = UUID().uuidString.lowercased()
        let workspace = supportDirectory
            .appendingPathComponent("AgenticFinder", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let indexURL = workspace.appendingPathComponent(
            AgenticFinderIndex.fileName,
            isDirectory: false
        )
        try Data(AgenticFinderIndex.lines(for: request.candidates).utf8)
            .write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: indexURL.path
        )
        let prompt = AgenticFinderPrompt.text(
            query: request.query,
            indexPath: indexURL.path
        )

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                defer {
                    deleteEphemeralSession(
                        sessionID,
                        workspace: workspace
                    )
                }
                try Task.checkCancellation()
                let result = try run(
                    arguments: [
                        "-p", prompt,
                        "--session-id", sessionID,
                        "--output-format", "json",
                        "--json-schema", Self.responseSchema,
                        "--no-memory",
                        "--no-subagents",
                        "--disable-web-search",
                        "--disallowed-tools", Self.disallowedTools,
                        "--permission-mode", "plan",
                        "--cwd", workspace.path,
                    ],
                    workingDirectory: workspace,
                    tracksCancellation: true
                )
                try Task.checkCancellation()
                guard result.status == 0 else {
                    let detail = result.error.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    throw AgenticFinderError.failed(
                        detail.isEmpty
                            ? "Grok could not search conversations."
                            : String(detail.prefix(400))
                    )
                }
                guard let data = result.output.data(using: .utf8),
                      let response = try? JSONDecoder().decode(
                        AgenticFinderOutputEnvelope.self,
                        from: data
                      ) else {
                    throw AgenticFinderError.invalidResponse
                }
                return response.structuredOutput.sanitized(
                    for: request.candidates
                )
            }.value
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let process = process
        lock.unlock()
        if let process {
            AgenticFinderProcessControl.requestTermination(process)
        }
    }

    func cleanupPendingSessions() async {
        let root = supportDirectory
            .appendingPathComponent("AgenticFinder", isDirectory: true)
        guard let workspaces = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        await Task.detached(priority: .utility) { [self] in
            for workspace in workspaces {
                let sessionID = workspace.lastPathComponent
                deleteEphemeralSession(sessionID, workspace: workspace)
            }
        }.value
    }

    private func deleteEphemeralSession(_ sessionID: String, workspace: URL) {
        guard let result = try? run(
            arguments: ["sessions", "delete", sessionID],
            workingDirectory: workspace,
            tracksCancellation: false
        ), result.status == 0 else {
            return
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    private func run(
        arguments: [String],
        workingDirectory: URL,
        tracksCancellation: Bool
    ) throws -> AgenticFinderProcessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let outputDrain = AgenticFinderPipeDrain(maximumBytes: 2 * 1024 * 1024)
        let errorDrain = AgenticFinderPipeDrain(maximumBytes: 64 * 1024)
        process.executableURL = executable.url
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        outputDrain.start(output.fileHandleForReading)
        errorDrain.start(errors.fileHandleForReading)

        do {
            try process.run()
        } catch {
            outputDrain.stop(output.fileHandleForReading)
            errorDrain.stop(errors.fileHandleForReading)
            throw AgenticFinderError.unavailable(
                "Conan Code could not start Grok conversation search."
            )
        }
        if tracksCancellation {
            lock.lock()
            self.process = process
            lock.unlock()
        }
        defer {
            if tracksCancellation {
                lock.lock()
                if self.process === process { self.process = nil }
                lock.unlock()
            }
        }
        if tracksCancellation, Task.isCancelled {
            AgenticFinderProcessControl.requestTermination(process)
        }
        process.waitUntilExit()
        outputDrain.waitForEOF()
        errorDrain.waitForEOF()
        return AgenticFinderProcessResult(
            status: process.terminationStatus,
            output: outputDrain.value(),
            error: errorDrain.value()
        )
    }

    /// `read_file`, `grep`, and `list_dir` are the finder's whole job: it
    /// searches the conversation index and the transcripts it points at. Every
    /// tool that could change something, run something, or reach the network
    /// stays denied, and the process is additionally started with
    /// `--permission-mode plan`, no memory, no subagents, and no web search.
    static let allowedTools = ["read_file", "grep", "list_dir"]

    private static let disallowedTools = [
        "run_terminal_cmd", "bash", "search_replace",
        "write", "edit", "kill_task", "todo_write",
        "get_task_output", "wait_tasks", "task", "scheduler_create",
        "scheduler_delete", "scheduler_list", "monitor", "search_tool",
        "use_tool", "update_goal", "workflow", "web_search", "web_fetch",
        "lsp", "image_gen", "image_edit", "image_to_video",
        "reference_to_video", "enter_plan_mode", "exit_plan_mode",
        "ask_user_question", "Agent",
    ].joined(separator: ",")

    private static let responseSchema = """
    {"type":"object","properties":{"message":{"type":"string"},"matches":{"type":"array","maxItems":5,"items":{"type":"object","properties":{"sessionID":{"type":"string"},"reason":{"type":"string"},"confidence":{"type":"number","minimum":0,"maximum":1},"open":{"type":"boolean"},"pin":{"type":"boolean"}},"required":["sessionID","reason","confidence","open","pin"],"additionalProperties":false}}},"required":["message","matches"],"additionalProperties":false}
    """
}

@MainActor
final class AgenticConversationFinderModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case results(AgenticFinderResponse)
        case failed(String)
    }

    @Published var query = ""
    @Published private(set) var state: State = .idle
    private let finder: any AgenticConversationFinding
    private var task: Task<Void, Never>?
    private var generation = 0

    init(finder: any AgenticConversationFinding) {
        self.finder = finder
    }

    func submit(
        loadCandidates: @escaping @MainActor () async -> [AgenticFinderCandidate],
        onResponse: @escaping @MainActor (AgenticFinderResponse) -> Void = { _ in }
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .searching else { return }
        generation += 1
        let submissionGeneration = generation
        state = .searching
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = await loadCandidates()
                try Task.checkCancellation()
                let response = try await finder.find(
                    AgenticFinderRequest(query: trimmed, candidates: candidates)
                )
                guard !Task.isCancelled,
                      generation == submissionGeneration else {
                    return
                }
                onResponse(response)
                state = .results(response)
            } catch is CancellationError {
                guard generation == submissionGeneration else { return }
                state = .idle
            } catch {
                guard !Task.isCancelled,
                      generation == submissionGeneration else {
                    return
                }
                let detail = error.localizedDescription.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                state = .failed(
                    detail.isEmpty
                        ? "Conan Code could not search conversations."
                        : detail
                )
            }
        }
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        finder.cancel()
        query = ""
        state = .idle
    }
}

/// How the sparkle toggle treats whatever is already in the fuzzy field.
///
/// The toggle is a mode switch, not a reset. A non-empty string is already
/// the request, so the panel should run it instead of asking for Return.
enum AgenticSearchActivation {
    static func shouldSubmit(carriedQuery: String) -> Bool {
        !carriedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Presentation state for the sidebar's agent-search panel.
///
/// Opening the panel, dismissing it, and the unavailable fallback are one
/// decision kept outside the view so every entry point — the toggle, the
/// panel's close button, and Escape — lands on the same code and can be
/// exercised without SwiftUI.
@MainActor
struct AgenticSearchPanelState {
    static let unavailableMessage = """
        Grok conversation search is unavailable. Check that the configured \
        Grok executable is ready.
        """

    private(set) var isPresented = false
    private(set) var model: AgenticConversationFinderModel?
    private(set) var unavailableMessage: String?

    /// True once the panel is up with a finder behind it, so the search field
    /// only accepts input it can actually run.
    var acceptsInput: Bool { isPresented && model != nil }

    /// Opens the panel around `model`, or around the unavailable explanation
    /// when Grok could not supply one.
    mutating func present(_ model: AgenticConversationFinderModel?) {
        self.model = model
        unavailableMessage = model == nil ? Self.unavailableMessage : nil
        isPresented = true
    }

    /// Opens the panel and copies the fuzzy-field text into the AI query.
    ///
    /// Returns whether that text should be submitted immediately.
    @discardableResult
    mutating func present(
        _ model: AgenticConversationFinderModel?,
        carrying query: String
    ) -> Bool {
        model?.query = query
        present(model)
        return AgenticSearchActivation.shouldSubmit(carriedQuery: query)
    }

    /// Closes the panel and cancels whatever the finder was doing.
    mutating func dismiss() {
        model?.reset()
        model = nil
        unavailableMessage = nil
        isPresented = false
    }
}
