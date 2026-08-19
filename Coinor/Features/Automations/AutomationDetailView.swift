import SwiftUI

/// The detail for one automation: what it does, when it runs next, and every
/// execution so far.
///
/// Executions are listed newest first, because the run a user cares about is
/// almost always the one that just happened.
struct AutomationDetailView: View {
    @ObservedObject var model: AutomationCenterModel
    let automation: Automation
    let edit: () -> Void

    /// Reading measure for the detail. Without it an execution row stretches
    /// the full window and its "Open Conversation" link ends up a long way
    /// from the date it belongs to.
    private static let contentWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                summaryGrid
                promptSection
                Divider()
                runsSection
            }
            .padding(16)
            .frame(maxWidth: Self.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(automation.name)
                        .font(.title3.weight(.semibold))
                    if automation.isPaused {
                        Text("Paused")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.2))
                            )
                            .foregroundStyle(.orange)
                    }
                }
                Text(recurrence.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if model.isRunning(automation.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    model.runNow(automation.id)
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(automation.workingDirectory.isEmpty)
            }
            Button(automation.isPaused ? "Resume" : "Pause") {
                model.setPaused(automation.id, paused: !automation.isPaused)
            }
            Button("Edit", action: edit)
            Menu {
                Button("Delete Automation", role: .destructive) {
                    model.deleteAutomation(automation.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Summary

    private var summaryGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailRow("Next run", nextRunText)
            detailRow("Project", model.projectName(for: automation))
            detailRow("Model", automation.model ?? "Grok default")
            detailRow(
                "Effort",
                automation.reasoningEffort?.title ?? "Model default"
            )
            detailRow("Schedule", automation.schedule, monospaced: true)
        }
    }

    private func detailRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .callout)
                .textSelection(.enabled)
        }
    }

    private var recurrence: AutomationRecurrence {
        .parse(automation.schedule)
    }

    private var nextRunText: String {
        guard !automation.isPaused else {
            return "Paused — will not run"
        }
        guard let schedule = try? CronSchedule.parse(automation.schedule),
              let next = schedule.nextFire(after: Date()) else {
            return "Unknown"
        }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(automation.prompt)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
        }
    }

    // MARK: - Runs

    private var runs: [AutomationRun] {
        model.runs(for: automation.id)
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Executions")
                    .font(.callout.weight(.medium))
                Spacer()
                if !runs.isEmpty {
                    Text("\(runs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if runs.isEmpty {
                Text("No executions yet. Use Run Now to start one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    // Newest first: the run that just happened is the one the
                    // user is looking for.
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { Divider() }
                        runRow(run)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
            }
        }
    }

    private func runRow(_ run: AutomationRun) -> some View {
        HStack(spacing: 10) {
            statusIcon(run)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(startedText(run))
                    .font(.callout)
                HStack(spacing: 6) {
                    Text(run.trigger == .forced ? "Manual" : "Scheduled")
                    if let duration = durationText(run) {
                        Text("·")
                        Text(duration)
                    }
                    if let error = run.errorMessage {
                        Text("·")
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let sessionID = run.sessionID {
                Button("Open Conversation") {
                    model.openConversation(sessionID)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusIcon(_ run: AutomationRun) -> some View {
        switch run.status {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func startedText(_ run: AutomationRun) -> String {
        guard let started = run.startedAt else { return "Unknown time" }
        return started.formatted(date: .abbreviated, time: .standard)
    }

    private func durationText(_ run: AutomationRun) -> String? {
        guard let started = run.startedAt else { return nil }
        guard let finished = run.finishedAt else { return "in progress" }
        let seconds = Int(finished.timeIntervalSince(started).rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
