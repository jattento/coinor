import Foundation
import Testing

@testable import Coinor

@Test
func telegramStartWithoutCodeAsksForPairingHelp() {
    var state = TelegramRoutingState.empty
    state.pendingCode = "ABCD2345"
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .start(userID: TelegramUserID(1), chatID: TelegramChatID(1), code: nil),
        state: state
    )
    #expect(next.pairedUserID == nil)
    #expect(decisions == [.sendPairingHelp])
}

@Test
func telegramStartWithWrongCodeIsRejected() {
    var state = TelegramRoutingState.empty
    state.pendingCode = "ABCD2345"
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .start(userID: TelegramUserID(1), chatID: TelegramChatID(1), code: "NOPE"),
        state: state
    )
    #expect(decisions == [.rejectPairing])
}

@Test
func telegramStartWithMatchingCodePairsTheChat() {
    var state = TelegramRoutingState.empty
    state.pendingCode = "ABCD2345"
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .start(userID: TelegramUserID(9), chatID: TelegramChatID(9), code: "abcd2345"),
        state: state
    )
    #expect(next.pairedUserID == TelegramUserID(9))
    #expect(next.pairedChatID == TelegramChatID(9))
    #expect(next.pendingCode == nil)
    #expect(decisions == [.pair(userID: TelegramUserID(9), chatID: TelegramChatID(9))])
}

@Test
func telegramIgnoresEveryoneExceptThePairedUser() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .new(userID: TelegramUserID(2), chatID: TelegramChatID(2), threadID: nil),
        state: state
    )
    #expect(decisions == [.rejectUnauthorized])
}

@Test
func telegramNewAsksForAProject() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .new(userID: TelegramUserID(9), chatID: TelegramChatID(9), threadID: nil),
        state: state
    )
    #expect(next.pickerThreadID == nil)
    #expect(decisions == [.sendProjectPicker])
}

@Test
func telegramUserCreatedTopicIsNew() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .topicCreated(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: TelegramThreadID(44),
            name: "Fix finder"
        ),
        state: state
    )
    #expect(next.pickerThreadID == TelegramThreadID(44))
    #expect(decisions == [.sendProjectPicker])
}

@Test
func telegramProjectCallbackAsksForWorktree() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    state.projectChoices = [
        TelegramProjectChoice(id: "/tmp/coinor", title: "coinor"),
    ]
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .callback(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: TelegramThreadID(44),
            queryID: "q",
            data: TelegramCallbackData.project(0)
        ),
        state: state
    )
    #expect(decisions == [.sendWorktreePicker(projectID: "/tmp/coinor")])
}

@Test
func telegramMainCheckoutCallbackCreatesAConversation() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    state.projectChoices = [
        TelegramProjectChoice(id: "/tmp/coinor", title: "coinor"),
    ]
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .callback(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: TelegramThreadID(44),
            queryID: "q",
            data: TelegramCallbackData.worktreeMain(0)
        ),
        state: state
    )
    #expect(
        decisions == [
            .createConversation(
                projectID: "/tmp/coinor",
                worktreeName: nil,
                threadID: TelegramThreadID(44)
            ),
        ]
    )
}

@Test
func telegramFindWithoutQueryAsksWhatToSearch() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .find(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: nil,
            query: nil
        ),
        state: state
    )
    #expect(next.awaitingFindQuery)
    #expect(decisions == [.askFindQuery])
}

@Test
func telegramFindWithQuerySearchesImmediately() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .find(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: nil,
            query: "refactor of foo"
        ),
        state: state
    )
    #expect(decisions == [.search(query: "refactor of foo")])
}

@Test
func telegramFindResultCallbackAttachesTheConversation() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    state.findChoices = [
        TelegramFindMatch(sessionID: "session-a", title: "Fix finder", reason: "mentions tabs"),
    ]
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .callback(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: nil,
            queryID: "q",
            data: TelegramCallbackData.find(0)
        ),
        state: state
    )
    #expect(decisions == [.attach(sessionID: "session-a")])
}

@Test
func telegramPermissionCallbackAnswersThePrompt() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    state.pendingPermissionSessionID = "session-a"
    state.pendingPermissionOptions = [
        TelegramPermissionOption(id: "allow-once", title: "Allow once"),
    ]
    let router = TelegramRouter()
    let (next, decisions) = router.handle(
        .callback(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: TelegramThreadID(44),
            queryID: "q",
            data: TelegramCallbackData.permission(0)
        ),
        state: state
    )
    #expect(next.pendingPermissionSessionID == nil)
    #expect(
        decisions == [.answerPermission(sessionID: "session-a", optionID: "allow-once")]
    )
}

@Test
func telegramMappedTopicTextIsAPrompt() {
    var state = TelegramRoutingState.empty
    state.pairedUserID = TelegramUserID(9)
    state.pairedChatID = TelegramChatID(9)
    state.sessionIDByThreadID = [44: "session-a"]
    let router = TelegramRouter()
    let (_, decisions) = router.handle(
        .text(
            userID: TelegramUserID(9),
            chatID: TelegramChatID(9),
            threadID: TelegramThreadID(44),
            text: "fix the finder"
        ),
        state: state
    )
    #expect(decisions == [.prompt(sessionID: "session-a", text: "fix the finder")])
}

@Test
func telegramParsesAStartCommandFromAnUpdate() throws {
    let update = try TelegramHTTPClient.decodeUpdate(
        [
            "update_id": 7,
            "message": [
                "message_id": 1,
                "from": [
                    "id": 9,
                    "is_bot": false,
                    "first_name": "Jose",
                ],
                "chat": [
                    "id": 9,
                    "type": "private",
                ],
                "text": "/start ABCD2345",
            ],
        ]
    )
    #expect(
        TelegramHTTPClient.inbound(from: update)
            == .start(userID: TelegramUserID(9), chatID: TelegramChatID(9), code: "ABCD2345")
    )
}