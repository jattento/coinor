import Foundation

enum GrokHookEventName: String, Codable, Equatable, Sendable {
    case sessionStart = "session_start"
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"
    case sessionEnd = "session_end"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
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
                debugDescription: "Unsupported Grok hook event"
            )
        }
    }
}

struct GrokHookEvent: Codable, Equatable, Sendable {
    let hookEventName: GrokHookEventName
    let sessionId: String
    let cwd: String
    let workspaceRoot: String
    let timestamp: String
    let transcriptPath: String?
    let clientIdentifier: String?
    let promptId: String?
    let permissionMode: String?
    let source: String?
    let reason: String?
    let subagentId: String?
    let subagentType: String?
    let description: String?
    let phase: String?

    static func decode(_ data: Data) throws -> GrokHookEvent {
        try JSONDecoder().decode(GrokHookEvent.self, from: data)
    }
}
