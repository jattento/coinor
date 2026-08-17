import Foundation

protocol TelegramAPIClient: Sendable {
    func getUpdates(
        offset: TelegramUpdateID?,
        timeout: Int
    ) async throws -> [TelegramUpdate]

    func sendMessage(
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        text: String,
        replyMarkup: TelegramReplyMarkup?
    ) async throws

    func sendMessageDraft(
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        draftID: Int,
        text: String
    ) async throws

    func createForumTopic(
        chatID: TelegramChatID,
        name: String
    ) async throws -> TelegramThreadID

    func editForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID,
        name: String
    ) async throws

    func closeForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID
    ) async throws

    func reopenForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID
    ) async throws

    func answerCallbackQuery(id: String) async throws
}

struct TelegramReplyMarkup: Equatable, Sendable {
    var rows: [[TelegramInlineButton]]
}

struct TelegramInlineButton: Equatable, Sendable {
    var title: String
    var data: String
}

enum TelegramAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidToken
    case requestFailed(status: Int, description: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The Telegram bot token is empty or invalid."
        case let .requestFailed(_, description):
            return "Telegram request failed: \(description)"
        case let .malformedResponse(detail):
            return "Telegram returned an unexpected response: \(detail)"
        }
    }
}

struct TelegramHTTPClient: TelegramAPIClient {
    var token: String
    var session: URLSession
    var endpoint: URL

    init(
        token: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.telegram.org")!
    ) {
        self.token = token
        self.session = session
        self.endpoint = endpoint
    }

    func getUpdates(
        offset: TelegramUpdateID?,
        timeout: Int
    ) async throws -> [TelegramUpdate] {
        var parameters: [String: Any] = [
            "timeout": timeout,
            "allowed_updates": [
                "message",
                "callback_query",
            ],
        ]
        if let offset {
            parameters["offset"] = offset.rawValue
        }
        let payload = try await post("getUpdates", parameters: parameters)
        guard let rows = payload.arrayValue else {
            throw TelegramAPIError.malformedResponse("getUpdates result must be an array")
        }
        return try rows.map(Self.decodeUpdate)
    }

    func sendMessage(
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        text: String,
        replyMarkup: TelegramReplyMarkup?
    ) async throws {
        var parameters: [String: Any] = [
            "chat_id": chatID.rawValue,
            "text": text,
        ]
        if let threadID {
            parameters["message_thread_id"] = threadID.rawValue
        }
        if let replyMarkup {
            parameters["reply_markup"] = [
                "inline_keyboard": replyMarkup.rows.map { row in
                    row.map {
                        [
                            "text": $0.title,
                            "callback_data": $0.data,
                        ]
                    }
                },
            ]
        }
        _ = try await post("sendMessage", parameters: parameters)
    }

    func sendMessageDraft(
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        draftID: Int,
        text: String
    ) async throws {
        var parameters: [String: Any] = [
            "chat_id": chatID.rawValue,
            "draft_id": draftID,
            "text": String(text.prefix(4096)),
        ]
        if let threadID {
            parameters["message_thread_id"] = threadID.rawValue
        }
        _ = try await post("sendMessageDraft", parameters: parameters)
    }

    func createForumTopic(
        chatID: TelegramChatID,
        name: String
    ) async throws -> TelegramThreadID {
        let payload = try await post(
            "createForumTopic",
            parameters: [
                "chat_id": chatID.rawValue,
                "name": String(name.prefix(128)),
            ]
        )
        guard let threadID = payload["message_thread_id"]?.intValue else {
            throw TelegramAPIError.malformedResponse(
                "createForumTopic did not return message_thread_id"
            )
        }
        return TelegramThreadID(threadID)
    }

    func editForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID,
        name: String
    ) async throws {
        _ = try await post(
            "editForumTopic",
            parameters: [
                "chat_id": chatID.rawValue,
                "message_thread_id": threadID.rawValue,
                "name": String(name.prefix(128)),
            ]
        )
    }

    func closeForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID
    ) async throws {
        _ = try await post(
            "closeForumTopic",
            parameters: [
                "chat_id": chatID.rawValue,
                "message_thread_id": threadID.rawValue,
            ]
        )
    }

    func reopenForumTopic(
        chatID: TelegramChatID,
        threadID: TelegramThreadID
    ) async throws {
        _ = try await post(
            "reopenForumTopic",
            parameters: [
                "chat_id": chatID.rawValue,
                "message_thread_id": threadID.rawValue,
            ]
        )
    }

    func answerCallbackQuery(id: String) async throws {
        _ = try await post(
            "answerCallbackQuery",
            parameters: ["callback_query_id": id]
        )
    }

    private func post(
        _ method: String,
        parameters: [String: Any]
    ) async throws -> GrokJSONValue {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TelegramAPIError.invalidToken
        }
        let urlString = endpoint.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        ) + "/bot\(trimmed)/\(method)"
        guard let url = URL(string: urlString) else {
            throw TelegramAPIError.invalidToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try GrokJSONValue.decode(data)
        guard decoded["ok"]?.boolValue == true else {
            throw TelegramAPIError.requestFailed(
                status: status,
                description: decoded["description"]?.stringValue
                    ?? "HTTP \(status)"
            )
        }
        return decoded["result"] ?? .object([:])
    }

    static func decodeUpdate(_ value: GrokJSONValue) throws -> TelegramUpdate {
        guard let rawID = value["update_id"]?.int64Value else {
            throw TelegramAPIError.malformedResponse("update_id is required")
        }
        return TelegramUpdate(
            id: TelegramUpdateID(rawID),
            message: value["message"].flatMap(decodeMessage),
            callbackQuery: value["callback_query"].flatMap(decodeCallback)
        )
    }

    static func inbound(from update: TelegramUpdate) -> TelegramInbound {
        if let callback = update.callbackQuery {
            let chatID = callback.message?.chat.id ?? TelegramChatID(callback.from.id.rawValue)
            return .callback(
                userID: callback.from.id,
                chatID: chatID,
                threadID: callback.message?.threadID,
                queryID: callback.id,
                data: callback.data ?? ""
            )
        }
        guard let message = update.message,
              let from = message.from,
              !from.isBot else {
            return .ignored
        }
        if let topic = message.forumTopicCreated, let threadID = message.threadID {
            return .topicCreated(
                userID: from.id,
                chatID: message.chat.id,
                threadID: threadID,
                name: topic.name
            )
        }
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return .ignored
        }
        let command = botCommand(from: text)
        switch command?.name {
        case "start":
            let code = command?.argument
            return .start(userID: from.id, chatID: message.chat.id, code: code)
        case "help":
            return .help(
                userID: from.id,
                chatID: message.chat.id,
                threadID: message.threadID
            )
        case "new":
            return .new(
                userID: from.id,
                chatID: message.chat.id,
                threadID: message.threadID
            )
        case "find":
            return .find(
                userID: from.id,
                chatID: message.chat.id,
                threadID: message.threadID,
                query: command?.argument
            )
        default:
            return .text(
                userID: from.id,
                chatID: message.chat.id,
                threadID: message.threadID,
                text: text
            )
        }
    }

    private static func decodeMessage(_ value: GrokJSONValue) -> TelegramMessage? {
        guard let messageID = value["message_id"]?.intValue,
              let chatValue = value["chat"],
              let chatID = chatValue["id"]?.int64Value,
              let chatType = chatValue["type"]?.stringValue else {
            return nil
        }
        let topic = value["forum_topic_created"]
        return TelegramMessage(
            messageID: messageID,
            from: value["from"].flatMap(decodeUser),
            chat: TelegramChat(id: TelegramChatID(chatID), type: chatType),
            text: value["text"]?.stringValue,
            threadID: value["message_thread_id"]?.intValue.map(TelegramThreadID.init),
            isTopicMessage: value["is_topic_message"]?.boolValue ?? false,
            forumTopicCreated: topic.flatMap {
                guard let name = $0["name"]?.stringValue else { return nil }
                return TelegramForumTopicCreated(name: name)
            }
        )
    }

    private static func decodeCallback(_ value: GrokJSONValue) -> TelegramCallbackQuery? {
        guard let id = value["id"]?.stringValue,
              let from = value["from"].flatMap(decodeUser) else {
            return nil
        }
        return TelegramCallbackQuery(
            id: id,
            from: from,
            message: value["message"].flatMap(decodeMessage),
            data: value["data"]?.stringValue
        )
    }

    private static func decodeUser(_ value: GrokJSONValue) -> TelegramUser? {
        guard let id = value["id"]?.int64Value,
              let firstName = value["first_name"]?.stringValue else {
            return nil
        }
        return TelegramUser(
            id: TelegramUserID(id),
            isBot: value["is_bot"]?.boolValue ?? false,
            firstName: firstName
        )
    }

    private static func botCommand(
        from text: String
    ) -> (name: String, argument: String?)? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let rawName = parts.first else { return nil }
        let name = rawName.split(separator: "@", maxSplits: 1).first.map(String.init)?
            .lowercased()
        guard let name, !name.isEmpty else { return nil }
        let argument = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return (name, argument?.isEmpty == true ? nil : argument)
    }
}

extension GrokJSONValue {
    var int64Value: Int64? {
        if let value = intValue {
            return Int64(value)
        }
        if case let .double(value) = self, value.rounded() == value {
            return Int64(value)
        }
        if let text = stringValue {
            return Int64(text)
        }
        return nil
    }
}
