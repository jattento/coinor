import Combine
import Foundation

struct TelegramCreatedConversation: Equatable, Sendable {
    var sessionID: String
    var title: String
}

@MainActor
protocol TelegramWorking: AnyObject {
    func telegramLocalProjects() -> [TelegramProjectChoice]
    func telegramCreateConversation(
        projectID: String,
        worktreeName: String?
    ) async throws -> TelegramCreatedConversation
    func telegramPrompt(sessionID: String, text: String) async throws -> String
    func telegramPersist(
        _ transform: @escaping @Sendable (inout MetadataDocument) -> Void
    ) async
    func telegramConversationTitle(_ sessionID: String) -> String?
}

@MainActor
final class TelegramBridge: ObservableObject {
    private let tokens: any TelegramTokenStoring
    private let makeClient: @MainActor (String) -> any TelegramAPIClient
    private let router = TelegramRouter()
    private weak var worker: TelegramWorking?
    private var pollTask: Task<Void, Never>?
    private var promptTasks: [String: Task<Void, Never>] = [:]
    private var offset: TelegramUpdateID?
    private var outboundChatID: TelegramChatID?
    private(set) var routing = TelegramRoutingState.empty

    @Published private(set) var statusText = TelegramCopy.missingToken
    @Published private(set) var pairingCode: String?
    @Published private(set) var isPaired = false
    @Published private(set) var hasToken = false

    init(
        tokens: any TelegramTokenStoring = KeychainTelegramTokenStore.default,
        client: (@MainActor (String) -> any TelegramAPIClient)? = nil
    ) {
        self.tokens = tokens
        makeClient = client ?? { TelegramHTTPClient(token: $0) }
    }

    func attach(worker: TelegramWorking, metadata: MetadataDocument) {
        self.worker = worker
        apply(metadata.telegram)
        refreshTokenPresence()
    }

    func startPolling() {
        pollTask?.cancel()
        refreshTokenPresence()
        guard hasToken else {
            statusText = TelegramCopy.missingToken
            return
        }
        statusText = isPaired
            ? TelegramCopy.alreadyPaired
            : "Waiting for /start with the pairing code."
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        promptTasks.values.forEach { $0.cancel() }
        promptTasks.removeAll()
    }

    func saveToken(_ token: String) throws {
        try tokens.save(token)
        refreshTokenPresence()
        startPolling()
    }

    func disconnect() throws {
        try tokens.delete()
        pairingCode = nil
        routing = TelegramRoutingState.empty
        isPaired = false
        hasToken = false
        statusText = TelegramCopy.missingToken
        stopPolling()
        Task { [weak self] in
            await self?.worker?.telegramPersist { $0.telegram = .empty }
        }
    }

    func refreshPairingCode() {
        let code = TelegramPairingCode.generate()
        pairingCode = code
        routing.pendingCode = code
        if !isPaired {
            statusText = "Send /start \(code) to the bot from your phone."
        }
    }

    func share(sessionID: String, title: String) async {
        guard let chatID = routing.pairedChatID,
              let token = try? tokens.load(),
              !token.isEmpty,
              routing.sessionIDByThreadID.values.contains(sessionID) == false else {
            return
        }
        do {
            let client = makeClient(token)
            let threadID = try await client.createForumTopic(
                chatID: chatID,
                name: title
            )
            bind(sessionID: sessionID, threadID: threadID)
            try await client.sendMessage(
                chatID: chatID,
                threadID: threadID,
                text: "This topic is the Conan Code conversation “\(title)”.",
                replyMarkup: nil
            )
            await persistMapping()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func closeTopic(for sessionID: String) async {
        guard let threadID = threadID(for: sessionID),
              let chatID = routing.pairedChatID,
              let token = try? tokens.load() else {
            return
        }
        do {
            try await makeClient(token).closeForumTopic(
                chatID: chatID,
                threadID: threadID
            )
        } catch {
            statusText = error.localizedDescription
        }
    }

    func reopenTopic(for sessionID: String) async {
        guard let threadID = threadID(for: sessionID),
              let chatID = routing.pairedChatID,
              let token = try? tokens.load() else {
            return
        }
        do {
            try await makeClient(token).reopenForumTopic(
                chatID: chatID,
                threadID: threadID
            )
        } catch {
            statusText = error.localizedDescription
        }
    }

    func syncTitle(_ title: String, for sessionID: String) async {
        guard let threadID = threadID(for: sessionID),
              let chatID = routing.pairedChatID,
              let token = try? tokens.load() else {
            return
        }
        try? await makeClient(token).editForumTopic(
            chatID: chatID,
            threadID: threadID,
            name: title
        )
    }

    func handleForTesting(_ inbound: TelegramInbound) async {
        await apply(inbound, replyWith: nil)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            guard let token = try? tokens.load() else {
                statusText = TelegramCopy.missingToken
                return
            }
            let client = makeClient(token)
            do {
                let updates = try await client.getUpdates(
                    offset: offset,
                    timeout: 30
                )
                for update in updates {
                    offset = TelegramUpdateID(update.id.rawValue + 1)
                    await apply(
                        TelegramHTTPClient.inbound(from: update),
                        replyWith: client
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                statusText = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func apply(
        _ inbound: TelegramInbound,
        replyWith client: (any TelegramAPIClient)?
    ) async {
        outboundChatID = inbound.chatID
        if case let .callback(_, _, _, queryID, _) = inbound {
            try? await client?.answerCallbackQuery(id: queryID)
        }
        let (next, decisions) = router.handle(inbound, state: routing)
        routing = next
        for decision in decisions {
            await perform(decision, client: client)
        }
    }

    private func perform(
        _ decision: TelegramDecision,
        client: (any TelegramAPIClient)?
    ) async {
        switch decision {
        case .ignore, .rejectUnauthorized:
            return
        case let .pair(userID, chatID):
            isPaired = true
            pairingCode = nil
            statusText = TelegramCopy.paired
            await worker?.telegramPersist { document in
                document.telegram.pairedUserID = userID
                document.telegram.pairedChatID = chatID
            }
            await reply(TelegramCopy.paired, threadID: nil, client: client)
        case .rejectPairing:
            await reply(TelegramCopy.invalidPairingCode, threadID: nil, client: client)
        case .sendPairingHelp:
            await reply(TelegramCopy.pairingHelp, threadID: nil, client: client)
        case .sendAlreadyPaired:
            await reply(TelegramCopy.alreadyPaired, threadID: nil, client: client)
        case .sendHelp:
            await reply(TelegramCopy.help, threadID: routing.pickerThreadID, client: client)
        case .sendProjectPicker:
            await sendProjectPicker(client: client)
        case let .sendWorktreePicker(projectID):
            await sendWorktreePicker(projectID: projectID, client: client)
        case .askWorktreeName:
            await reply(
                TelegramCopy.askWorktreeName,
                threadID: routing.pickerThreadID,
                client: client
            )
        case let .createConversation(projectID, worktreeName, threadID):
            await createConversation(
                projectID: projectID,
                worktreeName: worktreeName,
                threadID: threadID,
                client: client
            )
        case let .prompt(sessionID, text):
            await prompt(sessionID: sessionID, text: text, client: client)
        case .ignoreUnmappedTopic:
            await reply(
                TelegramCopy.unmappedTopic,
                threadID: routing.pickerThreadID,
                client: client
            )
        }
    }

    private func sendProjectPicker(client: (any TelegramAPIClient)?) async {
        let projects = worker?.telegramLocalProjects() ?? []
        routing.projectChoices = projects
        guard !projects.isEmpty else {
            await reply(
                TelegramCopy.noProjects,
                threadID: routing.pickerThreadID,
                client: client
            )
            return
        }
        let buttons = projects.enumerated().map { index, project in
            [TelegramInlineButton(title: project.title, data: TelegramCallbackData.project(index))]
        }
        await reply(
            TelegramCopy.pickProject,
            threadID: routing.pickerThreadID,
            markup: TelegramReplyMarkup(rows: buttons),
            client: client
        )
    }

    private func sendWorktreePicker(
        projectID: String,
        client: (any TelegramAPIClient)?
    ) async {
        guard let index = routing.projectChoices.firstIndex(where: { $0.id == projectID }) else {
            await sendProjectPicker(client: client)
            return
        }
        await reply(
            TelegramCopy.pickWorktree,
            threadID: routing.pickerThreadID,
            markup: TelegramReplyMarkup(
                rows: [
                    [
                        TelegramInlineButton(
                            title: "In Main Checkout",
                            data: TelegramCallbackData.worktreeMain(index)
                        ),
                    ],
                    [
                        TelegramInlineButton(
                            title: "In New Worktree",
                            data: TelegramCallbackData.worktreeNew(index)
                        ),
                    ],
                ]
            ),
            client: client
        )
    }

    private func createConversation(
        projectID: String,
        worktreeName: String?,
        threadID: TelegramThreadID?,
        client: (any TelegramAPIClient)?
    ) async {
        guard let worker, let chatID = routing.pairedChatID else { return }
        do {
            let created = try await worker.telegramCreateConversation(
                projectID: projectID,
                worktreeName: worktreeName
            )
            let boundThread: TelegramThreadID
            if let threadID {
                boundThread = threadID
            } else if let client {
                boundThread = try await client.createForumTopic(
                    chatID: chatID,
                    name: created.title
                )
            } else {
                return
            }
            bind(sessionID: created.sessionID, threadID: boundThread)
            await persistMapping()
            await reply(
                "Started “\(created.title)”. Messages in this topic are turns of that conversation.",
                threadID: boundThread,
                client: client
            )
        } catch {
            await reply(error.localizedDescription, threadID: threadID, client: client)
        }
    }

    private func prompt(
        sessionID: String,
        text: String,
        client: (any TelegramAPIClient)?
    ) async {
        promptTasks[sessionID]?.cancel()
        let threadID = threadID(for: sessionID)
        promptTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.reply(
                TelegramCopy.working,
                threadID: threadID,
                client: client
            )
            do {
                let answer = try await self.worker?.telegramPrompt(
                    sessionID: sessionID,
                    text: text
                ) ?? ""
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                await self.reply(
                    trimmed.isEmpty ? "Done." : trimmed,
                    threadID: threadID,
                    client: client
                )
            } catch is CancellationError {
                return
            } catch {
                await self.reply(
                    error.localizedDescription,
                    threadID: threadID,
                    client: client
                )
            }
        }
    }

    private func reply(
        _ text: String,
        threadID: TelegramThreadID?,
        markup: TelegramReplyMarkup? = nil,
        client: (any TelegramAPIClient)?
    ) async {
        guard let client, let chatID = routing.pairedChatID ?? fallbackChatID else {
            return
        }
        for chunk in Self.split(text) {
            do {
                try await client.sendMessage(
                    chatID: chatID,
                    threadID: threadID,
                    text: chunk,
                    replyMarkup: markup
                )
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    private var fallbackChatID: TelegramChatID? {
        routing.pairedChatID ?? outboundChatID
    }

    private func bind(sessionID: String, threadID: TelegramThreadID) {
        routing.sessionIDByThreadID = routing.sessionIDByThreadID.filter {
            $0.value != sessionID
        }
        routing.sessionIDByThreadID[threadID.rawValue] = sessionID
    }

    private func threadID(for sessionID: String) -> TelegramThreadID? {
        routing.sessionIDByThreadID.first { $0.value == sessionID }
            .map { TelegramThreadID($0.key) }
    }

    private func persistMapping() async {
        let pairs = routing.sessionIDByThreadID
        await worker?.telegramPersist { document in
            document.telegram.threadIDBySessionID = Dictionary(
                uniqueKeysWithValues: pairs.map { ($0.value, $0.key) }
            )
        }
    }

    private func apply(_ telegram: TelegramMetadata) {
        routing.pairedUserID = telegram.pairedUserID
        routing.pairedChatID = telegram.pairedChatID
        routing.sessionIDByThreadID = telegram.sessionIDByThreadID
        isPaired = telegram.pairedUserID != nil && telegram.pairedChatID != nil
        if isPaired {
            statusText = TelegramCopy.paired
        }
    }

    private func refreshTokenPresence() {
        hasToken = (try? tokens.load())?.isEmpty == false
    }

    private static func split(_ text: String) -> [String] {
        let limit = 4096
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(
                remainder.startIndex,
                offsetBy: min(limit, remainder.count)
            )
            chunks.append(String(remainder[remainder.startIndex..<end]))
            remainder = remainder[end...]
        }
        return chunks
    }
}
