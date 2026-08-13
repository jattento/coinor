import SwiftUI

struct RemoteHostBadge: View {
    let alias: RemoteHostAlias
    let isUnavailable: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "desktopcomputer")
            Text(alias.rawValue)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 96)
        }
        .font(.system(size: 10, weight: .light))
        .foregroundStyle(
            isUnavailable
                ? Color(nsColor: .systemRed)
                : Color(nsColor: .secondaryLabelColor)
        )
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        }
        .overlay {
            Capsule()
                .stroke(
                    isUnavailable
                        ? Color(nsColor: .systemRed).opacity(0.6)
                        : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        }
        .accessibilityLabel(
            isUnavailable
                ? "Remote computer \(alias.rawValue), unavailable"
                : "Remote computer \(alias.rawValue)"
        )
    }
}

struct AddRemoteHostView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAlias: RemoteHostAlias?
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Remote Computer")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isAdding)
                .help("Close")
            }
            .padding(14)

            Divider()

            Group {
                if coordinator.availableRemoteHostAliases.isEmpty {
                    emptyState
                } else {
                    List(
                        coordinator.availableRemoteHostAliases,
                        id: \.rawValue,
                        selection: $selectedAlias
                    ) { alias in
                        HStack(spacing: 9) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            Text(alias.rawValue)
                        }
                        .tag(alias)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if isAdding, let selectedAlias {
                        ProgressView("Connecting to \(selectedAlias.rawValue)…")
                            .controlSize(.small)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isAdding)
                    Button("Add") {
                        addSelectedHost()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedAlias == nil || isAdding)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 500, minHeight: 380)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Remote Computers Available")
                .font(.headline)
            Text(
                "Conan Code offers unregistered Host aliases from ~/.ssh/config and stores no credentials. Add another Host entry there or manage the computers already registered."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .padding(28)
    }

    private func addSelectedHost() {
        guard let selectedAlias else { return }
        isAdding = true
        errorMessage = nil
        Task {
            let failure = await coordinator.addRemoteHost(selectedAlias)
            isAdding = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}

struct RemoteHostsManagementView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var pendingStopAlias: RemoteHostAlias?
    @State private var stoppingAliases: Set<RemoteHostAlias> = []
    @State private var errorMessage: String?
    @State private var showsAddSheet = false
    @State private var reconnectingAliases: Set<RemoteHostAlias> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Remote Computers")
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

            if coordinator.registeredRemoteHosts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No Remote Computers")
                        .font(.headline)
                    Text("Conan Code offers the hosts in your SSH configuration and stores no credentials.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Sending the user back to the menu they just used is a
                    // dead end, so the action lives here too.
                    Button("Add Remote Computer…") {
                        showsAddSheet = true
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let errorMessage {
                            Label(
                                errorMessage,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(
                            coordinator.registeredRemoteHosts,
                            id: \.rawValue
                        ) { alias in
                            hostRow(alias)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 420)
        .sheet(isPresented: $showsAddSheet) {
            AddRemoteHostView(coordinator: coordinator)
        }
        .alert(
            "Stop Remote Runtime?",
            isPresented: Binding(
                get: { pendingStopAlias != nil },
                set: { presented in
                    if !presented {
                        pendingStopAlias = nil
                    }
                }
            ),
            presenting: pendingStopAlias
        ) { alias in
            Button("Cancel", role: .cancel) {
                pendingStopAlias = nil
            }
            Button("Stop Runtime", role: .destructive) {
                stopRemoteRuntime(alias)
            }
        } message: { alias in
            Text(
                "Every agent still working on \(alias.rawValue) will stop. The remote Grok runtime and all of its active work will be terminated."
            )
        }
    }

    private func hostRow(_ alias: RemoteHostAlias) -> some View {
        let runtime = coordinator.remoteHost(alias)
        let unreachableReason = runtime?.unreachableReason
        let isConnected = runtime != nil && unreachableReason == nil
        let isStopping = stoppingAliases.contains(alias)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(alias.rawValue)
                        .font(.system(size: 14, weight: .medium))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(
                                isConnected
                                    ? Color(nsColor: .systemGreen)
                                    : Color(nsColor: .systemRed)
                            )
                            .frame(width: 7, height: 7)
                        Text(isConnected ? "Connected" : "Unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isStopping || reconnectingAliases.contains(alias) {
                    ProgressView()
                        .controlSize(.small)
                }
                if !isConnected {
                    Button("Reconnect") {
                        reconnect(alias)
                    }
                    .disabled(reconnectingAliases.contains(alias))
                }
                Button("Stop remote runtime", role: .destructive) {
                    pendingStopAlias = alias
                }
                .disabled(runtime == nil || isStopping)
                Button("Remove") {
                    errorMessage = nil
                    coordinator.removeRemoteHost(alias)
                }
                .disabled(isStopping)
            }

            if let runtime {
                LabeledContent("Grok version") {
                    Text(runtime.host.grokVersion)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12))

                if let maximumSessions = runtime.host.maximumSessions,
                   maximumSessions < 20 {
                    Label {
                        Text(
                            "MaxSessions is \(maximumSessions). One conversation opens many SSH channels, and MaxSessions on that computer limits how many can stay open. Raise it to at least 20 for reliable multi-agent work."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(
                    coordinator.unreachableRemoteHostReasons[alias]
                        ?? "Conan Code is not currently connected to this computer."
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    /// A remote computer that was asleep, restarted, or off the network comes
    /// back without being removed and added again.
    private func reconnect(_ alias: RemoteHostAlias) {
        errorMessage = nil
        reconnectingAliases.insert(alias)
        Task {
            let failure = await coordinator.reconnectRemoteHost(alias)
            reconnectingAliases.remove(alias)
            if let failure {
                errorMessage = failure
            }
        }
    }

    private func stopRemoteRuntime(_ alias: RemoteHostAlias) {
        pendingStopAlias = nil
        errorMessage = nil
        stoppingAliases.insert(alias)
        Task {
            let failure = await coordinator.stopRemoteRuntime(alias)
            stoppingAliases.remove(alias)
            if let failure {
                errorMessage = failure
            }
        }
    }
}
