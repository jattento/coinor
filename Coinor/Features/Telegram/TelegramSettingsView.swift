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
                Text("Paste the token from BotFather. Conan Code stores it in the Keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if let code = telegram.pairingCode {
                    LabeledContent("Pairing Code", value: code)
                        .textSelection(.enabled)
                }
                Button(telegram.pairingCode == nil ? "Create Pairing Code" : "New Pairing Code") {
                    telegram.refreshPairingCode()
                }
                .disabled(!telegram.hasToken)
                Text(
                    telegram.isPaired
                        ? telegram.statusText
                        : "Open the bot on your phone and send /start followed by the pairing code."
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
