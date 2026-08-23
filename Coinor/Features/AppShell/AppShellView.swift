import SwiftUI

enum AppShellDestination: Equatable {
    case conversation
    case automations
}

struct AppShellView: View {
    @ObservedObject var model: AppShellModel
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openURL) private var openURL
    @State private var destination: AppShellDestination = .conversation
    @State private var showsSettings = false
    @StateObject private var automationCenter: AutomationCenterModel

    init(model: AppShellModel, coordinator: AppCoordinator) {
        self.model = model
        self.coordinator = coordinator
        _automationCenter = StateObject(
            wrappedValue: AutomationCenterModel(coordinator: coordinator)
        )
    }

    var body: some View {
        NavigationSplitView {
            AppShellSidebar(
                coordinator: coordinator,
                destination: $destination
            )
            .navigationSplitViewColumnWidth(min: 230, ideal: 278, max: 400)
        } detail: {
            switch destination {
            case .conversation:
                VStack(spacing: 0) {
                    ConversationContentView(
                        model: model,
                        coordinator: coordinator
                    )
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
                .frame(minWidth: 560, minHeight: 380)
            case .automations:
                AutomationsView(model: automationCenter)
                    .frame(minWidth: 560, minHeight: 380)
            }
        }
        .frame(minWidth: 840, minHeight: 520)
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
            TerminalTabShortcutMonitor(coordinator: coordinator)
                .frame(width: 0, height: 0)
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
