import Foundation

public enum GrokHookEventName: String, Codable, Equatable {
    case sessionStart = "session_start"
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"
    case sessionEnd = "session_end"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "session_start", "SessionStart", "sessionStart":
            self = .sessionStart
        case "subagent_start", "SubagentStart", "subagentStart":
            self = .subagentStart
        case "subagent_stop", "SubagentStop", "subagentStop",
             "subagent_end", "SubagentEnd", "subagentEnd":
            self = .subagentStop
        case "session_end", "SessionEnd", "sessionEnd":
            self = .sessionEnd
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Grok hook event: \(value)"
            )
        }
    }
}

public struct GrokHookEvent: Codable, Equatable {
    public let hookEventName: GrokHookEventName
    public let sessionId: String
    public let cwd: String
    public let workspaceRoot: String
    public let timestamp: String
    public let transcriptPath: String?
    public let clientIdentifier: String?
    public let promptId: String?
    public let permissionMode: String?
    public let source: String?
    public let reason: String?
    public let subagentId: String?
    public let subagentType: String?
    public let description: String?
    public let phase: String?

    public static func decode(_ data: Data) throws -> GrokHookEvent {
        try JSONDecoder().decode(GrokHookEvent.self, from: data)
    }
}
