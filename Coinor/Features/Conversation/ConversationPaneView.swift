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

@MainActor
struct IDEPaneView: View {
    @ObservedObject var fresh: TerminalSession
    @ObservedObject var lazygit: TerminalSession
    let isVisible: Bool

    private let freshFraction: CGFloat = 0.60
    private let separatorWidth: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(
                proxy.size.width - separatorWidth,
                0
            )
            HStack(spacing: separatorWidth) {
                terminal(
                    fresh,
                    accessibilityName: "Fresh"
                )
                .frame(width: floor(availableWidth * freshFraction))

                terminal(
                    lazygit,
                    accessibilityName: "Lazygit"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .separatorColor))
        }
        .background(Color.black)
        .accessibilityIdentifier("conversation.ide.panes")
    }

    private func terminal(
        _ session: TerminalSession,
        accessibilityName: String
    ) -> some View {
        TerminalSurfaceRepresentable(
            session: session,
            isVisible: isVisible
        )
        .id(
            "\(session.id):\(session.generation):"
                + session.launch.workingDirectory
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(accessibilityName)
        .accessibilityIdentifier("terminal.ide.\(session.id)")
    }
}
