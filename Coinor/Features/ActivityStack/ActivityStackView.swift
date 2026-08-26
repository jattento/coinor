import SwiftUI

/// The Activity Stack's chrome around the conversation content area: an
/// overlay that stands in for the terminal while nothing is focused, and an
/// action bar shown under it once something is.
///
/// Neither piece renders `RuntimeHostView` itself. `ConversationContentView`
/// (and its `RuntimeHostView`) stays mounted at all times, in the same
/// position in the view tree, regardless of whether the Activity Stack is
/// open — see `AppShellView`. `RuntimeHostView`'s `ZStack` holds every loaded
/// runtime's tabs, each backed by a real `ghostty_surface_t` and subprocess;
/// if the Activity Stack instead swapped in its own separate copy of
/// `RuntimeHostView` when opened, SwiftUI would treat that as a totally
/// different view identity and tear down and relaunch every one of those
/// surfaces and subprocesses on every single open/close, which is exactly
/// what made heavy toggling between the two views freeze the app. Focusing a
/// conversation from the Activity Stack still goes through the same
/// `AppCoordinator.selectConversation` the sidebar uses (via
/// `ActivityStackModel.selectFocus`), so the terminal underneath already
/// shows the right conversation on its own; this file only adds chrome on
/// top of it.
@MainActor
struct ActivityStackEmptyOverlay: View {
    @ObservedObject var model: ActivityStackModel

    var body: some View {
        VStack(spacing: 14) {
            ConanASCIIView()
            Text("Waiting for the next agent…")
                .font(.system(size: 15, weight: .medium))
            Text(
                model.working.isEmpty
                    ? "Nobody needs you right now. This screen updates on its own."
                    : "Nobody needs you right now. \(model.workingCount) agent(s) are still working; this screen fills itself when one of them does."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier(AppShellIdentifier.activityStackEmptyState)
    }
}

// MARK: - Action bar

@MainActor
struct ActivityStackActionBar: View {
    @ObservedObject var model: ActivityStackModel
    let display: ActivityStackFocusDisplay

    var body: some View {
        Group {
            if display.reason != nil {
                queuedActionBar
            } else {
                watchingActionBar
            }
        }
        .accessibilityIdentifier(AppShellIdentifier.activityStackFocus)
    }

    private var queuedActionBar: some View {
        HStack(spacing: 8) {
            Button {
                model.dismissOrCloseFocused()
            } label: {
                actionLabel("⌘D", "Done, remove")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)
            .accessibilityIdentifier(AppShellIdentifier.activityStackDismiss)

            Button {
                model.pushFocusedToEnd()
            } label: {
                actionLabel("⌘S", "Send to end")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityIdentifier(AppShellIdentifier.activityStackPushToEnd)

            Menu {
                Button("15 minutes") { model.snoozeFocused(minutes: 15) }
                Button("1 hour") { model.snoozeFocused(minutes: 60) }
            } label: {
                actionLabel(nil, "Snooze")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.muteFocused()
            } label: {
                actionLabel("⌘M", "Mute")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("m", modifiers: .command)
            .accessibilityIdentifier(AppShellIdentifier.activityStackMute)

            Spacer()

            Text("Answering in the terminal advances the queue on its own.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Shown once the focused conversation is no longer blocking and nothing
    /// else is waiting: it stays in view instead of snapping to the empty
    /// state, but push/snooze/mute do not apply to something that is not
    /// actually queued anymore.
    private var watchingActionBar: some View {
        HStack(spacing: 8) {
            Button {
                model.dismissOrCloseFocused()
            } label: {
                actionLabel("⌘D", "Close")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)
            .accessibilityIdentifier(AppShellIdentifier.activityStackDismiss)

            Spacer()

            Text("It will come back here on its own if it needs you again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func actionLabel(_ key: String?, _ title: String) -> some View {
        HStack(spacing: 6) {
            if let key {
                Text(key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            Text(title)
                .font(.system(size: 11.5))
        }
    }
}

// MARK: - Presentation helpers

extension ActivityQueueReason {
    var tint: Color {
        switch self {
        case .needsInput: .orange
        case .failed: .red
        case .finished: .green
        }
    }

    var glyphName: String {
        switch self {
        case .needsInput: "questionmark"
        case .failed: "xmark"
        case .finished: "checkmark"
        }
    }
}

enum ActivityStackWaitFormatter {
    static func string(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours)h"
            : "\(hours)h \(remainingMinutes)m"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
