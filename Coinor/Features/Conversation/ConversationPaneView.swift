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
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .background(Color(nsColor: .separatorColor))
            .clipped()
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
            .overlay(alignment: .top) {
                RemoteConnectionBanner(session: session)
            }
    }
}

/// Shown only on a remote pane whose SSH channel dropped.
///
/// The remote Grok leader keeps the session alive after its client
/// disconnects, so this reports a lost view of live work rather than lost
/// work.
@MainActor
struct RemoteConnectionBanner: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let text = session.connectionState.bannerText {
            HStack(spacing: 8) {
                Text(text)
                    .font(.callout)
                if session.connectionState == .disconnected {
                    Button("Reconnect") {
                        session.reconnect()
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .accessibilityIdentifier("terminal.connection.\(session.id)")
        }
    }
}

@MainActor
struct IDEPaneView: View {
    @ObservedObject var fresh: TerminalSession
    let isVisible: Bool

    var body: some View {
        terminal(fresh, accessibilityName: "Fresh")
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

@MainActor
struct GitPaneView: View {
    @ObservedObject var lazygit: TerminalSession
    let isVisible: Bool

    var body: some View {
        terminal(lazygit, accessibilityName: "Lazygit")
            .background(Color.black)
            .accessibilityIdentifier("conversation.git.panes")
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
        .accessibilityIdentifier("terminal.git.\(session.id)")
    }
}
