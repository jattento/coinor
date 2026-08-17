import Foundation

/// What a phone turn is allowed to show. RichardAtCT's quiet/verbose-0
/// pattern: one working draft, permission buttons, one final answer.
/// Tool names and subagent lifecycle stay off Telegram.
struct TelegramTurnPresenter: Equatable, Sendable {
    private var lastDraft: String?
    private var answerStarted = false

    mutating func consume(_ input: TelegramTurnInput) -> [TelegramTurnOutput] {
        switch input {
        case .started:
            return draft(TelegramCopy.working)
        case let .draft(text):
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preview.isEmpty else { return [] }
            answerStarted = true
            return draft(preview)
        case .status, .subagent:
            return []
        case let .permission(title, options):
            return [.message(title, markup: Self.permissionMarkup(options))]
        case let .finished(answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.message(trimmed.isEmpty ? "Done." : trimmed, markup: nil)]
        case let .failed(text):
            return [.message(text, markup: nil)]
        }
    }

    private mutating func draft(_ text: String) -> [TelegramTurnOutput] {
        guard text != lastDraft else { return [] }
        lastDraft = text
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
