import Foundation

struct AgenticFinderCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let project: String
    let lastActivity: String?
    let archived: Bool
    let pinned: Bool
    let excerpt: String?
}

struct AgenticFinderRequest: Codable, Equatable, Sendable {
    let query: String
    let candidates: [AgenticFinderCandidate]
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

protocol ConversationExcerptLoading: Sendable {
    func excerpts(for sessionIDs: [String]) async -> [String: String]
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

private final class AgenticFinderProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var cancelled = false

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        processes[ObjectIdentifier(process)] = process
        return true
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let current = Array(processes.values)
        lock.unlock()
        for process in current {
            AgenticFinderProcessControl.requestTermination(process)
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
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

final class GrokConversationExcerptLoader: ConversationExcerptLoading, @unchecked Sendable {
    private static let maximumConcurrentExports = 4
    private static let maximumExportCaptureBytes = 8 * 1024 * 1024
    private static let maximumErrorCaptureBytes = 16 * 1024

    let executable: GrokExecutable
    private let environment: [String: String]
    private let lock = NSLock()
    private var activeRegistry: AgenticFinderProcessRegistry?

    init(
        executable: GrokExecutable,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.environment = environment
    }

    func cancel() {
        currentRegistry()?.cancelAll()
    }

    func excerpts(for sessionIDs: [String]) async -> [String: String] {
        let registry = AgenticFinderProcessRegistry()
        replaceActiveRegistry(with: registry)?.cancelAll()
        defer { clearActiveRegistry(if: registry) }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [:] }
            return await withTaskGroup(of: (String, String?).self) { group in
                var iterator = sessionIDs.makeIterator()
                for _ in 0..<min(
                    Self.maximumConcurrentExports,
                    sessionIDs.count
                ) {
                    guard let sessionID = iterator.next() else { break }
                    group.addTask { [self, registry] in
                        (
                            sessionID,
                            firstUserExcerpt(
                                sessionID: sessionID,
                                registry: registry
                            )
                        )
                    }
                }

                var result: [String: String] = [:]
                while let (sessionID, excerpt) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        registry.cancelAll()
                        return [:]
                    }
                    if let excerpt { result[sessionID] = excerpt }
                    if let nextSessionID = iterator.next() {
                        group.addTask { [self, registry] in
                            (
                                nextSessionID,
                                firstUserExcerpt(
                                    sessionID: nextSessionID,
                                    registry: registry
                                )
                            )
                        }
                    }
                }
                return result
            }
        } onCancel: { [registry] in
            registry.cancelAll()
        }
    }

    private func currentRegistry() -> AgenticFinderProcessRegistry? {
        lock.lock()
        defer { lock.unlock() }
        return activeRegistry
    }

    private func replaceActiveRegistry(
        with registry: AgenticFinderProcessRegistry
    ) -> AgenticFinderProcessRegistry? {
        lock.lock()
        defer { lock.unlock() }
        let previous = activeRegistry
        activeRegistry = registry
        return previous
    }

    private func clearActiveRegistry(
        if registry: AgenticFinderProcessRegistry
    ) {
        lock.lock()
        if activeRegistry === registry { activeRegistry = nil }
        lock.unlock()
    }

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

    private func firstUserExcerpt(
        sessionID: String,
        registry: AgenticFinderProcessRegistry
    ) -> String? {
        guard !Task.isCancelled, !registry.isCancelled else { return nil }
        let result: AgenticFinderProcessResult
        do {
            result = try runProcess(
                arguments: ["export", sessionID],
                registry: registry
            )
        } catch {
            return nil
        }
        guard !Task.isCancelled,
              !registry.isCancelled,
              result.status == 0 else {
            return nil
        }
        return Self.transcriptExcerpt(result.output)
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

    private func runProcess(
        arguments: [String],
        registry: AgenticFinderProcessRegistry
    ) throws -> AgenticFinderProcessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let outputDrain = AgenticFinderPipeDrain(
            maximumBytes: Self.maximumExportCaptureBytes
        )
        let errorDrain = AgenticFinderPipeDrain(
            maximumBytes: Self.maximumErrorCaptureBytes
        )
        process.executableURL = executable.url
        process.arguments = arguments
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
                "Conan Code could not start Grok conversation export."
            )
        }
        guard registry.register(process) else {
            AgenticFinderProcessControl.requestTermination(process)
            process.waitUntilExit()
            outputDrain.waitForEOF()
            errorDrain.waitForEOF()
            throw CancellationError()
        }
        defer { registry.unregister(process) }

        if registry.isCancelled {
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

        let requestData = try JSONEncoder().encode(request)
        let requestJSON = String(decoding: requestData, as: UTF8.self)
        let prompt = """
        You are Conan Code's conversation finder. Use only the candidate data below. Return at most five matches. Prefer semantic evidence from title and excerpt, then recency. Never invent a session ID. Set open=true only when the user explicitly asks to open, show, or take them to a conversation. Set pin=true only when they explicitly ask to pin it. An archived match may still be returned; Conan Code will unarchive it only when open=true. Merely listing or finding results must not mutate anything. Write a concise English message.

        REQUEST JSON:
        \(requestJSON)
        """

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

    private static let disallowedTools = [
        "run_terminal_cmd", "bash", "read_file", "search_replace",
        "write", "edit", "list_dir", "grep", "kill_task", "todo_write",
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
