import SwiftUI

@MainActor
struct RuntimeHostView: View {
    @ObservedObject var manager: ConversationRuntimeManager

    var body: some View {
        // Every loaded conversation stays mounted here, so a single child
        // that asks for more room than the pane has must not be able to size
        // the stack: that measurement would travel up to the detail column
        // and overflow the window, clipping the left of the pane under the
        // sidebar and running the right past the window edge. `PinnedStack`
        // reports exactly the offered space no matter what its children
        // return — `.frame(maxWidth: .infinity)` does not.
        PinnedStack {
            ForEach(manager.runtimes) { runtime in
                RuntimeContainer(
                    runtime: runtime,
                    isVisible: manager.selectedSessionID == runtime.id
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
