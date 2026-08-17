import Foundation
import Testing

@testable import Coinor

private let pairedUser = TelegramUserID(9)
private let pairedChat = TelegramChatID(9)
private let mappedThread = TelegramThreadID(44)

private func pairedState() -> TelegramRoutingState {
    var state = TelegramRoutingState.empty
    state.pairedUserID = pairedUser
    state.pairedChatID = pairedChat
    state.sessionIDByThreadID = [mappedThread.rawValue: "session-a"]
    return state
}

private func userMessage(
    updateID: Int64 = 1,
    text: String? = nil,
    caption: String? = nil,
    extra: [String: GrokJSONValue] = [:]
) -> GrokJSONValue {
    var message: [String: GrokJSONValue] = [
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
        "message_thread_id": 44,
        "is_topic_message": true,
    ]
    if let text {
        message["text"] = .string(text)
    }
    if let caption {
        message["caption"] = .string(caption)
    }
    for (key, value) in extra {
        message[key] = value
    }
    return [
        "update_id": .int(Int(updateID)),
        "message": .object(message),
    ]
}

private func inbound(from raw: GrokJSONValue) throws -> TelegramInbound {
    try TelegramHTTPClient.inbound(from: TelegramHTTPClient.decodeUpdate(raw))
}

private func decisions(
    _ inbound: TelegramInbound,
    state: TelegramRoutingState = pairedState()
) -> [TelegramDecision] {
    TelegramRouter().handle(inbound, state: state).1
}

@Test
func unauthorizedMappedTextDoesNotBecomeAPrompt() throws {
    let inbound = try inbound(from: userMessage(text: "steal the session"))
    var state = pairedState()
    state.pairedUserID = TelegramUserID(99)
    #expect(decisions(inbound, state: state) == [.rejectUnauthorized])
}

@Test
func mappedTopicTextBecomesAPromptTurn() throws {
    let inbound = try inbound(from: userMessage(text: "fix the finder"))
    #expect(
        decisions(inbound) == [
            .prompt(
                sessionID: "session-a",
                text: "fix the finder",
                attachments: []
            ),
        ]
    )
}

@Test
func mappedPhotoBecomesAPromptTurnWithThePhotoAttachment() throws {
    let inbound = try inbound(
        from: userMessage(
            caption: "see this error",
            extra: [
                "photo": .array([
                    [
                        "file_id": "small",
                        "width": 10,
                        "file_size": 12,
                    ],
                    [
                        "file_id": "large-photo",
                        "width": 800,
                        "file_size": 9_000,
                    ],
                ]),
            ]
        )
    )
    #expect(
        decisions(inbound) == [
            .prompt(
                sessionID: "session-a",
                text: "see this error",
                attachments: [
                    TelegramTurnAttachment(
                        kind: .photo,
                        fileID: "large-photo",
                        fileName: "photo.jpg",
                        mimeType: "image/jpeg"
                    ),
                ]
            ),
        ]
    )
}

@Test
func mappedDocumentBecomesAPromptTurn() throws {
    let inbound = try inbound(
        from: userMessage(
            extra: [
                "document": [
                    "file_id": "doc-1",
                    "file_name": "notes.txt",
                    "mime_type": "text/plain",
                ],
            ]
        )
    )
    guard case let .prompt(sessionID, _, attachments) = decisions(inbound).first else {
        Issue.record("expected a prompt turn")
        return
    }
    #expect(sessionID == "session-a")
    #expect(attachments == [
        TelegramTurnAttachment(
            kind: .document,
            fileID: "doc-1",
            fileName: "notes.txt",
            mimeType: "text/plain"
        ),
    ])
}

@Test
func mappedVoiceBecomesAPromptTurn() throws {
    let inbound = try inbound(
        from: userMessage(
            extra: [
                "voice": [
                    "file_id": "voice-1",
                    "mime_type": "audio/ogg",
                ],
            ]
        )
    )
    #expect(
        decisions(inbound) == [
            .prompt(
                sessionID: "session-a",
                text: "",
                attachments: [
                    TelegramTurnAttachment(
                        kind: .voice,
                        fileID: "voice-1",
                        fileName: "voice.ogg",
                        mimeType: "audio/ogg"
                    ),
                ]
            ),
        ]
    )
}

@Test
func findThenChosenMatchAttachesThatConversation() throws {
    let find = try inbound(from: userMessage(text: "/find sidebar drag"))
    #expect(decisions(find) == [.search(query: "sidebar drag")])

    var state = pairedState()
    state.findChoices = [
        TelegramFindMatch(
            sessionID: "session-b",
            title: "Fix sidebar",
            reason: "mentions drag"
        ),
    ]
    let pick = TelegramInbound.callback(
        userID: pairedUser,
        chatID: pairedChat,
        threadID: mappedThread,
        queryID: "q",
        data: TelegramCallbackData.find(0)
    )
    #expect(decisions(pick, state: state) == [.attach(sessionID: "session-b")])
}

@Test
func permissionCallbackDuringAPromptAnswersACP() {
    var state = pairedState()
    state.pendingPermissionSessionID = "session-a"
    state.pendingPermissionOptions = [
        TelegramPermissionOption(id: "allow-once", title: "Allow once"),
    ]
    let inbound = TelegramInbound.callback(
        userID: pairedUser,
        chatID: pairedChat,
        threadID: mappedThread,
        queryID: "q",
        data: TelegramCallbackData.permission(0)
    )
    #expect(
        decisions(inbound, state: state)
            == [.answerPermission(sessionID: "session-a", optionID: "allow-once")]
    )
}

@Test
func archivedTopicMessagesAreIgnored() {
    var state = pairedState()
    state.archivedSessionIDs = ["session-a"]
    let inbound = TelegramInbound.text(
        userID: pairedUser,
        chatID: pairedChat,
        threadID: mappedThread,
        text: "keep going",
        attachments: []
    )
    #expect(decisions(inbound, state: state) == [.ignoreArchivedTopic])
}

@Test
func closingAnActiveTopicDropsOnlyTheSurface() {
    let state = pairedState()
    let inbound = TelegramInbound.topicClosed(
        userID: pairedUser,
        chatID: pairedChat,
        threadID: mappedThread
    )
    let (next, result) = TelegramRouter().handle(inbound, state: state)
    #expect(result == [.dropTopic(mappedThread)])
    #expect(next.sessionIDByThreadID[mappedThread.rawValue] == nil)
}

@Test
func turnBuilderPutsPhotoBytesOnTheACPPrompt() {
    let pixels = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
    let blocks = TelegramTurnBuilder.blocks(
        text: "see this error",
        attachments: [
            TelegramResolvedAttachment(
                kind: .photo,
                fileName: "photo.jpg",
                mimeType: "image/jpeg",
                data: pixels,
                transcript: nil
            ),
        ]
    )
    #expect(blocks.count == 2)
    #expect(blocks[0]["type"]?.stringValue == "text")
    #expect(blocks[0]["text"]?.stringValue == "see this error")
    #expect(blocks[1]["type"]?.stringValue == "image")
    #expect(blocks[1]["data"]?.stringValue == pixels.base64EncodedString())
}

@Test
func turnBuilderIncludesVoiceTranscriptAndAudio() {
    let audio = Data([0x4F, 0x67, 0x67, 0x53])
    let blocks = TelegramTurnBuilder.blocks(
        text: "",
        attachments: [
            TelegramResolvedAttachment(
                kind: .voice,
                fileName: "voice.ogg",
                mimeType: "audio/ogg",
                data: audio,
                transcript: "fix the sidebar"
            ),
        ]
    )
    let text = blocks[0]["text"]?.stringValue ?? ""
    #expect(text.contains("fix the sidebar"))
    #expect(blocks.contains { $0["type"]?.stringValue == "audio" })
    #expect(
        blocks.first { $0["type"]?.stringValue == "audio" }?["data"]?.stringValue
            == audio.base64EncodedString()
    )
}

@Test
func turnBuilderInlinesPlainTextDocuments() {
    let body = Data("hello from a file".utf8)
    let blocks = TelegramTurnBuilder.blocks(
        text: "",
        attachments: [
            TelegramResolvedAttachment(
                kind: .document,
                fileName: "notes.txt",
                mimeType: "text/plain",
                data: body,
                transcript: nil
            ),
        ]
    )
    #expect(blocks.count == 1)
    #expect(blocks[0]["text"]?.stringValue?.contains("hello from a file") == true)
}

@Test
func subagentStatusCopyNamesTheParentWorkNotANewConversation() {
    let started = GrokSubagentLifecycleObservation(
        kind: .started,
        childSessionID: "child",
        parentSessionID: "session-a",
        description: "explore",
        subagentType: nil,
        status: nil,
        timestamp: nil
    )
    #expect(TelegramCopy.subagentLine(started) == "Subagent started: explore")
    #expect(!TelegramCopy.subagentLine(started).localizedCaseInsensitiveContains("conversation"))
}
