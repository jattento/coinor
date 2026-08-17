import Foundation

struct TelegramRouter: Sendable {
    func handle(
        _ inbound: TelegramInbound,
        state: TelegramRoutingState
    ) -> (TelegramRoutingState, [TelegramDecision]) {
        var next = state
        switch inbound {
        case .ignored:
            return (next, [.ignore])

        case let .start(userID, chatID, code):
            return handleStart(
                userID: userID,
                chatID: chatID,
                code: code,
                state: &next
            )

        case let .help(userID, chatID, _):
            guard isAuthorized(userID: userID, chatID: chatID, state: next) else {
                return (next, [.rejectUnauthorized])
            }
            return (next, [.sendHelp])

        case let .new(userID, chatID, threadID):
            guard isAuthorized(userID: userID, chatID: chatID, state: next) else {
                return (next, [.rejectUnauthorized])
            }
            next.awaitingWorktreeNameForProjectID = nil
            next.pickerThreadID = threadID
            return (next, [.sendProjectPicker])

        case let .topicCreated(userID, chatID, threadID, _):
            guard isAuthorized(userID: userID, chatID: chatID, state: next) else {
                return (next, [.rejectUnauthorized])
            }
            next.awaitingWorktreeNameForProjectID = nil
            next.pickerThreadID = threadID
            return (next, [.sendProjectPicker])

        case let .callback(userID, chatID, threadID, _, data):
            guard isAuthorized(userID: userID, chatID: chatID, state: next) else {
                return (next, [.rejectUnauthorized])
            }
            return handleCallback(data: data, threadID: threadID, state: &next)

        case let .text(userID, chatID, threadID, text):
            guard isAuthorized(userID: userID, chatID: chatID, state: next) else {
                return (next, [.rejectUnauthorized])
            }
            if let projectID = next.awaitingWorktreeNameForProjectID {
                next.awaitingWorktreeNameForProjectID = nil
                return (
                    next,
                    [
                        .createConversation(
                            projectID: projectID,
                            worktreeName: text,
                            threadID: threadID ?? next.pickerThreadID
                        ),
                    ]
                )
            }
            guard let threadID,
                  let sessionID = next.sessionIDByThreadID[threadID.rawValue] else {
                return (next, [.ignoreUnmappedTopic])
            }
            return (next, [.prompt(sessionID: sessionID, text: text)])
        }
    }

    private func handleStart(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        code: String?,
        state: inout TelegramRoutingState
    ) -> (TelegramRoutingState, [TelegramDecision]) {
        if state.pairedUserID == userID, state.pairedChatID == chatID {
            return (state, [.sendAlreadyPaired])
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
        return (state, [.ignore])
    }

    private func isAuthorized(
        userID: TelegramUserID,
        chatID: TelegramChatID,
        state: TelegramRoutingState
    ) -> Bool {
        state.pairedUserID == userID && state.pairedChatID == chatID
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
