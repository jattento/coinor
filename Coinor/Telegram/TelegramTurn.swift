import Foundation

struct TelegramTurnAttachment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case photo
        case document
        case voice
    }

    var kind: Kind
    var fileID: String
    var fileName: String?
    var mimeType: String?
}

struct TelegramResolvedAttachment: Equatable, Sendable {
    var kind: TelegramTurnAttachment.Kind
    var fileName: String?
    var mimeType: String
    var data: Data
    var transcript: String?
}

/// Assembles the ACP `session/prompt` content the poller sends. Tests drive
/// this function with the same attachments the live bridge resolves.
enum TelegramTurnBuilder {
    static func blocks(
        text: String,
        attachments: [TelegramResolvedAttachment]
    ) -> [GrokJSONValue] {
        var media: [GrokJSONValue] = []
        var lines: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(trimmed)
        }

        for attachment in attachments {
            switch attachment.kind {
            case .photo:
                media.append(imageBlock(attachment))
            case .voice:
                if let transcript = attachment.transcript?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !transcript.isEmpty {
                    lines.append("Voice note transcript:\n\(transcript)")
                } else {
                    lines.append("Voice note attached.")
                }
                media.append(audioBlock(attachment))
            case .document:
                appendDocument(
                    attachment,
                    lines: &lines,
                    media: &media
                )
            }
        }

        var blocks: [GrokJSONValue] = []
        if !lines.isEmpty {
            blocks.append([
                "type": "text",
                "text": .string(lines.joined(separator: "\n\n")),
            ])
        }
        blocks.append(contentsOf: media)
        if blocks.isEmpty {
            blocks.append(["type": "text", "text": " "])
        }
        return blocks
    }

    private static func imageBlock(
        _ attachment: TelegramResolvedAttachment
    ) -> GrokJSONValue {
        [
            "type": "image",
            "mimeType": .string(attachment.mimeType),
            "data": .string(attachment.data.base64EncodedString()),
        ]
    }

    private static func audioBlock(
        _ attachment: TelegramResolvedAttachment
    ) -> GrokJSONValue {
        [
            "type": "audio",
            "mimeType": .string(attachment.mimeType),
            "data": .string(attachment.data.base64EncodedString()),
        ]
    }

    private static func appendDocument(
        _ attachment: TelegramResolvedAttachment,
        lines: inout [String],
        media: inout [GrokJSONValue]
    ) {
        let name = attachment.fileName ?? "file"
        if attachment.mimeType.hasPrefix("image/") {
            media.append(imageBlock(attachment))
            return
        }
        if attachment.mimeType.hasPrefix("text/"),
           let body = String(data: attachment.data, encoding: .utf8),
           !body.isEmpty {
            lines.append("File \(name):\n\(body)")
            return
        }
        lines.append("Attached file: \(name)")
        media.append([
            "type": "resource",
            "resource": [
                "uri": .string("telegram://\(name)"),
                "mimeType": .string(attachment.mimeType),
                "blob": .string(attachment.data.base64EncodedString()),
            ],
        ])
    }
}
