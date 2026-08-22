import Foundation

/// A Grok session identifier.
///
/// This is the one field Coinor treats as a hard contract: the catalog, the
/// roster, the hook events, and the terminal resume command are joined by it.
struct GrokSessionID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// One row of Grok's persisted session catalog, from `x.ai/session/list`.
///
/// Only the identifier is required. Everything else is optional because the
/// row is a contract owned by the local Grok fork; `raw` keeps the payload the
/// row was decoded from so a field Coinor does not model yet stays reachable.
struct GrokPersistedSession: Sendable, Equatable, Identifiable {
    let id: GrokSessionID
    let title: String?
    let cwd: String?
    let sessionKind: String?
    let listKind: String?
    let source: String?
    let modelID: String?
    let branch: String?
    let repositoryName: String?
    let worktreeLabel: String?
    let gitRootDirectory: String?
    let sourceWorkspaceDirectory: String?
    let gitRemotes: [String]
    let messageCount: Int?
    let createdAt: Date?
    let updatedAt: Date?
    let lastActiveAt: Date?
    let raw: GrokJSONValue

    /// Grok hides subagent sessions from its own listings. Coinor re-checks
    /// because a subagent is a pane, never a conversation.
    var isSubagent: Bool {
        sessionKind?.hasPrefix("subagent") ?? false
    }

    /// The directory a conversation belongs to. A worktree session records the
    /// checkout it was created from, which is what groups it with its project.
    var projectDirectory: String? {
        sourceWorkspaceDirectory ?? gitRootDirectory ?? cwd
    }

    init(raw: GrokJSONValue) throws {
        guard let sessionID = raw["sessionId"]?.stringValue, !sessionID.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: GrokMethod.sessionList,
                detail: "a session row has no sessionId"
            )
        }
        id = GrokSessionID(sessionID)
        let explicitTitle = raw["title"]?.stringValue
        let summary = raw["summary"]?.stringValue
        title = [explicitTitle, summary]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        cwd = raw["cwd"]?.stringValue
        sessionKind = raw["sessionKind"]?.stringValue
        listKind = raw["_meta"]?["x.ai/session"]?["kind"]?.stringValue
        source = raw["source"]?.stringValue
        modelID = raw["modelId"]?.stringValue
        branch = raw["branch"]?.stringValue
        repositoryName = raw["repoName"]?.stringValue
        worktreeLabel = raw["worktreeLabel"]?.stringValue
        gitRootDirectory = raw["gitRootDir"]?.stringValue
        sourceWorkspaceDirectory = raw["sourceWorkspaceDir"]?.stringValue
        gitRemotes = raw.stringArray("gitRemotes")
        messageCount = raw["numMessages"]?.intValue
        createdAt = GrokTimestamp.date(from: raw["createdAt"])
        updatedAt = GrokTimestamp.date(from: raw["updatedAt"])
        lastActiveAt = GrokTimestamp.date(from: raw["lastActiveAt"])
        self.raw = raw
    }

    private init(
        id: GrokSessionID,
        title: String?,
        cwd: String?,
        sessionKind: String?,
        listKind: String?,
        source: String?,
        modelID: String?,
        branch: String?,
        repositoryName: String?,
        worktreeLabel: String?,
        gitRootDirectory: String?,
        sourceWorkspaceDirectory: String?,
        gitRemotes: [String],
        messageCount: Int?,
        createdAt: Date?,
        updatedAt: Date?,
        lastActiveAt: Date?,
        raw: GrokJSONValue
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.sessionKind = sessionKind
        self.listKind = listKind
        self.source = source
        self.modelID = modelID
        self.branch = branch
        self.repositoryName = repositoryName
        self.worktreeLabel = worktreeLabel
        self.gitRootDirectory = gitRootDirectory
        self.sourceWorkspaceDirectory = sourceWorkspaceDirectory
        self.gitRemotes = gitRemotes
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActiveAt = lastActiveAt
        self.raw = raw
    }

    /// Returns a copy with `title` replaced, keeping every other field as is.
    /// Used to reflect a rename in the local catalog before Grok's RPC
    /// confirms it and the next real refresh lands.
    func withTitle(_ newTitle: String) -> GrokPersistedSession {
        GrokPersistedSession(
            id: id,
            title: newTitle,
            cwd: cwd,
            sessionKind: sessionKind,
            listKind: listKind,
            source: source,
            modelID: modelID,
            branch: branch,
            repositoryName: repositoryName,
            worktreeLabel: worktreeLabel,
            gitRootDirectory: gitRootDirectory,
            sourceWorkspaceDirectory: sourceWorkspaceDirectory,
            gitRemotes: gitRemotes,
            messageCount: messageCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActiveAt: lastActiveAt,
            raw: raw
        )
    }
}

/// Applies a rename to a session array before Grok's RPC confirms it, so the
/// sidebar shows the new title immediately instead of waiting for a full
/// catalog refresh. Pure and side-effect free so it is independently
/// testable; the caller decides which array (local or a remote host's) to
/// apply it to and how to rebuild the catalog afterward.
enum OptimisticTitleUpdate {
    /// Returns `sessions` unchanged, plus `nil`, when no session matches.
    static func apply(
        to sessions: [GrokPersistedSession],
        sessionID: String,
        title: String
    ) -> (sessions: [GrokPersistedSession], previous: GrokPersistedSession?) {
        guard let index = sessions.firstIndex(where: { $0.id.rawValue == sessionID }) else {
            return (sessions, nil)
        }
        var updated = sessions
        let previous = updated[index]
        updated[index] = previous.withTitle(title)
        return (updated, previous)
    }
}

/// Coarse activity of a session, as Grok's roster reports it.
enum GrokSessionActivity: Sendable, Equatable {
    case working
    case idle
    case needsInput
    case dormant
    case completed
    case dead
    case unknown(String)

    init(wireValue: String?) {
        switch wireValue {
        case "working": self = .working
        case "idle": self = .idle
        case "needs_input": self = .needsInput
        case "dormant": self = .dormant
        case "completed": self = .completed
        case "dead": self = .dead
        case let other?: self = .unknown(other)
        case nil: self = .unknown("")
        }
    }

    /// Whether this session is asking for the user before it can continue.
    var needsAttention: Bool { self == .needsInput }
}

/// One row of Grok's live roster, from `x.ai/sessions/list` and the
/// `x.ai/sessions/changed` broadcast.
struct GrokRosterEntry: Sendable, Equatable, Identifiable {
    let id: GrokSessionID
    let title: String?
    let cwd: String?
    let isWorktree: Bool
    let modelID: String?
    let reasoningEffort: String?
    let activity: GrokSessionActivity
    let isResident: Bool
    let lastChange: Date?
    let originKind: String?
    let raw: GrokJSONValue

    init(raw: GrokJSONValue, method: String) throws {
        guard let sessionID = raw["sessionId"]?.stringValue, !sessionID.isEmpty else {
            throw GrokControlError.malformedPayload(
                method: method,
                detail: "a roster row has no sessionId"
            )
        }
        id = GrokSessionID(sessionID)
        title = raw["title"]?.stringValue
        cwd = raw["cwd"]?.stringValue
        isWorktree = raw["isWorktree"]?.boolValue ?? false
        modelID = raw["modelId"]?.stringValue
        reasoningEffort = raw["reasoningEffort"]?.stringValue
        activity = GrokSessionActivity(wireValue: raw["activity"]?.stringValue)
        isResident = raw["resident"]?.boolValue ?? false
        lastChange = GrokTimestamp.date(fromUnixMilliseconds: raw["lastChangeUnixMs"])
        originKind = raw["origin"]?["kind"]?.stringValue
        self.raw = raw
    }
}

/// A roster delta. Grok sends current state only, never an event fold.
struct GrokRosterChange: Sendable, Equatable {
    let upserted: [GrokRosterEntry]
    let removed: [GrokSessionID]

    init(upserted: [GrokRosterEntry], removed: [GrokSessionID]) {
        self.upserted = upserted
        self.removed = removed
    }

    init(params: GrokJSONValue) throws {
        upserted = try (params["upserted"]?.arrayValue ?? [])
            .map { try GrokRosterEntry(raw: $0, method: GrokMethod.sessionsChanged) }
        removed = (params["removed"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
            .map { GrokSessionID($0) }
    }
}

/// A lifecycle fact emitted by Grok for one hidden subagent session.
///
/// Hooks and native notifications ultimately feed the same lifecycle state.
/// Progress is start-equivalent because it proves the child is still live even
/// when its original spawn notification was missed.
struct GrokSubagentLifecycleObservation: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case started
        case progressed
        case finished
    }

    let kind: Kind
    let childSessionID: String
    let parentSessionID: String
    let description: String?
    let subagentType: String?
    let status: String?
    let timestamp: String?

    static func parseNotification(
        params: GrokJSONValue,
        timestamp: GrokJSONValue? = nil
    ) -> GrokSubagentLifecycleObservation? {
        let update = params["update"] ?? params
        guard let wireKind = update["sessionUpdate"]?.stringValue else {
            return nil
        }

        let kind: Kind
        switch wireKind {
        case "subagent_spawned":
            kind = .started
        case "subagent_progress":
            kind = .progressed
        case "subagent_finished":
            kind = .finished
        default:
            return nil
        }

        guard let childSessionID = firstString(
            in: update,
            keys: ["child_session_id", "childSessionId", "subagent_id", "subagentId"]
        ), !childSessionID.isEmpty else {
            return nil
        }

        let outerSessionID = firstString(
            in: params,
            keys: ["sessionId", "session_id"]
        )
        let parentSessionID = firstString(
            in: update,
            keys: ["parent_session_id", "parentSessionId"]
        ) ?? outerSessionID
        guard let parentSessionID, !parentSessionID.isEmpty else {
            return nil
        }

        let milliseconds = params["_meta"]?["agentTimestampMs"]
            ?? params["_meta"]?["agent_timestamp_ms"]
        return GrokSubagentLifecycleObservation(
            kind: kind,
            childSessionID: childSessionID,
            parentSessionID: parentSessionID,
            description: firstString(in: update, keys: ["description"]),
            subagentType: firstString(
                in: update,
                keys: ["subagent_type", "subagentType"]
            ),
            status: firstString(in: update, keys: ["status"]),
            timestamp: timestampText(milliseconds ?? timestamp)
        )
    }

    /// Parses one full `updates.jsonl` envelope returned by
    /// `x.ai/session/updates`.
    static func parsePersistedEnvelope(
        _ envelope: GrokJSONValue
    ) -> GrokSubagentLifecycleObservation? {
        guard let wireMethod = envelope["method"]?.stringValue else {
            return nil
        }
        let normalized = GrokMethod.normalize(
            wireMethod: wireMethod,
            params: envelope["params"] ?? .object([:])
        )
        guard normalized.method == GrokMethod.sessionUpdate
                || normalized.method == GrokMethod.sessionNotification else {
            return nil
        }
        return parseNotification(
            params: normalized.params,
            timestamp: envelope["timestamp"]
        )
    }

    private static func firstString(
        in value: GrokJSONValue,
        keys: [String]
    ) -> String? {
        keys.lazy.compactMap { value[$0]?.stringValue }.first
    }

    private static func timestampText(_ value: GrokJSONValue?) -> String? {
        if let text = value?.stringValue {
            return text
        }
        guard let number = value?.doubleValue else {
            return nil
        }
        let milliseconds = number > 10_000_000_000 ? number : number * 1_000
        return String(format: "%.0f", milliseconds)
    }
}

/// How the control connection authenticated. Listing local sessions does not
/// require credentials, so a failure here is reported rather than fatal.
enum GrokAuthentication: Sendable, Equatable {
    case succeeded(methodID: String)
    case failed(methodID: String, message: String)
    case unavailable
}

/// What Coinor learned about the Grok build it just connected to.
struct GrokAgentHandshake: Sendable, Equatable {
    let protocolVersion: Int?
    let agentVersion: String?
    let agentID: String?
    let authMethodIDs: [String]
    let defaultAuthMethodID: String?
    let authentication: GrokAuthentication
    let raw: GrokJSONValue
}

enum GrokTimestamp {
    // `ISO8601DateFormatter` is documented as safe to use from several threads
    // once configured, and neither instance is mutated after creation.
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Grok writes RFC 3339, with fractional seconds only sometimes.
    static func date(from value: GrokJSONValue?) -> Date? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return withFractionalSeconds.date(from: text) ?? withoutFractionalSeconds.date(from: text)
    }

    static func date(fromUnixMilliseconds value: GrokJSONValue?) -> Date? {
        guard let milliseconds = value?.doubleValue, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
