import Combine
import Foundation

struct TelegramCreatedConversation: Equatable, Sendable {
    var sessionID: String
    var title: String
}

private struct ActiveTelegramTurn {
    var presenter: TelegramTurnPresenter
    let draftID: Int
    let threadID: TelegramThreadID?
}

@MainActor
protocol TelegramWorking: AnyObject {
    func telegramLocalProjects() -> [TelegramProjectChoice]
    func telegramCreateConversation(
        projectID: String,
        worktreeName: String?
    ) async throws -> TelegramCreatedConversation
    func telegramPrompt(
        sessionID: String,
        blocks: [GrokJSONValue],
        onUpdate: @escaping @Sendable (GrokPromptUpdate) -> Void
    ) async throws -> String
    func telegramAnswerPermission(sessionID: String, optionID: String?)
    func telegramFind(query: String) async throws -> (message: String, matches: [TelegramFindMatch])
    func telegramPrepareAttachment(sessionID: String) async throws -> TelegramCreatedConversation
    func telegramPersist(
        _ transform: @escaping @Sendable (inout MetadataDocument) -> Void
    ) async
    func telegramConversationTitle(_ sessionID: String) -> String?
    func telegramLocalConversations() -> [TelegramCatalogConversation]
}

@MainActor
final class TelegramBridge: ObservableObject {
    private let tokens: any TelegramTokenStoring
    private let makeClient: @MainActor (String) -> any TelegramAPIClient
    private let transcriber: any TelegramTranscribing
    private let router = TelegramRouter()
    private weak var worker: TelegramWorking?
    private var pollTask: Task<Void, Never>?
    private var promptTasks: [String: Task<Void, Never>] = [:]
    private var activeTurns: [String: ActiveTelegramTurn] = [:]
    private var catalogSyncTask: Task<Void, Never>?
    private var offset: TelegramUpdateID?
    private var outboundChatID: TelegramChatID?
    private(set) var routing = TelegramRoutingState.empty

    @Published private(set) var statusText = TelegramCopy.missingToken
    @Published private(set) var pairingCode: String?
    @Published private(set) var isPaired = false
    @Published private(set) var hasToken = false
    @Published private(set) var allowedUsername: String?

    init(
        tokens: any TelegramTokenStoring = FileTelegramTokenStore.default,
        client: (@MainActor (String) -> any TelegramAPIClient)? = nil,
        transcriber: any TelegramTranscribing = SpeechTelegramTranscriber()
    ) {
        self.tokens = tokens
        makeClient = client ?? { TelegramHTTPClient(token: $0) }
        self.transcriber = transcriber
    }

    func attach(worker: TelegramWorking, metadata: MetadataDocument) {
        self.worker = worker
        apply(metadata.telegram, archivedSessionIDs: archivedIDs(in: metadata))
        refreshTokenPresence()
    }

    func startPolling() {
        pollTask?.cancel()
        refreshTokenPresence()
        guard hasToken else {
            statusText = TelegramCopy.missingToken
            return
        }
        refreshAllowlist()
        if !isPaired {
            if let username = routing.allowedUsername, !username.isEmpty {
                pairingCode = nil
                routing.pendingCode = nil
                statusText = TelegramCopy.listening(for: username)
            } else if pairingCode == nil {
                refreshPairingCode()
            }
        }
        if isPaired {
            statusText = TelegramCopy.alreadyPaired
            scheduleCatalogSync()
        } else if routing.allowedUsername == nil, pairingCode != nil {
            statusText = "Send /start \(pairingCode ?? "") to the bot from your phone."
        }
        pollTask = Task { [weak self] in
            await self?.configureBotThenPoll()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        promptTasks.values.forEach { $0.cancel() }
        promptTasks.removeAll()
        activeTurns.removeAll()
        catalogSyncTask?.cancel()
        catalogSyncTask = nil
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
        refreshAllowlist()
        if routing.allowedUsername != nil {
            pairingCode = nil
            routing.pendingCode = nil
            if !isPaired {
                statusText = TelegramCopy.listening(for: routing.allowedUsername ?? "")
            }
            return
        }
        let code = TelegramPairingCode.generate()
        pairingCode = code
        routing.pendingCode = code
        if !isPaired {
            statusText = "Send /start \(code) to the bot from your phone."
        }
        Task { [weak self] in
            await self?.worker?.telegramPersist { $0.telegram.pendingPairingCode = code }
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

    func syncCatalog(_ conversations: [TelegramCatalogConversation]) async {
        guard isPaired,
              let chatID = routing.pairedChatID,
              let token = try? tokens.load(),
              !token.isEmpty else {
            return
        }
        let wanted = TelegramTopicCatalog.publish(conversations)
        let client = makeClient(token)
        for item in conversations where item.isArchived {
            await closeTopic(for: item.sessionID)
        }
        for item in wanted {
            if Task.isCancelled { return }
            if threadID(for: item.sessionID) == nil {
                do {
                    let threadID = try await client.createForumTopic(
                        chatID: chatID,
                        name: item.title
                    )
                    bind(sessionID: item.sessionID, threadID: threadID)
                    await persistMapping()
                    try await Task.sleep(for: .milliseconds(350))
                } catch is CancellationError {
                    return
                } catch {
                    statusText = error.localizedDescription
                    return
                }
            }
        }
    }

    func closeTopic(for sessionID: String) async {
        routing.archivedSessionIDs.insert(sessionID)
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
        routing.archivedSessionIDs.remove(sessionID)
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

    func scheduleCatalogSync() {
        guard isPaired else { return }
        catalogSyncTask?.cancel()
        catalogSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            await self.syncCatalog(self.worker?.telegramLocalConversations() ?? [])
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

    func reportSubagent(
        rootSessionID: String,
        observation: GrokSubagentLifecycleObservation
    ) {
        guard var turn = activeTurns[rootSessionID],
              let token = try? tokens.load() else {
            return
        }
        let outputs = turn.presenter.consume(.subagent(observation))
        activeTurns[rootSessionID] = turn
        guard !outputs.isEmpty else { return }
        let client = makeClient(token)
        let draftID = turn.draftID
        let threadID = turn.threadID
        Task {
            await self.publish(
                outputs,
                draftID: draftID,
                threadID: threadID,
                client: client
            )
        }
    }

    func handleForTesting(
        _ inbound: TelegramInbound,
        username: String? = nil
    ) async {
        await apply(inbound, username: username, replyWith: nil)
    }

    private func configureBotThenPoll() async {
        if let token = try? tokens.load() {
            try? await makeClient(token).configureBotProfile()
        }
        await pollLoop()
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
                        username: update.message?.from?.username
                            ?? update.callbackQuery?.from.username,
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
        username: String? = nil,
        replyWith client: (any TelegramAPIClient)?
    ) async {
        outboundChatID = inbound.chatID
        if case let .callback(_, _, _, queryID, _) = inbound {
            try? await client?.answerCallbackQuery(id: queryID)
        }
        let (next, decisions) = router.handle(
            inbound,
            state: routing,
            username: username
        )
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
            routing.pendingCode = nil
            statusText = TelegramCopy.paired
            await worker?.telegramPersist { document in
                document.telegram.pairedUserID = userID
                document.telegram.pairedChatID = chatID
                document.telegram.pendingPairingCode = nil
            }
            await reply(TelegramCopy.paired, threadID: nil, client: client)
            scheduleCatalogSync()
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
        case let .prompt(sessionID, text, attachments):
            await prompt(
                sessionID: sessionID,
                text: text,
                attachments: attachments,
                client: client
            )
        case .ignoreArchivedTopic:
            return
        case let .dropTopic(threadID):
            routing.sessionIDByThreadID.removeValue(forKey: threadID.rawValue)
            await persistMapping()
        case .askFindQuery:
            await reply(
                TelegramCopy.askFindQuery,
                threadID: routing.pickerThreadID,
                client: client
            )
        case let .search(query):
            await search(query: query, client: client)
        case let .attach(sessionID):
            await attach(sessionID: sessionID, client: client)
        case let .answerPermission(sessionID, optionID):
            worker?.telegramAnswerPermission(sessionID: sessionID, optionID: optionID)
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
            await reply(TelegramCopy.reply(for: error), threadID: threadID, client: client)
        }
    }

    private func search(query: String, client: (any TelegramAPIClient)?) async {
        do {
            let result = try await worker?.telegramFind(query: query)
            let matches = result?.matches ?? []
            routing.findChoices = matches
            guard !matches.isEmpty else {
                await reply(
                    result?.message.isEmpty == false
                        ? result!.message
                        : TelegramCopy.noFindMatches,
                    threadID: routing.pickerThreadID,
                    client: client
                )
                return
            }
            let listing = matches.enumerated().map { index, match in
                "\(index + 1). \(match.title)\n\(match.reason)"
            }.joined(separator: "\n\n")
            let header = result?.message.isEmpty == false
                ? result!.message
                : TelegramCopy.pickFindMatch
            let buttons = matches.enumerated().map { index, match in
                [
                    TelegramInlineButton(
                        title: String(match.title.prefix(40)),
                        data: TelegramCallbackData.find(index)
                    ),
                ]
            }
            await reply(
                header + "\n\n" + listing,
                threadID: routing.pickerThreadID,
                markup: TelegramReplyMarkup(rows: buttons),
                client: client
            )
        } catch {
            await reply(error.localizedDescription, threadID: routing.pickerThreadID, client: client)
        }
    }

    private func attach(sessionID: String, client: (any TelegramAPIClient)?) async {
        do {
            let created = try await worker?.telegramPrepareAttachment(sessionID: sessionID)
            guard let created, let chatID = routing.pairedChatID else { return }
            if let existing = threadID(for: created.sessionID) {
                await reply(
                    "This conversation is already “\(created.title)” in its topic.",
                    threadID: existing,
                    client: client
                )
                return
            }
            let threadID: TelegramThreadID
            if let client {
                threadID = try await client.createForumTopic(
                    chatID: chatID,
                    name: created.title
                )
            } else {
                return
            }
            bind(sessionID: created.sessionID, threadID: threadID)
            await persistMapping()
            await reply(
                "Opened “\(created.title)”. Messages in this topic are turns of that conversation.",
                threadID: threadID,
                client: client
            )
        } catch {
            await reply(
                TelegramCopy.reply(for: error),
                threadID: routing.pickerThreadID,
                client: client
            )
        }
    }

    private func prompt(
        sessionID: String,
        text: String,
        attachments: [TelegramTurnAttachment],
        client: (any TelegramAPIClient)?
    ) async {
        promptTasks[sessionID]?.cancel()
        let threadID = threadID(for: sessionID)
        let draftID = Int.random(in: 1...Int.max)
        activeTurns[sessionID] = ActiveTelegramTurn(
            presenter: TelegramTurnPresenter(),
            draftID: draftID,
            threadID: threadID
        )
        promptTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.consume(
                .started,
                sessionID: sessionID,
                draftID: draftID,
                threadID: threadID,
                client: client
            )
            do {
                let resolved = await self.resolve(attachments, client: client)
                let blocks = TelegramTurnBuilder.blocks(
                    text: text,
                    attachments: resolved
                )
                let answer = try await self.worker?.telegramPrompt(
                    sessionID: sessionID,
                    blocks: blocks
                ) { [weak self] update in
                    Task { @MainActor in
                        await self?.handlePromptUpdate(
                            update,
                            sessionID: sessionID,
                            draftID: draftID,
                            threadID: threadID,
                            client: client
                        )
                    }
                } ?? ""
                await self.consume(
                    .finished(answer),
                    sessionID: sessionID,
                    draftID: draftID,
                    threadID: threadID,
                    client: client
                )
            } catch is CancellationError {
                self.finishTurn(sessionID, draftID: draftID)
                return
            } catch {
                await self.consume(
                    .failed(TelegramCopy.reply(for: error)),
                    sessionID: sessionID,
                    draftID: draftID,
                    threadID: threadID,
                    client: client
                )
            }
            self.finishTurn(sessionID, draftID: draftID)
        }
    }

    private func handlePromptUpdate(
        _ update: GrokPromptUpdate,
        sessionID: String,
        draftID: Int,
        threadID: TelegramThreadID?,
        client: (any TelegramAPIClient)?
    ) async {
        switch update {
        case let .draft(text):
            await consume(
                .draft(text),
                sessionID: sessionID,
                draftID: draftID,
                threadID: threadID,
                client: client
            )
        case let .status(title):
            await consume(
                .status(title),
                sessionID: sessionID,
                draftID: draftID,
                threadID: threadID,
                client: client
            )
        case let .permission(prompt):
            let options = prompt.options.map {
                TelegramPermissionOption(id: $0.id, title: $0.title)
            }
            routing.pendingPermissionSessionID = sessionID
            routing.pendingPermissionOptions = options
            await consume(
                .permission(title: prompt.title, options: options),
                sessionID: sessionID,
                draftID: draftID,
                threadID: threadID,
                client: client
            )
        }
    }

    private func consume(
        _ input: TelegramTurnInput,
        sessionID: String,
        draftID: Int,
        threadID: TelegramThreadID?,
        client: (any TelegramAPIClient)?
    ) async {
        guard var turn = activeTurns[sessionID], turn.draftID == draftID else {
            return
        }
        let outputs = turn.presenter.consume(input)
        activeTurns[sessionID] = turn
        await publish(
            outputs,
            draftID: draftID,
            threadID: threadID,
            client: client
        )
    }

    private func finishTurn(_ sessionID: String, draftID: Int) {
        guard activeTurns[sessionID]?.draftID == draftID else { return }
        activeTurns[sessionID] = nil
    }

    private func publish(
        _ outputs: [TelegramTurnOutput],
        draftID: Int,
        threadID: TelegramThreadID?,
        client: (any TelegramAPIClient)?
    ) async {
        for output in outputs {
            switch output {
            case let .draft(text):
                await draft(
                    text,
                    draftID: draftID,
                    threadID: threadID,
                    client: client
                )
            case let .message(text, markup):
                await reply(
                    text,
                    threadID: threadID,
                    markup: markup,
                    client: client
                )
            }
        }
    }

    private func draft(
        _ text: String,
        draftID: Int,
        threadID: TelegramThreadID?,
        client: (any TelegramAPIClient)?
    ) async {
        guard let client, let chatID = routing.pairedChatID ?? fallbackChatID else {
            return
        }
        do {
            try await client.sendMessageDraft(
                chatID: chatID,
                threadID: threadID,
                draftID: draftID,
                text: text
            )
        } catch {
            statusText = error.localizedDescription
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

    private func apply(
        _ telegram: TelegramMetadata,
        archivedSessionIDs: Set<String>
    ) {
        routing.pairedUserID = telegram.pairedUserID
        routing.pairedChatID = telegram.pairedChatID
        routing.sessionIDByThreadID = telegram.sessionIDByThreadID
        routing.archivedSessionIDs = archivedSessionIDs
        routing.pendingCode = telegram.pendingPairingCode
        pairingCode = telegram.pendingPairingCode
        isPaired = telegram.pairedUserID != nil && telegram.pairedChatID != nil
        refreshAllowlist()
        if isPaired {
            statusText = TelegramCopy.paired
        } else if let username = routing.allowedUsername, !username.isEmpty {
            pairingCode = nil
            routing.pendingCode = nil
            statusText = TelegramCopy.listening(for: username)
        }
    }

    private func refreshAllowlist() {
        let username = try? tokens.allowedUsername()
        let normalized = username.map(TelegramUsername.normalize)
        routing.allowedUsername = normalized?.isEmpty == false ? normalized : nil
        allowedUsername = routing.allowedUsername
    }

    private func archivedIDs(in metadata: MetadataDocument) -> Set<String> {
        Set(metadata.sessions.compactMap { id, value in
            value.archived ? id : nil
        })
    }

    private func resolve(
        _ attachments: [TelegramTurnAttachment],
        client: (any TelegramAPIClient)?
    ) async -> [TelegramResolvedAttachment] {
        guard let client else { return [] }
        var resolved: [TelegramResolvedAttachment] = []
        for attachment in attachments {
            do {
                let data = try await client.downloadFile(id: attachment.fileID)
                let mime = attachment.mimeType
                    ?? (attachment.kind == .photo ? "image/jpeg" : "application/octet-stream")
                var transcript: String?
                if attachment.kind == .voice {
                    transcript = await transcriber.transcribe(
                        data: data,
                        mimeType: mime
                    )
                }
                resolved.append(
                    TelegramResolvedAttachment(
                        kind: attachment.kind,
                        fileName: attachment.fileName,
                        mimeType: mime,
                        data: data,
                        transcript: transcript
                    )
                )
            } catch {
                statusText = error.localizedDescription
            }
        }
        return resolved
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
