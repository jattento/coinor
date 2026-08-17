import Foundation

extension AppCoordinator: TelegramWorking {
    func telegramLocalProjects() -> [TelegramProjectChoice] {
        catalog.projects.compactMap { project in
            guard ProjectIdentity(rawValue: project.projectID).target == .local else {
                return nil
            }
            return TelegramProjectChoice(
                id: project.projectID,
                title: projectDisplayName(project.projectID)
            )
        }
    }

    func telegramCreateConversation(
        projectID: String,
        worktreeName: String?
    ) async throws -> TelegramCreatedConversation {
        guard ProjectIdentity(rawValue: projectID).target == .local else {
            throw TelegramBridgeError.remoteProjectsAreDesktopOnly
        }
        if let worktreeName {
            let sessionID = try await createLocalWorktreeConversation(
                in: projectID,
                name: worktreeName
            )
            return TelegramCreatedConversation(
                sessionID: sessionID,
                title: session(sessionID)?.title ?? "New Conversation"
            )
        }
        let sessionID = try await createACPDrivenConversation(in: projectID)
        return TelegramCreatedConversation(
            sessionID: sessionID,
            title: "New Conversation"
        )
    }

    func telegramPrompt(
        sessionID: String,
        text: String,
        onUpdate: @escaping @Sendable (GrokPromptUpdate) -> Void
    ) async throws -> String {
        guard let controlClient, hostAliasBySessionID[sessionID] == nil else {
            throw TelegramBridgeError.remoteProjectsAreDesktopOnly
        }
        let id = GrokSessionID(sessionID)
        do {
            try await controlClient.loadSession(id)
        } catch {
            // A session we just created is already loaded.
        }
        return try await controlClient.prompt(
            sessionID: id,
            text: text,
            onUpdate: onUpdate
        )
    }

    func telegramAnswerPermission(sessionID: String, optionID: String?) {
        Task {
            await controlClient?.answerPermission(
                sessionID: sessionID,
                optionID: optionID
            )
        }
    }

    func telegramFind(
        query: String
    ) async throws -> (message: String, matches: [TelegramFindMatch]) {
        guard let agenticFinder else {
            throw TelegramBridgeError.finderUnavailable
        }
        let candidates = await agenticFinderCandidates().filter {
            $0.remoteHost == nil
        }
        let response = try await agenticFinder.find(
            AgenticFinderRequest(query: query, candidates: candidates)
        )
        let matches = response.matches.prefix(5).map { match in
            let title = summaries.first { $0.id == match.sessionID }?.title
                ?? match.sessionID
            return TelegramFindMatch(
                sessionID: match.sessionID,
                title: title,
                reason: match.reason
            )
        }
        return (response.message, Array(matches))
    }

    func telegramPrepareAttachment(
        sessionID: String
    ) async throws -> TelegramCreatedConversation {
        guard hostAliasBySessionID[sessionID] == nil else {
            throw TelegramBridgeError.remoteProjectsAreDesktopOnly
        }
        guard let summary = summaries.first(where: { $0.id == sessionID }) else {
            throw TelegramBridgeError.conversationMissing
        }
        let plan = AgenticFinderActionPlan.resolve(
            match: AgenticFinderMatch(
                sessionID: sessionID,
                reason: "",
                confidence: 1,
                open: true,
                pin: false
            ),
            summary: summary,
            metadata: metadata
        )
        _ = await persist { document in
            plan.apply(to: &document)
        }
        if plan.shouldUnarchiveConversation {
            await telegram.reopenTopic(for: sessionID)
        }
        return TelegramCreatedConversation(
            sessionID: sessionID,
            title: summary.title
        )
    }

    func telegramPersist(
        _ transform: @escaping @Sendable (inout MetadataDocument) -> Void
    ) async {
        _ = await persist(transform)
    }

    func telegramConversationTitle(_ sessionID: String) -> String? {
        session(sessionID)?.title
    }

    func shareConversationOnTelegram(_ sessionID: String) {
        guard canShareOnTelegram(sessionID) else { return }
        let title = session(sessionID)?.title ?? "Conversation"
        Task { [weak self] in
            await self?.telegram.share(sessionID: sessionID, title: title)
        }
    }

    func canShareOnTelegram(_ sessionID: String) -> Bool {
        telegram.isPaired
            && hostAliasBySessionID[sessionID] == nil
            && !metadata.telegram.threadIDBySessionID.keys.contains(sessionID)
    }

    private func createACPDrivenConversation(
        in projectID: String
    ) async throws -> String {
        guard let controlClient else {
            throw GrokControlError.notConnected
        }
        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = mainCheckout(for: projectID)
        try await controlClient.createSession(
            id: GrokSessionID(sessionID),
            cwd: workingDirectory
        )
        pendingSessions[sessionID] = SessionSummary(
            id: sessionID,
            projectID: projectID,
            title: "New Conversation",
            lastActivityAt: Date()
        )
        rebuildCatalog()
        return sessionID
    }

    private func createLocalWorktreeConversation(
        in projectID: String,
        name: String
    ) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let checkout = URL(
            fileURLWithPath: mainCheckout(for: projectID),
            isDirectory: true
        )
        let result = try await Task.detached {
            try WorktreeService().prepareCreation(
                named: trimmed,
                from: checkout
            )
        }.value
        applyMainCheckout(
            projectID,
            path: result.plan.project.mainCheckout.path
        )
        if let warning = result.warning {
            presentTelegramWarning(warning)
        }
        return createConversation(
            in: projectID,
            workingDirectory: result.plan.workingDirectory.path,
            additionalArguments: result.plan.grokArguments
        )
    }
}

enum TelegramBridgeError: Error, Equatable, LocalizedError, Sendable {
    case remoteProjectsAreDesktopOnly
    case finderUnavailable
    case conversationMissing

    var errorDescription: String? {
        switch self {
        case .remoteProjectsAreDesktopOnly:
            return "Remote projects stay on the Mac. Pair Telegram on that computer instead."
        case .finderUnavailable:
            return "Conan Code could not start a conversation search."
        case .conversationMissing:
            return "That conversation is no longer in the catalog."
        }
    }
}
