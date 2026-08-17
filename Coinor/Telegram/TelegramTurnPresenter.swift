import Foundation

/// Snapshot of one phone turn for the Mac conversation view.
///
/// Grok still owns the durable transcript. This is Coinor presentation so
/// the Ghostty TUI does not have to paint ACP-driven turns.
struct TelegramLiveTurn: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case working
        case streaming
        case permission
        case finished
        case failed
    }

    var userText: String
    var assistantText: String
    var phase: Phase

    var isActive: Bool {
        switch phase {
        case .working, .streaming, .permission:
            return true
        case .finished, .failed:
            return false
        }
    }
}

/// What a phone turn is allowed to show. RichardAtCT's quiet/verbose-0
/// pattern: one working draft, permission buttons, one final answer.
/// Subagent lifecycle is desktop pane state, never a chat message.
struct TelegramTurnPresenter: Equatable, Sendable {
    private(set) var live: TelegramLiveTurn
    private var lastDraft: String?
    private var answerStarted = false

    init(userText: String = "") {
        live = TelegramLiveTurn(
            userText: userText,
            assistantText: "",
            phase: .working
        )
    }

    mutating func setUserText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        live.userText = trimmed
    }

    mutating func consume(_ input: TelegramTurnInput) -> [TelegramTurnOutput] {
        switch input {
        case .started:
            live.phase = .working
            return draft(TelegramCopy.working)
        case let .draft(text):
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preview.isEmpty else { return [] }
            answerStarted = true
            live.phase = .streaming
            return draft(preview)
        case let .status(title):
            guard !answerStarted else { return [] }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            live.phase = .working
            return draft("\(TelegramCopy.working) \(trimmed)")
        case let .subagent(observation):
            guard !answerStarted, observation.kind == .started else { return [] }
            live.phase = .working
            return draft("\(TelegramCopy.working) \(Self.label(observation))")
        case let .permission(title, options):
            live.phase = .permission
            live.assistantText = title
            return [.message(title, markup: Self.permissionMarkup(options))]
        case let .finished(answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.isEmpty ? "Done." : trimmed
            live.phase = .finished
            live.assistantText = text
            return [.message(text, markup: nil)]
        case let .failed(text):
            live.phase = .failed
            live.assistantText = text
            return [.message(text, markup: nil)]
        }
    }

    private mutating func draft(_ text: String) -> [TelegramTurnOutput] {
        guard text != lastDraft else { return [] }
        lastDraft = text
        live.assistantText = text
        return [.draft(text)]
    }

    static func label(_ observation: GrokSubagentLifecycleObservation) -> String {
        observation.description
            ?? observation.subagentType
            ?? "subagent"
    }

    static func permissionMarkup(
        _ options: [TelegramPermissionOption]
    ) -> TelegramReplyMarkup {
        var rows = options.enumerated().map { index, option in
            [
                TelegramInlineButton(
                    title: option.title,
                    data: TelegramCallbackData.permission(index)
                ),
            ]
        }
        rows.append([
            TelegramInlineButton(
                title: "Deny",
                data: TelegramCallbackData.permissionDeny
            ),
        ])
        return TelegramReplyMarkup(rows: rows)
    }
}

enum TelegramTurnInput: Equatable, Sendable {
    case started
    case draft(String)
    case status(String)
    case subagent(GrokSubagentLifecycleObservation)
    case permission(title: String, options: [TelegramPermissionOption])
    case finished(String)
    case failed(String)
}

enum TelegramTurnOutput: Equatable, Sendable {
    case draft(String)
    case message(String, markup: TelegramReplyMarkup?)
}
