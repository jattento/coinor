import SwiftUI

@MainActor
struct RuntimeHostView: View {
    @ObservedObject var manager: ConversationRuntimeManager

    var body: some View {
        // Every loaded conversation stays mounted in this ZStack. A ZStack
        // takes the size of its largest child and centers all of them, so a
        // single child that asks for more room than the pane has makes the
        // whole stack — tab strip included — overflow the detail column
        // symmetrically: clipped on the left under the sidebar, running past
        // the right window edge. Each child is pinned to the available space
        // so no conversation can size the stack, and the stack is clipped as
        // a backstop. This is why the misalignment showed up after opening
        // several chats: more children, more chances one of them inflates it.
        ZStack {
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
