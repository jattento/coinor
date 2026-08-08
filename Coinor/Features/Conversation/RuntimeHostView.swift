import SwiftUI

@MainActor
struct RuntimeHostView: View {
    @ObservedObject var manager: ConversationRuntimeManager

    var body: some View {
        ZStack {
            ForEach(manager.runtimes) { runtime in
                RuntimeContainer(
                    runtime: runtime,
                    isVisible: manager.selectedSessionID == runtime.id
                )
                .opacity(manager.selectedSessionID == runtime.id ? 1 : 0)
                .allowsHitTesting(manager.selectedSessionID == runtime.id)
                .accessibilityHidden(manager.selectedSessionID != runtime.id)
            }

            if manager.runtimes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No Conversation Selected")
                        .font(.headline)
                    Text("Choose a conversation from the sidebar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("runtime.empty")
            }
        }
    }
}

@MainActor
private struct RuntimeContainer: View {
    @ObservedObject var runtime: ConversationRuntime
    let isVisible: Bool

    var body: some View {
        ConversationTabbedView(
            runtime: runtime,
            isConversationVisible: isVisible
        )
    }
}
