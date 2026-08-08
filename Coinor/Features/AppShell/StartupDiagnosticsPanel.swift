import SwiftUI

enum StartupDiagnosticsPresentation: Equatable {
    case band
    case startup
}

/// Compact status evidence for the startup compatibility checks.
struct StartupDiagnosticsPanel: View {
    let checks: [StartupCheck]
    let isRunning: Bool
    let presentation: StartupDiagnosticsPresentation
    let rerun: () -> Void

    init(
        checks: [StartupCheck],
        isRunning: Bool,
        presentation: StartupDiagnosticsPresentation = .band,
        rerun: @escaping () -> Void
    ) {
        self.checks = checks
        self.isRunning = isRunning
        self.presentation = presentation
        self.rerun = rerun
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    row(for: check)

                    if check.id != checks.last?.id {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(backgroundColor)
        .clipShape(
            RoundedRectangle(
                cornerRadius: presentation == .startup ? 6 : 0
            )
        )
        .overlay {
            if presentation == .startup {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Startup Diagnostics")
                .font(.system(size: 11, weight: .semibold))

            Spacer(minLength: 12)

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

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
        .frame(height: presentation == .startup ? 34 : 30)
        .padding(.horizontal, 12)
    }

    private func row(for check: StartupCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName(for: check.status))
                .font(.system(size: 11))
                .foregroundStyle(color(for: check.status))
                .frame(width: 14)
                .padding(.top, 2)

            ViewThatFits(in: .horizontal) {
                wideRow(for: check)
                compactRow(for: check)
            }
        }
        .padding(.vertical, presentation == .startup ? 6 : 4)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.kind.title), \(check.status.label), \(check.detail)")
        .accessibilityIdentifier(AppShellIdentifier.startupCheckRow(check.kind))
    }

    private func wideRow(for check: StartupCheck) -> some View {
        HStack(spacing: 8) {
            Text(check.kind.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 138, alignment: .leading)

            Text(check.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            statusLabel(for: check.status)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func compactRow(for check: StartupCheck) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(check.kind.title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 8)

                statusLabel(for: check.status)
            }

            Text(check.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func statusLabel(for status: StartupCheck.Status) -> some View {
        Text(status.label)
            .font(.system(size: 11))
            .foregroundStyle(color(for: status))
            .lineLimit(1)
    }

    private var summary: String {
        if isRunning {
            return "Checking"
        }

        let unresolved = checks.filter {
            $0.status == .failed || $0.status == .warning
        }.count
        if unresolved > 0 {
            return "\(unresolved) \(unresolved == 1 ? "issue" : "issues")"
        }

        let pending = checks.filter { $0.status == .pending }.count
        if pending > 0 {
            return "\(pending) pending"
        }

        return "All passed"
    }

    private var backgroundColor: Color {
        switch presentation {
        case .band:
            return Color(nsColor: .windowBackgroundColor)
        case .startup:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var accessibilityIdentifier: String {
        switch presentation {
        case .band:
            return AppShellIdentifier.startupDiagnostics
        case .startup:
            return "StartupExperienceDiagnostics"
        }
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
