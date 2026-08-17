import SwiftUI

struct TelegramSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var telegram: TelegramBridge
    @State private var tokenDraft = ""

    var body: some View {
        Form {
            Section {
                SecureField("Bot Token", text: $tokenDraft)
                HStack {
                    Button("Save Token") {
                        saveToken()
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Disconnect Telegram") {
                        disconnect()
                    }
                    .disabled(!telegram.hasToken && !telegram.isPaired)
                }
                Text("Paste the token from BotFather. Conan Code stores it in ~/.coinor/telegram.toml on this Mac (mode 600). Set allowed_username there to skip the pairing code.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if let username = telegram.allowedUsername {
                    LabeledContent("Allowed user", value: "@\(username)")
                        .textSelection(.enabled)
                }
                if let code = telegram.pairingCode, telegram.allowedUsername == nil {
                    LabeledContent("Pairing Code", value: code)
                        .textSelection(.enabled)
                }
                if telegram.allowedUsername == nil {
                    Button(telegram.pairingCode == nil ? "Create Pairing Code" : "New Pairing Code") {
                        telegram.refreshPairingCode()
                    }
                    .disabled(!telegram.hasToken)
                }
                Text(
                    telegram.isPaired
                        ? telegram.statusText
                        : telegram.allowedUsername.map { TelegramCopy.listening(for: $0) }
                            ?? "Open the bot on your phone and send /start followed by the pairing code."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 280)
        .navigationTitle("Telegram")
    }

    private func saveToken() {
        do {
            try telegram.saveToken(tokenDraft)
            tokenDraft = ""
            if telegram.pairingCode == nil {
                telegram.refreshPairingCode()
            }
        } catch {
            coordinator.presentTelegramWarning(error.localizedDescription)
        }
    }

    private func disconnect() {
        do {
            try telegram.disconnect()
            tokenDraft = ""
        } catch {
            coordinator.presentTelegramWarning(error.localizedDescription)
        }
    }
}
