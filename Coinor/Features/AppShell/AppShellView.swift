import SwiftUI

enum AppShellDestination: Equatable {
    case conversation
    case automations
}

struct AppShellView: View {
    @ObservedObject var model: AppShellModel
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var activityStack: ActivityStackModel
    @Environment(\.openURL) private var openURL
    @State private var destination: AppShellDestination = .conversation
    @State private var showsSettings = false
    @AppStorage("appShell.sidebarWidth") private var sidebarWidth: Double = 278
    @AppStorage("appShell.sidebarVisible") private var isSidebarVisible = true
    @StateObject private var automationCenter: AutomationCenterModel

    init(
        model: AppShellModel,
        coordinator: AppCoordinator,
        activityStack: ActivityStackModel
    ) {
        self.model = model
        self.coordinator = coordinator
        self.activityStack = activityStack
        _automationCenter = StateObject(
            wrappedValue: AutomationCenterModel(coordinator: coordinator)
        )
    }

    var body: some View {
        // An explicit split, not `NavigationSplitView`.
        //
        // Measured on a live window in the broken state, with the
        // accessibility API: the split placed its detail hosting view at the
        // window's own origin with the window's full width (x=-3407 w=1688)
        // while the sidebar occupied x=-3399 w=264, and the detail's content
        // then measured 1954 — the window width plus the sidebar width. The
        // detail pane was therefore sitting *under* the sidebar and running
        // past the right window edge, which is exactly what every report
        // showed. Neither pinned `columnVisibility` nor
        // `.navigationSplitViewStyle(.balanced)` prevented it.
        //
        // Laying the two columns out here makes the geometry explicit: the
        // sidebar gets exactly `sidebarWidth`, the detail gets the rest, and
        // neither can be placed on top of the other.
        HStack(spacing: 0) {
            if isSidebarVisible {
                AppShellSidebarHost(
                    coordinator: coordinator,
                    destination: $destination,
                    activityStack: activityStack
                )
                .frame(width: CGFloat(sidebarWidth))
                .clipped()

                SidebarResizeDivider(
                    width: $sidebarWidth,
                    range: Self.sidebarWidthRange
                )
            }

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(minWidth: 840, minHeight: 520)
        .modifier(
            AppShellChrome(
                model: model,
                coordinator: coordinator,
                activityStack: activityStack,
                automationCenter: automationCenter,
                isSidebarVisible: $isSidebarVisible,
                showsSettings: $showsSettings,
                openURL: openURL
            )
        )
    }

    private static let sidebarWidthRange: ClosedRange<Double> = 230...400

    @ViewBuilder
    private var detailContent: some View {
        Group {
            switch destination {
            case .conversation:
                VStack(spacing: 0) {
                    // `ConversationContentView` (and the `RuntimeHostView`
                    // inside it) stays mounted here at all times, whether or
                    // not the Activity Stack is open: it owns every loaded
                    // conversation's real Ghostty surfaces and subprocesses,
                    // and tearing that whole tree down just to swap in a
                    // second copy for the panel — then back again on close —
                    // used to relaunch all of them on every single toggle.
                    // The Activity Stack only ever adds chrome on top.
                    ZStack {
                        ConversationContentView(
                            model: model,
                            coordinator: coordinator
                        )
                        if activityStack.isPresented,
                           case .ready = coordinator.status,
                           activityStack.focusedDisplay == nil {
                            ActivityStackEmptyOverlay(model: activityStack)
                        }
                    }
                    if activityStack.isPresented,
                       case .ready = coordinator.status,
                       let display = activityStack.focusedDisplay {
                        Divider()
                        ActivityStackActionBar(
                            model: activityStack,
                            display: display
                        )
                    }
                    if case .ready = coordinator.status,
                       model.unresolvedStartupCheckCount > 0 {
                        Divider()
                        StartupDiagnosticsPanel(
                            checks: model.startupChecks,
                            isRunning: model.isRunningStartupChecks,
                            rerun: { Task { await model.runStartupChecks() } }
                        )
                    }
                }
            case .automations:
                AutomationsView(model: automationCenter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The draggable boundary between the sidebar and the detail pane.
///
/// Replaces `NavigationSplitView`'s own splitter now that the shell lays its
/// two columns out directly.
private struct SidebarResizeDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var widthAtDragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                widthAtDragStart = start
                                width = min(
                                    max(
                                        start + value.translation.width,
                                        range.lowerBound
                                    ),
                                    range.upperBound
                                )
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// Window-level chrome for the shell: startup tasks, toolbar, sheets,
/// the warning banner, and the shortcut monitor. Split out so the shell's
/// own layout stays a plain two-column `HStack`.
@MainActor
private struct AppShellChrome: ViewModifier {
    @ObservedObject var model: AppShellModel
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var activityStack: ActivityStackModel
    @ObservedObject var automationCenter: AutomationCenterModel
    @Binding var isSidebarVisible: Bool
    @Binding var showsSettings: Bool
    let openURL: OpenURLAction

    func body(content: Content) -> some View {
        content
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    isSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(
                    isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
                )
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        .task {
            async let diagnostics: Void = model.runStartupChecks()
            await coordinator.start()
            _ = await diagnostics
            await model.runStartupChecks()
        }
        .task {
            await model.monitorGrokUpdates()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let status = model.missingUpstreamGrokCommits {
                    Button {
                        openURL(status.url)
                    } label: {
                        Image(systemName: "arrow.trianglehead.branch")
                            .foregroundStyle(.orange)
                    }
                    .help(
                        "Grok is missing \(status.missingCommitCount) commit(s) from upstream xai-org/grok-build"
                    )
                    .accessibilityLabel(
                        "Grok missing \(status.missingCommitCount) upstream commit(s)"
                    )
                    .accessibilityIdentifier(
                        AppShellIdentifier.grokUpstreamSyncButton
                    )
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let release = model.availableGrokRelease {
                    Button {
                        openURL(release.url)
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .help("Grok \(release.tagName) is available")
                    .accessibilityLabel(
                        "Grok update available: \(release.tagName)"
                    )
                    .accessibilityIdentifier(
                        AppShellIdentifier.grokUpdateButton
                    )
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activityStack.togglePresented()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "tray.2")
                        if activityStack.queue.count > 0 {
                            Text("\(activityStack.queue.count)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(3)
                                .background(
                                    Circle().fill(activityStackBadgeColor)
                                )
                                .foregroundStyle(.white)
                                .offset(x: 9, y: -8)
                        }
                    }
                }
                .help("Activity Stack")
                .accessibilityLabel(
                    activityStack.queue.isEmpty
                        ? "Activity Stack"
                        : "Activity Stack, \(activityStack.queue.count) waiting"
                )
                .accessibilityIdentifier(AppShellIdentifier.activityStackButton)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier(AppShellIdentifier.settingsButton)
            }
        }
        .sheet(isPresented: $showsSettings) {
            if let runtime = coordinator.runtimeManager?.ghosttyRuntime {
                SettingsWindowHost(
                    runtime: runtime,
                    changelogLoader: model.changelogLoader
                )
            } else {
                SettingsUnavailableView()
            }
        }
        .sheet(isPresented: $coordinator.showsArchivedItems) {
            ArchivedItemsView(coordinator: coordinator)
        }
        .overlay(alignment: .top) {
            if let warning = coordinator.warningMessage {
                WarningBanner(message: warning) {
                    coordinator.dismissWarning()
                }
                .padding(.top, 8)
            }
        }
        .background {
            TerminalTabShortcutMonitor(
                coordinator: coordinator,
                activityStack: activityStack
            )
                .frame(width: 0, height: 0)
        }
        .onReceive(coordinator.objectWillChange) {
            // `objectWillChange` fires before the new value is committed, so
            // recomputing has to wait for the next turn of the run loop or it
            // would read the state `coordinator` is about to replace.
            DispatchQueue.main.async {
                activityStack.recompute()
            }
        }
    }

    private var activityStackBadgeColor: Color {
        if activityStack.queue.contains(where: { $0.reason == .failed }) {
            return .red
        }
        if activityStack.queue.contains(where: { $0.reason == .needsInput }) {
            return .orange
        }
        return .green
    }
}

/// Keeps one stable view in `NavigationSplitView`'s sidebar column.
///
/// The normal conversation list and the Activity Stack queue are both always
/// mounted; only opacity and hit testing change. That keeps the column's
/// identity — and therefore the split's own column geometry — fixed while
/// the Activity Stack opens and closes.
@MainActor
private struct AppShellSidebarHost: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var destination: AppShellDestination
    @ObservedObject var activityStack: ActivityStackModel

    var body: some View {
        ZStack {
            AppShellSidebar(
                coordinator: coordinator,
                destination: $destination
            )
            .opacity(activityStack.isPresented ? 0 : 1)
            .allowsHitTesting(!activityStack.isPresented)
            .accessibilityHidden(activityStack.isPresented)

            ActivityStackSidebarView(model: activityStack)
                .opacity(activityStack.isPresented ? 1 : 0)
                .allowsHitTesting(activityStack.isPresented)
                .accessibilityHidden(!activityStack.isPresented)
        }
    }
}

/// Shown when the gear is opened before the Ghostty runtime exists, so the
/// settings surface still appears instead of a blank sheet.
private struct SettingsUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Settings are unavailable until Conan Code finishes starting.")
            Button("Close") {
                dismiss()
            }
            .accessibilityIdentifier(AppShellIdentifier.settingsClose)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 160)
        .accessibilityIdentifier(AppShellIdentifier.settingsPanel)
    }
}

private struct WarningBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(.regularMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor))
        }
        .padding(.horizontal, 12)
    }
}

private struct ArchivedItemsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Archived Items")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                if !coordinator.archivedConversations.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        archivedSectionTitle("Conversations")
                        ForEach(coordinator.archivedConversations) { conversation in
                            HStack {
                                Text(conversation.title)
                                Spacer()
                                Button("Unarchive") {
                                    coordinator.unarchiveConversation(
                                        conversation.id
                                    )
                                }
                                .accessibilityLabel(
                                    "Unarchive \(conversation.title)"
                                )
                                .accessibilityIdentifier(
                                    "ArchivedConversation.\(conversation.id).Unarchive"
                                )
                            }
                        }
                    }
                }

                if !coordinator.archivedProjectIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        archivedSectionTitle("Projects")
                        ForEach(coordinator.archivedProjectIDs, id: \.self) { projectID in
                            let name = coordinator.projectDisplayName(projectID)
                            HStack {
                                Text(name)
                                Spacer()
                                Button("Unarchive") {
                                    coordinator.unarchiveProject(projectID)
                                }
                                .accessibilityLabel("Unarchive \(name)")
                                .accessibilityIdentifier(
                                    "ArchivedProject.\(projectID).Unarchive"
                                )
                            }
                        }
                    }
                }

                if coordinator.archivedConversations.isEmpty,
                   coordinator.archivedProjectIDs.isEmpty {
                    Text("No archived items")
                        .foregroundStyle(.secondary)
                }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func archivedSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
