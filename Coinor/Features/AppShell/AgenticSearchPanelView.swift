import SwiftUI

/// The agent-search results panel, moved out of `AppShellSidebar`.
///
/// The sidebar's `AgenticSearchPanelState` is a value type wrapping a
/// reference-type finder model, so a sidebar-level `@State` never re-rendered
/// when the model changed. This view holds the model with `@ObservedObject`,
/// so every published state change re-renders the panel; the presentation
/// state (presented/dismissed) still lives in the sidebar's `@State` because
/// it only changes through user actions the sidebar already animates.
struct AgenticSearchPanelView: View {
    @ObservedObject var model: AgenticConversationFinderModel
    let coordinator: AppCoordinator
    let submit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchHeader

            stateContent
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16))
        }
        .padding(.horizontal, SidebarStyle.rowInset)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onExitCommand {
            dismiss()
        }
        .accessibilityIdentifier(AppShellIdentifier.agenticSearchPanel)
    }

    private var searchHeader: some View {
        HStack {
            Text("Agent Search")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if case .searching = model.state {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Find") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                model.query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty || model.state == .searching
            )
            closeButton
        }
    }

    /// The panel's own way out. The sparkle toggle also closes it, but a user
    /// who opened this from the toggle looks for the dismissal inside the thing
    /// that appeared, not back at the control that summoned it.
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Close Agent Search")
        .accessibilityLabel("Close Agent Search")
        .accessibilityIdentifier(AppShellIdentifier.agenticSearchClose)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle:
            Text("Try: “Find yesterday's remote-host conversation and open it.”")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .searching:
            Text("Reading conversation summaries…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemRed))
        case .results(let response):
            Text(response.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if response.matches.isEmpty {
                Text("No matching conversations")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(response.matches) { match in
                    matchRow(match)
                }
            }
        }
    }

    private func matchRow(_ match: AgenticFinderMatch) -> some View {
        let summary = coordinator.agenticConversationSummary(match.sessionID)
        let title = summary?.title ?? "Conversation"
        let openingAccessibilityLabel = summary?.archived == true
            ? "Open \(title). Opening restores it from Archive. \(match.reason)"
            : "Open \(title). \(match.reason)"
        return HStack(spacing: 8) {
            Button {
                coordinator.applyAgenticFinderMatch(match.openingAction)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .lineLimit(1)
                        if summary?.archived == true {
                            Text("Archived")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.tertiary)
                    }
                    Text(match.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openingAccessibilityLabel)

            if !coordinator.isAgenticConversationPinned(match.sessionID) {
                Button("Pin") {
                    coordinator.applyAgenticFinderMatch(match.pinningAction)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Pin \(title)")
                .accessibilityHint(
                    "Pins the conversation without opening it"
                )
            }
        }
    }
}

/// The fallback panel shown when Grok could not supply a finder, explaining
/// why instead of showing an empty query box.
struct AgenticSearchUnavailablePanelView: View {
    let unavailableMessage: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Search Unavailable")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                closeButton
            }
            Text(unavailableMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16))
        }
        .padding(.horizontal, SidebarStyle.rowInset)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onExitCommand {
            dismiss()
        }
        .accessibilityIdentifier(AppShellIdentifier.agenticSearchPanel)
    }

    /// The panel's own way out. The sparkle toggle also closes it, but a user
    /// who opened this from the toggle looks for the dismissal inside the thing
    /// that appeared, not back at the control that summoned it.
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Close Agent Search")
        .accessibilityLabel("Close Agent Search")
        .accessibilityIdentifier(AppShellIdentifier.agenticSearchClose)
    }
}