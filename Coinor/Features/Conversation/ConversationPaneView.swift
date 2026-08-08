import SwiftUI

@MainActor
struct ConversationPaneView: View {
    @ObservedObject var root: TerminalSession
    let descendants: [TerminalSession]
    let isVisible: Bool

    init(
        root: TerminalSession,
        descendants: [TerminalSession],
        isVisible: Bool = true
    ) {
        self.root = root
        self.descendants = descendants
        self.isVisible = isVisible
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: descendants.isEmpty ? 0 : 1) {
                terminal(root)
                    .frame(
                        width: descendants.isEmpty
                            ? proxy.size.width
                            : floor(proxy.size.width / 2)
                    )

                if !descendants.isEmpty {
                    VStack(spacing: 1) {
                        ForEach(descendants) { session in
                            terminal(session)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .separatorColor))
        }
        .background(Color.black)
        .accessibilityIdentifier("conversation.panes")
    }

    private func terminal(_ session: TerminalSession) -> some View {
        TerminalSurfaceRepresentable(
            session: session,
            isVisible: isVisible
        )
            .id(session.generation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("terminal.\(session.id)")
    }
}
