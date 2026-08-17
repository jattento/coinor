import Foundation
import Testing

@testable import Coinor

private func observation(
    _ kind: GrokSubagentLifecycleObservation.Kind,
    label: String = "explore"
) -> GrokSubagentLifecycleObservation {
    GrokSubagentLifecycleObservation(
        kind: kind,
        childSessionID: "child-\(label)",
        parentSessionID: "session-a",
        description: label,
        subagentType: nil,
        status: nil,
        timestamp: nil
    )
}

@Test
func phoneTurnPublishesOneWorkingDraftThenOneFinalAnswer() {
    var presenter = TelegramTurnPresenter(userText: "Manda ok")
    #expect(presenter.live.userText == "Manda ok")
    #expect(presenter.consume(.started) == [.draft(TelegramCopy.working)])
    #expect(presenter.live.phase == .working)
    #expect(presenter.live.assistantText == TelegramCopy.working)
    #expect(presenter.consume(.finished("ok")) == [.message("ok", markup: nil)])
    #expect(presenter.live == TelegramLiveTurn(
        userText: "Manda ok",
        assistantText: "ok",
        phase: .finished
    ))
}

@Test
func subagentLifecycleNeverBecomesAChatMessage() {
    var presenter = TelegramTurnPresenter()
    _ = presenter.consume(.started)
    #expect(
        presenter.consume(.subagent(observation(.started)))
            == [.draft("\(TelegramCopy.working) explore")]
    )
    #expect(presenter.consume(.subagent(observation(.progressed))).isEmpty)
    #expect(presenter.consume(.subagent(observation(.finished))).isEmpty)
    #expect(presenter.consume(.finished("ok")) == [.message("ok", markup: nil)])
}

@Test
func aFloodOfSubagentsStillProducesOneFinalMessage() {
    var presenter = TelegramTurnPresenter()
    var messages: [TelegramTurnOutput] = []
    messages.append(contentsOf: presenter.consume(.started))
    for label in ["explore", "general-purpose", "explore", "review"] {
        messages.append(contentsOf: presenter.consume(.subagent(observation(.started, label: label))))
        messages.append(contentsOf: presenter.consume(.subagent(observation(.progressed, label: label))))
        messages.append(contentsOf: presenter.consume(.subagent(observation(.finished, label: label))))
    }
    messages.append(contentsOf: presenter.consume(.finished("ok")))

    let chatMessages = messages.compactMap { output -> String? in
        if case let .message(text, _) = output { return text }
        return nil
    }
    #expect(chatMessages == ["ok"])
    #expect(messages.contains(.draft("\(TelegramCopy.working) review")))
    #expect(presenter.live.phase == .finished)
    #expect(presenter.live.assistantText == "ok")
}

@Test
func streamedAnswerReplacesWorkingStatusAndIgnoresLaterSubagents() {
    var presenter = TelegramTurnPresenter(userText: "Manda ok")
    _ = presenter.consume(.started)
    _ = presenter.consume(.status("Read"))
    #expect(presenter.consume(.draft("ok")) == [.draft("ok")])
    #expect(presenter.live.phase == .streaming)
    #expect(presenter.live.assistantText == "ok")
    #expect(presenter.consume(.subagent(observation(.started))).isEmpty)
    #expect(presenter.consume(.status("Bash")).isEmpty)
    #expect(presenter.consume(.finished("ok")) == [.message("ok", markup: nil)])
    #expect(presenter.live.phase == .finished)
}

@Test
func emptyAnswerBecomesDone() {
    var presenter = TelegramTurnPresenter()
    #expect(presenter.consume(.finished("   ")) == [.message("Done.", markup: nil)])
}

@Test
func permissionPromptIsAButtonMessage() {
    var presenter = TelegramTurnPresenter()
    let options = [TelegramPermissionOption(id: "allow-once", title: "Allow once")]
    #expect(
        presenter.consume(.permission(title: "Run git push?", options: options))
            == [
                .message(
                    "Run git push?",
                    markup: TelegramTurnPresenter.permissionMarkup(options)
                ),
            ]
    )
}

@Test
func liveUserPreviewPrefersTypedTextThenMedia() {
    #expect(
        TelegramTurnBuilder.liveUserPreview(text: "Manda ok", attachments: [])
            == "Manda ok"
    )
    #expect(
        TelegramTurnBuilder.liveUserPreview(
            text: "",
            attachments: [
                TelegramTurnAttachment(
                    kind: .voice,
                    fileID: "v",
                    fileName: "voice.ogg",
                    mimeType: "audio/ogg"
                ),
            ]
        ) == "Voice note"
    )
}

@Test
func duplicateWorkingDraftsAreSuppressed() {
    var presenter = TelegramTurnPresenter()
    #expect(presenter.consume(.started) == [.draft(TelegramCopy.working)])
    #expect(presenter.consume(.started).isEmpty)
    #expect(presenter.consume(.subagent(observation(.started))) == [
        .draft("\(TelegramCopy.working) explore"),
    ])
    #expect(presenter.consume(.subagent(observation(.started))).isEmpty)
}
