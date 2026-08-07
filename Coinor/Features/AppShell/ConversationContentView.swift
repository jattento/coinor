import SwiftUI

struct ConversationContentView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Group {
            switch coordinator.status {
            case .starting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to Grok")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text("Coinor could not start")
                        .font(.headline)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Button("Retry") {
                        Task {
                            await coordinator.restart()
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let runtimeManager = coordinator.runtimeManager {
                    RuntimeHostView(manager: runtimeManager)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.terminalRegion)
    }
}
