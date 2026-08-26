import SwiftUI

/// The Activity Stack panel: a rail of conversations waiting for the user on
/// the left, and the focused conversation's real, live terminal on the right.
///
/// This replaces the normal conversation content area while presented; it
/// never opens a separate window and never duplicates a Ghostty surface. The
/// focused pane is the same `ConversationPaneView` the sidebar would show, so
/// answering it is exactly the terminal input the user already knows: text,
/// image, or audio all go straight through Grok.
@MainActor
struct ActivityStackView: View {
    @ObservedObject var model: ActivityStackModel
    @ObservedObject var runtimeManager: ConversationRuntimeManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                focusArea
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.activityStackPanel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Label("Activity Stack", systemImage: "tray.2")
                .font(.system(size: 13, weight: .semibold))

            if !model.queue.isEmpty {
                Divider().frame(height: 16)
                countBadge(
                    "\(count(.needsInput)) need input",
                    color: .orange,
                    isVisible: count(.needsInput) > 0
                )
                countBadge(
                    "\(count(.failed)) failed",
                    color: .red,
                    isVisible: count(.failed) > 0
                )
                countBadge(
                    "\(count(.finished)) finished",
                    color: .green,
                    isVisible: count(.finished) > 0
                )
            }

            Spacer()

            Button {
                model.togglePause()
            } label: {
                Label(
                    model.isPaused ? "Resume Queue" : "Pause Queue",
                    systemImage: model.isPaused
                        ? "play.fill" : "pause.fill"
                )
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(AppShellIdentifier.activityStackPauseToggle)

            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close Activity Stack")
            .accessibilityIdentifier(AppShellIdentifier.activityStackClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func count(_ reason: ActivityQueueReason) -> Int {
        model.queue.filter { $0.reason == reason }.count
    }

    private func countBadge(
        _ text: String,
        color: Color,
        isVisible: Bool
    ) -> some View {
        Group {
            if isVisible {
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("IN QUEUE · \(model.queue.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                VStack(spacing: 2) {
                    ForEach(model.queue) { item in
                        ActivityStackRailRow(
                            item: item,
                            isFocused: item.id == model.focusedID
                        ) {
                            model.selectFocus(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)

                if model.queue.isEmpty {
                    Text("Nobody is waiting on you.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }

                if !model.away.isEmpty {
                    Divider().padding(.top, 6)
                    awaySection
                }

                if model.workingCount > 0 {
                    Divider().padding(.top, 6)
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.green)
                        Text(
                            model.workingCount == 1
                                ? "1 agent working"
                                : "\(model.workingCount) agents working"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier(AppShellIdentifier.activityStackRail)
    }

    private var awaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OUT OF THE QUEUE · \(model.away.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            ForEach(model.away) { item in
                ActivityStackAwayRow(item: item) {
                    model.restore(item.id)
                }
            }
        }
        .accessibilityIdentifier(AppShellIdentifier.activityStackAwaySection)
    }

    // MARK: - Focus area

    @ViewBuilder
    private var focusArea: some View {
        if let item = model.focusedItem {
            ActivityStackFocusPane(
                model: model,
                item: item,
                runtime: runtimeManager.runtime(sessionID: item.id)
            )
            .accessibilityIdentifier(AppShellIdentifier.activityStackFocus)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Queue clear")
                .font(.system(size: 17, weight: .medium))
            Text(
                model.workingCount > 0
                    ? "Nobody needs you right now. \(model.workingCount) agent(s) are still working; the stack fills itself when one of them does."
                    : "Nobody needs you right now."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AppShellIdentifier.activityStackEmptyState)
    }
}

// MARK: - Rail row

@MainActor
private struct ActivityStackRailRow: View {
    let item: ActivityStackItem
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.reason.glyphName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.reason.tint)
                    .frame(width: 12)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.reason.label)
                            .foregroundStyle(item.reason.tint)
                        Text("·")
                        Text(item.project)
                        if let since = item.since {
                            Text("·")
                            Text(ActivityStackWaitFormatter.string(since: since))
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isFocused
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AppShellIdentifier.activityStackRow(item.id))
    }
}

// MARK: - Away row

@MainActor
private struct ActivityStackAwayRow: View {
    let item: ActivityStackAwayItem
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(reasonText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Return to queue", action: restore)
                .buttonStyle(.link)
                .font(.system(size: 10.5))
                .accessibilityIdentifier(
                    AppShellIdentifier.activityStackRestore(item.id)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var reasonText: String {
        switch item.reason {
        case .muted:
            "Muted"
        case .snoozed(let until):
            "Snoozed until \(ActivityStackWaitFormatter.time(until))"
        }
    }
}

// MARK: - Focus pane

@MainActor
private struct ActivityStackFocusPane: View {
    @ObservedObject var model: ActivityStackModel
    let item: ActivityStackItem
    let runtime: ConversationRuntime?

    var body: some View {
        VStack(spacing: 0) {
            focusHeader
            Divider()
            if let runtime {
                ConversationPaneView(
                    root: runtime.root,
                    descendants: runtime.descendants,
                    isVisible: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Resuming conversation…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            actionBar
        }
    }

    private var focusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(item.reason.label.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(item.reason.tint, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)

                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if let position = model.focusedPosition {
                    Text("\(position.index) / \(position.total)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Text(item.project)
                if let since = item.since {
                    Text("·")
                    Text("waiting \(ActivityStackWaitFormatter.string(since: since))")
                        .foregroundStyle(item.reason.tint)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                model.dismissFocused()
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

private extension ActivityQueueReason {
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
