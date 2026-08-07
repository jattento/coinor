import SwiftUI

/// Dense status band for the startup compatibility checks.
struct StartupDiagnosticsPanel: View {
    let checks: [StartupCheck]
    let isRunning: Bool
    let rerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                ForEach(checks) { row(for: $0) }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.startupDiagnostics)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Startup Diagnostics")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            ProgressView()
                .controlSize(.small)
                .opacity(isRunning ? 1 : 0)
                .frame(width: 16, height: 16)

            Button(action: rerun) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(isRunning)
            .help("Re-run startup checks")
            .accessibilityLabel("Re-run startup checks")
            .accessibilityIdentifier(AppShellIdentifier.refreshStartupChecks)
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
    }

    private func row(for check: StartupCheck) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName(for: check.status))
                .font(.system(size: 11))
                .foregroundStyle(color(for: check.status))
                .frame(width: 14)

            Text(check.kind.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(check.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(check.status.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.kind.title), \(check.status.label), \(check.detail)")
        .accessibilityIdentifier(AppShellIdentifier.startupCheckRow(check.kind))
    }

    private func symbolName(for status: StartupCheck.Status) -> String {
        switch status {
        case .pending:
            return "circle.dashed"
        case .passed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private func color(for status: StartupCheck.Status) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .passed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}
