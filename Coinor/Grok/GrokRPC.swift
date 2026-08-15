import Foundation

/// The Grok methods Coinor's control plane depends on.
///
/// `initialize` and `authenticate` are ACP. The `x.ai/*` methods are
/// extensions owned by the local Grok fork; ACP carries them with a leading
/// underscore on the wire, so `x.ai/session/list` is sent as
/// `_x.ai/session/list` and its notifications arrive the same way.
enum GrokMethod {
    static let initialize = "initialize"
    static let authenticate = "authenticate"

    static let sessionList = "x.ai/session/list"
    static let sessionsList = "x.ai/sessions/list"
    static let sessionsChanged = "x.ai/sessions/changed"
    static let sessionRename = "x.ai/session/rename"
    static let sessionNotification = "x.ai/session_notification"
    static let sessionUpdate = "x.ai/session/update"
    static let sessionUpdates = "x.ai/session/updates"
    static let leaderReconnected = "x.ai/leader_reconnected"
    static let workflowsList = "x.ai/workflows/list"
    static let workflowsLaunch = "x.ai/workflows/launch"
    static let workflowsSnapshot = "x.ai/workflows/snapshot"
    static let workflowsControl = "x.ai/workflows/control"

    static let requestPermission = "session/request_permission"
    static let askUserQuestion = "x.ai/ask_user_question"
    static let exitPlanMode = "x.ai/exit_plan_mode"

    static let extensionPrefix = "_"

    static func wireName(forExtension method: String) -> String {
        extensionPrefix + method
    }

    /// The extension name behind a wire method, or `nil` for a plain ACP one.
    static func extensionName(forWire wireMethod: String) -> String? {
        guard wireMethod.hasPrefix(extensionPrefix) else { return nil }
        return String(wireMethod.dropFirst())
    }

    /// Grok extension messages can arrive directly or through the ACP gateway
    /// wrapper. Return the real method and params in either case.
    static func normalize(
        wireMethod: String,
        params: GrokJSONValue
    ) -> (method: String, params: GrokJSONValue) {
        guard wireMethod.hasPrefix(extensionPrefix) else {
            return (wireMethod, params)
        }
        let fallback = extensionName(forWire: wireMethod) ?? wireMethod
        guard let wrappedMethod = params["method"]?.stringValue else {
            return (fallback, params)
        }
        return (wrappedMethod, params["params"] ?? .object([:]))
    }

    static func isSharedInteraction(_ method: String) -> Bool {
        method == requestPermission
            || method == askUserQuestion
            || method == exitPlanMode
    }
}

struct GrokRPCError: Sendable, Equatable {
    let code: Int
    let message: String
    let data: GrokJSONValue?

    init?(_ value: GrokJSONValue?) {
        guard let value, !value.isNull else { return nil }
        code = value["code"]?.intValue ?? 0
        message = value["message"]?.stringValue ?? "unknown error"
        data = value["data"]
    }
}

/// An inbound JSON-RPC message, classified by shape.
enum GrokInboundMessage: Sendable {
    case response(id: String, result: GrokJSONValue?, error: GrokRPCError?)
    case notification(method: String, params: GrokJSONValue)
    case request(id: GrokJSONValue, method: String, params: GrokJSONValue)
}

enum GrokRPC {
    static let jsonrpcVersion = "2.0"
    static let methodNotFoundCode = -32601

    static func request(
        id: String,
        method: String,
        params: GrokJSONValue
    ) -> GrokJSONValue {
        [
            "jsonrpc": .string(jsonrpcVersion),
            "id": .string(id),
            "method": .string(method),
            "params": params,
        ]
    }

    static func errorResponse(
        id: GrokJSONValue,
        code: Int,
        message: String
    ) -> GrokJSONValue {
        [
            "jsonrpc": .string(jsonrpcVersion),
            "id": id,
            "error": ["code": .int(code), "message": .string(message)],
        ]
    }

    /// Classifies one frame. Returns `nil` for anything that is not a
    /// JSON-RPC message, which the caller keeps as a diagnostic rather than
    /// treating as a protocol failure.
    static func classify(_ payload: Data) -> GrokInboundMessage? {
        guard let value = try? GrokJSONValue.decode(payload),
              case .object = value
        else { return nil }

        let method = value["method"]?.stringValue
        let params = value["params"] ?? .object([:])

        if let identifier = value["id"], !identifier.isNull {
            if let method {
                return .request(id: identifier, method: method, params: params)
            }
            guard let text = responseID(identifier) else { return nil }
            return .response(
                id: text,
                result: value["result"],
                error: GrokRPCError(value["error"])
            )
        }

        guard let method else { return nil }
        return .notification(method: method, params: params)
    }

    /// Coinor sends string identifiers, but a peer is free to echo any JSON
    /// scalar, so a numeric identifier still resolves to the same key.
    private static func responseID(_ value: GrokJSONValue) -> String? {
        if let text = value.stringValue { return text }
        if let number = value.intValue { return String(number) }
        return nil
    }
}
