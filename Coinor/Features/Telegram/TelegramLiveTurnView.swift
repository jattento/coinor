import SwiftUI

@MainActor
struct TelegramLiveTurnOverlay: View {
    @ObservedObject var telegram: TelegramBridge
    let sessionID: String?

    var body: some View {
        if let sessionID, let turn = telegram.liveTurn(for: sessionID) {
            TelegramLiveTurnCard(turn: turn) {
                telegram.dismissLiveTurn(sessionID)
            }
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.18), value: turn)
        }
    }
}

@MainActor
private struct TelegramLiveTurnCard: View {
    let turn: TelegramLiveTurn
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .semibold))
                Text("Telegram")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if turn.isActive {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .foregroundStyle(.secondary)

            if !turn.userText.isEmpty {
                bubble(label: "You", text: turn.userText, prominent: false)
            }
            if !turn.assistantText.isEmpty {
                bubble(label: "Conan Code", text: turn.assistantText, prominent: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.telegramLiveTurn)
    }

    private func bubble(label: String, text: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        }
    }
}
