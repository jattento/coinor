import SwiftUI

/// The sidebar's content while the Activity Stack is open.
///
/// This replaces `AppShellSidebar` in the same `NavigationSplitView` column
/// rather than adding a second list beside it: the Activity Stack is a mode
/// the sidebar itself switches into, exactly like the existing Agent Search
/// panel takes over the same column. Closing it restores the normal
/// Pinned/Projects list.
@MainActor
struct ActivityStackSidebarView: View {
    @ObservedObject var model: ActivityStackModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    queueSection
                    if !model.away.isEmpty {
                        awaySection
                    }
                    if !model.working.isEmpty {
                        workingSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            }
            .scrollContentBackground(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.activityStackPanel)
    }

    // MARK: - Header

    private var header: some View {
        Text("Activity Stack")
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarStyle.rowInset + SidebarStyle.rowPadding)
            .frame(height: 40)
    }

    // MARK: - Sections

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            sectionHeader("IN QUEUE · \(model.queue.count)")

            if model.queue.isEmpty {
                Text("Nobody is waiting on you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SidebarStyle.rowInset + SidebarStyle.rowPadding)
                    .padding(.vertical, 4)
            } else {
                ForEach(model.queue) { item in
                    ActivityStackSidebarRow(
                        item: item,
                        isFocused: item.id == model.focusedID
                    ) {
                        model.selectFocus(item.id)
                    }
                }
            }
        }
    }

    private var awaySection: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            sectionHeader("OUT OF THE QUEUE · \(model.away.count)")

            ForEach(model.away) { item in
                ActivityStackAwayRow(item: item) {
                    model.restore(item.id)
                }
            }
        }
        .accessibilityIdentifier(AppShellIdentifier.activityStackAwaySection)
    }

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            sectionHeader(
                model.working.count == 1
                    ? "1 AGENT WORKING"
                    : "\(model.working.count) AGENTS WORKING"
            )

            ForEach(model.working) { item in
                ActivityStackWorkingRow(item: item)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SidebarStyle.rowInset + SidebarStyle.rowPadding)
            .padding(.top, SidebarStyle.sectionTopSpacing)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Queue row

@MainActor
private struct ActivityStackSidebarRow: View {
    let item: ActivityStackItem
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: item.reason.glyphName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.reason.tint)
                    .frame(width: 13)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(SidebarStyle.conversationFont)
                        .foregroundStyle(
                            isFocused
                                ? Color(nsColor: .labelColor)
                                : Color(nsColor: .secondaryLabelColor)
                        )
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(item.reason.label)
                            .foregroundStyle(item.reason.tint)
                        Text("·")
                        Text(item.project)
                        if let since = item.since {
                            Text("·")
                            Text(ActivityStackWaitFormatter.string(since: since))
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .padding(.vertical, 5)
            .background(
                SidebarRowBackground(isSelected: isFocused, isHovered: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarStyle.rowInset)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(AppShellIdentifier.activityStackRow(item.id))
    }
}

// MARK: - Working row

@MainActor
private struct ActivityStackWorkingRow: View {
    let item: ActivityStackWorkingItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 13)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SidebarStyle.conversationFont)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.project)
                    if let since = item.since {
                        Text("·")
                        Text(ActivityStackWaitFormatter.string(since: since))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarStyle.rowPadding)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarStyle.rowInset)
    }
}

// MARK: - Away row

@MainActor
private struct ActivityStackAwayRow: View {
    let item: ActivityStackAwayItem
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SidebarStyle.conversationFont)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                Text(reasonText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Return to queue", action: restore)
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .accessibilityIdentifier(
                        AppShellIdentifier.activityStackRestore(item.id)
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarStyle.rowPadding)
        .padding(.vertical, 5)
        .padding(.horizontal, SidebarStyle.rowInset)
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
