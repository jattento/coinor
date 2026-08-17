import Foundation

struct TelegramUserID: Hashable, Sendable, Codable {
    let rawValue: Int64

    init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }
}

struct TelegramChatID: Hashable, Sendable, Codable {
    let rawValue: Int64

    init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }
}

struct TelegramThreadID: Hashable, Sendable, Codable {
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

struct TelegramUpdateID: Hashable, Sendable {
    let rawValue: Int64

    init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }
}

struct TelegramUser: Equatable, Sendable {
    var id: TelegramUserID
    var isBot: Bool
    var firstName: String
}

struct TelegramChat: Equatable, Sendable {
    var id: TelegramChatID
    var type: String
}

struct TelegramMessage: Equatable, Sendable {
    var messageID: Int
    var from: TelegramUser?
    var chat: TelegramChat
    var text: String?
    var caption: String?
    var threadID: TelegramThreadID?
    var isTopicMessage: Bool
    var forumTopicCreated: TelegramForumTopicCreated?
    var forumTopicClosed: Bool
    var attachments: [TelegramTurnAttachment]
}

struct TelegramForumTopicCreated: Equatable, Sendable {
    var name: String
}

struct TelegramCallbackQuery: Equatable, Sendable {
    var id: String
    var from: TelegramUser
    var message: TelegramMessage?
    var data: String?
}

struct TelegramUpdate: Equatable, Sendable {
    var id: TelegramUpdateID
    var message: TelegramMessage?
    var callbackQuery: TelegramCallbackQuery?
}

struct TelegramProjectChoice: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
}

enum TelegramInbound: Equatable, Sendable {
    case start(userID: TelegramUserID, chatID: TelegramChatID, code: String?)
    case help(userID: TelegramUserID, chatID: TelegramChatID, threadID: TelegramThreadID?)
    case new(userID: TelegramUserID, chatID: TelegramChatID, threadID: TelegramThreadID?)
    case find(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        query: String?
    )
    case text(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        text: String,
        attachments: [TelegramTurnAttachment]
    )
    case topicClosed(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        threadID: TelegramThreadID
    )
    case callback(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        threadID: TelegramThreadID?,
        queryID: String,
        data: String
    )
    case topicCreated(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        threadID: TelegramThreadID,
        name: String
    )
    case ignored

    var chatID: TelegramChatID? {
        switch self {
        case let .start(_, chatID, _),
             let .help(_, chatID, _),
             let .new(_, chatID, _),
             let .find(_, chatID, _, _),
             let .text(_, chatID, _, _, _),
             let .callback(_, chatID, _, _, _),
             let .topicCreated(_, chatID, _, _),
             let .topicClosed(_, chatID, _):
            return chatID
        case .ignored:
            return nil
        }
    }
}

enum TelegramDecision: Equatable, Sendable {
    case ignore
    case rejectUnauthorized
    case pair(userID: TelegramUserID, chatID: TelegramChatID)
    case rejectPairing
    case sendPairingHelp
    case sendAlreadyPaired
    case sendHelp
    case sendProjectPicker
    case sendWorktreePicker(projectID: String)
    case askWorktreeName(projectID: String)
    case createConversation(
        projectID: String,
        worktreeName: String?,
        threadID: TelegramThreadID?
    )
    case prompt(
        sessionID: String,
        text: String,
        attachments: [TelegramTurnAttachment]
    )
    case ignoreArchivedTopic
    case dropTopic(TelegramThreadID)
    case askFindQuery
    case search(query: String)
    case attach(sessionID: String)
    case answerPermission(sessionID: String, optionID: String?)
    case ignoreUnmappedTopic
}

struct TelegramFindMatch: Equatable, Sendable, Identifiable {
    var id: String { sessionID }
    var sessionID: String
    var title: String
    var reason: String
}

struct TelegramRoutingState: Equatable, Sendable {
    var pendingCode: String?
    var pairedUserID: TelegramUserID?
    var pairedChatID: TelegramChatID?
    var sessionIDByThreadID: [Int: String]
    var projectChoices: [TelegramProjectChoice]
    var findChoices: [TelegramFindMatch]
    var awaitingWorktreeNameForProjectID: String?
    var awaitingFindQuery: Bool
    var pickerThreadID: TelegramThreadID?
    var pendingPermissionSessionID: String?
    var pendingPermissionOptions: [TelegramPermissionOption]
    var archivedSessionIDs: Set<String>

    var isPaired: Bool {
        pairedUserID != nil && pairedChatID != nil
    }

    static let empty = TelegramRoutingState(
        pendingCode: nil,
        pairedUserID: nil,
        pairedChatID: nil,
        sessionIDByThreadID: [:],
        projectChoices: [],
        findChoices: [],
        awaitingWorktreeNameForProjectID: nil,
        awaitingFindQuery: false,
        pickerThreadID: nil,
        pendingPermissionSessionID: nil,
        pendingPermissionOptions: [],
        archivedSessionIDs: []
    )
}

struct TelegramPermissionOption: Equatable, Sendable {
    var id: String
    var title: String
}

enum TelegramCopy {
    static let pairingHelp =
        "Ask Conan Code on this Mac for a pairing code, then send /start followed by that code."
    static let invalidPairingCode = "That pairing code is not valid."
    static let alreadyPaired = "This Mac is already paired to this chat."
    static let paired =
        "Conan Code is paired to this chat. Send /new to start a conversation, /find to attach one, or create a topic."
    static let help =
        "Commands:\n/new — start a conversation\n/find — search existing conversations\n/help — this message\n\nMessages in a conversation topic are turns of that conversation."
    static let askFindQuery = "What should Conan Code search for?"
    static let noFindMatches = "Conan Code found no local conversations for that."
    static let pickFindMatch = "Choose a conversation to open on Telegram."
    static let pickProject = "Choose a project for the new conversation."
    static let noProjects =
        "Conan Code has no local projects yet. Add one on the Mac, then send /new again."
    static let pickWorktree = "Start this conversation in the main checkout or a new worktree?"
    static let askWorktreeName = "Send a worktree name (letters, numbers, dot, underscore, or hyphen)."
    static let unmappedTopic =
        "This topic is not a Conan Code conversation. Send /new or create a topic to start one."
    static let working = "Working…"
    static let missingToken = "Paste a Telegram bot token in Conan Code Settings to enable remote work."

    static func subagentLine(
        _ observation: GrokSubagentLifecycleObservation
    ) -> String {
        let label = observation.description
            ?? observation.subagentType
            ?? "subagent"
        switch observation.kind {
        case .started:
            return "Subagent started: \(label)"
        case .progressed:
            return "Subagent working: \(label)"
        case .finished:
            return "Subagent finished: \(label)"
        }
    }
}

enum TelegramCallbackData {
    static let projectPrefix = "p:"
    static let worktreeMainPrefix = "wm:"
    static let worktreeNewPrefix = "wn:"
    static let findPrefix = "f:"
    static let permissionPrefix = "a:"
    static let permissionDeny = "ax"

    static func project(_ index: Int) -> String { "\(projectPrefix)\(index)" }
    static func worktreeMain(_ index: Int) -> String { "\(worktreeMainPrefix)\(index)" }
    static func worktreeNew(_ index: Int) -> String { "\(worktreeNewPrefix)\(index)" }
    static func find(_ index: Int) -> String { "\(findPrefix)\(index)" }
    static func permission(_ index: Int) -> String { "\(permissionPrefix)\(index)" }

    static func projectIndex(_ data: String) -> Int? {
        index(data, prefix: projectPrefix)
    }

    static func worktreeMainIndex(_ data: String) -> Int? {
        index(data, prefix: worktreeMainPrefix)
    }

    static func worktreeNewIndex(_ data: String) -> Int? {
        index(data, prefix: worktreeNewPrefix)
    }

    static func findIndex(_ data: String) -> Int? {
        index(data, prefix: findPrefix)
    }

    static func permissionIndex(_ data: String) -> Int? {
        index(data, prefix: permissionPrefix)
    }

    private static func index(_ data: String, prefix: String) -> Int? {
        guard data.hasPrefix(prefix) else { return nil }
        return Int(data.dropFirst(prefix.count))
    }
}
