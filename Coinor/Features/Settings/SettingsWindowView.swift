import SwiftUI

/// View state for the changelog tab: the loaded releases, or the reason it
/// failed to load.
@MainActor
final class ChangelogModel: ObservableObject {
    @Published private(set) var entries: [GrokReleaseEntry] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var errorMessage: String?

    private let loader: any GrokChangelogLoading

    init(loader: any GrokChangelogLoading) {
        self.loader = loader
    }

    /// Loads the changelog from the cooked bundle resource. The data is read
    /// once and kept; reloading is a no-op.
    func load() async {
        guard !isLoaded else { return }
        do {
            entries = try await loader.load()
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Owns one `fresh` terminal session per settings tab.
///
/// Sessions are created lazily on first selection and reused while the window
/// stays open, so switching back and forth does not restart the editor for a
/// file that is already open. The changelog tab has no terminal session; it
/// owns a ``ChangelogModel`` instead.
@MainActor
final class SettingsEditorModel: ObservableObject {
    let tabs: [SettingsFileTab]
    @Published var selectedTabID: String

    private let runtime: GhosttyRuntime
    private var sessions: [String: TerminalSession] = [:]

    init(
        runtime: GhosttyRuntime,
        tabs: [SettingsFileTab] = SettingsFileCatalog.tabs(),
        changelogLoader: any GrokChangelogLoading = BundledGrokChangelogLoader()
    ) {
        self.runtime = runtime
        self.tabs = tabs
        self.selectedTabID = tabs.first(
            where: { $0.id == SettingsFileCatalog.defaultTabID }
        )?.id ?? tabs.first?.id ?? SettingsFileCatalog.defaultTabID
        self.changelogModel = ChangelogModel(loader: changelogLoader)
    }

    var selectedTab: SettingsFileTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The changelog tab's view model, created once per settings presentation.
    /// Owned here so switching away from the tab does not lose loaded state.
    let changelogModel: ChangelogModel

    func session(for tab: SettingsFileTab) -> TerminalSession {
        if let existing = sessions[tab.id] {
            return existing
        }
        guard let launch = tab.launch else {
            fatalError("A terminal session was requested for a non-terminal tab")
        }
        let session = TerminalSession(
            launch: launch,
            runtime: runtime,
            keepsSurfaceAfterProcessExit: true
        )
        sessions[tab.id] = session
        return session
    }

    func shutdown() {
        for session in sessions.values {
            session.shutdown()
        }
        sessions.removeAll()
    }
}

/// Creates the editor model once per presentation of the settings surface.
@MainActor
struct SettingsWindowHost: View {
    @StateObject private var model: SettingsEditorModel

    init(
        runtime: GhosttyRuntime,
        changelogLoader: any GrokChangelogLoading =
            BundledGrokChangelogLoader()
    ) {
        _model = StateObject(
            wrappedValue: SettingsEditorModel(
                runtime: runtime,
                changelogLoader: changelogLoader
            )
        )
    }

    var body: some View {
        SettingsWindowView(model: model)
    }
}

@MainActor
struct SettingsWindowView: View {
    @ObservedObject var model: SettingsEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            editor
        }
        .frame(minWidth: 900, minHeight: 620)
        // Without `.contain` the panel identifier would replace every child
        // identifier, including the per-tab terminal ones.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.settingsPanel)
        .onDisappear {
            model.shutdown()
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close Settings")
            .accessibilityIdentifier(AppShellIdentifier.settingsClose)
        }
        .padding(14)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    Button {
                        model.selectedTabID = tab.id
                    } label: {
                        Text(tab.label)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                tab.id == model.selectedTabID
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.clear
                            )
                    )
                    .help(tab.path ?? tab.label)
                    .accessibilityLabel(tab.label)
                    .accessibilityIdentifier(tab.accessibilityIdentifier)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let tab = model.selectedTab {
            if tab.isChangelog {
                ChangelogView(model: model.changelogModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        AppShellIdentifier.settingsChangelog
                    )
            } else {
                VStack(spacing: 0) {
                    TerminalSurfaceRepresentable(
                        session: model.session(for: tab)
                    )
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Text(tab.path ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                .background(Color.black)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(tab.terminalAccessibilityIdentifier)
            }
        } else {
            Text("No configuration files available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
