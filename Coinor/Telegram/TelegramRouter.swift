import Foundation

struct TelegramRouter: Sendable {
    func handle(
        _ inbound: TelegramInbound,
        state: TelegramRoutingState,
        username: String? = nil
    ) -> (TelegramRoutingState, [TelegramDecision]) {
        var next = state
        var claimed: [TelegramDecision] = []
        if let decision = claimAllowedUser(
            inbound,
            username: username,
            state: &next
        ) {
            claimed = [decision]
        }
        switch inbound {
        case .ignored:
            return (next, claimed.isEmpty ? [.ignore] : claimed)

        case let .start(userID, chatID, code):
            let (stateAfterStart, decisions) = handleStart(
                userID: userID,
                chatID: chatID,
                username: username,
                code: code,
                state: &next
            )
            return (stateAfterStart, merge(claimed, decisions))

        case let .help(userID, chatID, _):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            return (next, merge(claimed, [.sendHelp]))

        case let .new(userID, chatID, threadID):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            next.awaitingWorktreeNameForProjectID = nil
            next.awaitingFindQuery = false
            next.pickerThreadID = threadID
            return (next, merge(claimed, [.sendProjectPicker]))

        case let .find(userID, chatID, threadID, query):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            next.awaitingWorktreeNameForProjectID = nil
            next.pickerThreadID = threadID
            let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                next.awaitingFindQuery = true
                return (next, merge(claimed, [.askFindQuery]))
            }
            next.awaitingFindQuery = false
            return (next, merge(claimed, [.search(query: trimmed)]))

        case let .topicCreated(userID, chatID, threadID, _):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            next.awaitingWorktreeNameForProjectID = nil
            next.awaitingFindQuery = false
            next.pickerThreadID = threadID
            return (next, merge(claimed, [.sendProjectPicker]))

        case let .topicClosed(userID, chatID, threadID):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            if let sessionID = next.sessionIDByThreadID[threadID.rawValue],
               next.archivedSessionIDs.contains(sessionID) {
                return (next, merge(claimed, [.ignore]))
            }
            next.sessionIDByThreadID.removeValue(forKey: threadID.rawValue)
            return (next, merge(claimed, [.dropTopic(threadID)]))

        case let .callback(userID, chatID, threadID, _, data):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            let (stateAfterCallback, decisions) = handleCallback(
                data: data,
                threadID: threadID,
                state: &next
            )
            return (stateAfterCallback, merge(claimed, decisions))

        case let .text(userID, chatID, threadID, text, attachments):
            guard isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: next
            ) else {
                return (next, [.rejectUnauthorized])
            }
            if let projectID = next.awaitingWorktreeNameForProjectID, attachments.isEmpty {
                next.awaitingWorktreeNameForProjectID = nil
                return (
                    next,
                    merge(claimed, [
                        .createConversation(
                            projectID: projectID,
                            worktreeName: text,
                            threadID: threadID ?? next.pickerThreadID
                        ),
                    ])
                )
            }
            if next.awaitingFindQuery, attachments.isEmpty {
                next.awaitingFindQuery = false
                return (next, merge(claimed, [.search(query: text)]))
            }
            guard let threadID,
                  let sessionID = next.sessionIDByThreadID[threadID.rawValue] else {
                return (next, merge(claimed, [.ignoreUnmappedTopic]))
            }
            if next.archivedSessionIDs.contains(sessionID) {
                return (next, merge(claimed, [.ignoreArchivedTopic]))
            }
            return (
                next,
                merge(claimed, [
                    .prompt(
                        sessionID: sessionID,
                        text: text,
                        attachments: attachments
                    ),
                ])
            )
        }
    }

    private func handleStart(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        username: String?,
        code: String?,
        state: inout TelegramRoutingState
    ) -> (TelegramRoutingState, [TelegramDecision]) {
        if state.pairedUserID == userID, state.pairedChatID == chatID {
            return (state, [.sendAlreadyPaired])
        }
        if hasUsernameAllowlist(state) {
            if isAuthorized(
                userID: userID,
                chatID: chatID,
                username: username,
                state: state
            ) {
                return (state, [.sendAlreadyPaired])
            }
            return (state, [.rejectUnauthorized])
        }
        if state.isPaired {
            return (state, [.rejectUnauthorized])
        }
        let expected = state.pendingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let offered = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected, !expected.isEmpty else {
            return (state, [.sendPairingHelp])
        }
        guard let offered, offered.caseInsensitiveCompare(expected) == .orderedSame else {
            return (state, offered == nil ? [.sendPairingHelp] : [.rejectPairing])
        }
        state.pairedUserID = userID
        state.pairedChatID = chatID
        state.pendingCode = nil
        return (state, [.pair(userID: userID, chatID: chatID)])
    }

    private func handleCallback(
        data: String,
        threadID: TelegramThreadID?,
        state: inout TelegramRoutingState
    ) -> (TelegramRoutingState, [TelegramDecision]) {
        if let index = TelegramCallbackData.projectIndex(data) {
            guard let project = project(at: index, state: state) else {
                return (state, [.sendProjectPicker])
            }
            state.pickerThreadID = threadID ?? state.pickerThreadID
            return (state, [.sendWorktreePicker(projectID: project.id)])
        }
        if let index = TelegramCallbackData.worktreeMainIndex(data) {
            guard let project = project(at: index, state: state) else {
                return (state, [.sendProjectPicker])
            }
            state.awaitingWorktreeNameForProjectID = nil
            return (
                state,
                [
                    .createConversation(
                        projectID: project.id,
                        worktreeName: nil,
                        threadID: threadID ?? state.pickerThreadID
                    ),
                ]
            )
        }
        if let index = TelegramCallbackData.worktreeNewIndex(data) {
            guard let project = project(at: index, state: state) else {
                return (state, [.sendProjectPicker])
            }
            state.awaitingWorktreeNameForProjectID = project.id
            state.pickerThreadID = threadID ?? state.pickerThreadID
            return (state, [.askWorktreeName(projectID: project.id)])
        }
        if let index = TelegramCallbackData.findIndex(data) {
            guard state.findChoices.indices.contains(index) else {
                return (state, [.askFindQuery])
            }
            return (state, [.attach(sessionID: state.findChoices[index].sessionID)])
        }
        if data == TelegramCallbackData.permissionDeny {
            guard let sessionID = state.pendingPermissionSessionID else {
                return (state, [.ignore])
            }
            state.pendingPermissionSessionID = nil
            state.pendingPermissionOptions = []
            return (state, [.answerPermission(sessionID: sessionID, optionID: nil)])
        }
        if let index = TelegramCallbackData.permissionIndex(data) {
            guard let sessionID = state.pendingPermissionSessionID,
                  state.pendingPermissionOptions.indices.contains(index) else {
                return (state, [.ignore])
            }
            let optionID = state.pendingPermissionOptions[index].id
            state.pendingPermissionSessionID = nil
            state.pendingPermissionOptions = []
            return (state, [.answerPermission(sessionID: sessionID, optionID: optionID)])
        }
        return (state, [.ignore])
    }

    private func isAuthorized(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        username: String?,
        state: TelegramRoutingState
    ) -> Bool {
        if state.pairedUserID == userID, state.pairedChatID == chatID {
            return true
        }
        if state.isPaired {
            return false
        }
        return TelegramUsername.matches(username, allowed: state.allowedUsername)
    }

    private func hasUsernameAllowlist(_ state: TelegramRoutingState) -> Bool {
        guard let allowed = state.allowedUsername else { return false }
        return !TelegramUsername.normalize(allowed).isEmpty
    }

    private func claimAllowedUser(
        _ inbound: TelegramInbound,
        username: String?,
        state: inout TelegramRoutingState
    ) -> TelegramDecision? {
        guard hasUsernameAllowlist(state),
              !state.isPaired,
              let userID = inbound.userID,
              let chatID = inbound.chatID,
              TelegramUsername.matches(username, allowed: state.allowedUsername) else {
            return nil
        }
        state.pairedUserID = userID
        state.pairedChatID = chatID
        state.pendingCode = nil
        return .pair(userID: userID, chatID: chatID)
    }

    private func merge(
        _ claimed: [TelegramDecision],
        _ decisions: [TelegramDecision]
    ) -> [TelegramDecision] {
        if claimed.isEmpty {
            return decisions
        }
        if decisions == [.rejectUnauthorized] {
            return decisions
        }
        return claimed + decisions.filter { $0 != claimed[0] }
    }

    private func project(
        at index: Int,
        state: TelegramRoutingState
    ) -> TelegramProjectChoice? {
        guard state.projectChoices.indices.contains(index) else {
            return nil
        }
        return state.projectChoices[index]
    }
}

enum TelegramPairingCode {
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate(using generator: inout some RandomNumberGenerator) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(
            (0..<8).map { _ in
                alphabet.randomElement(using: &generator)!
            }
        )
    }
}
