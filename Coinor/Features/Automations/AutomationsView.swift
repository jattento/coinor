import SwiftUI

/// The Automations destination: a sidebar tab showing every configured cron
/// automation, with entry points to edit an automation, run one now, edit the
/// shared system prompt, and open an automation's detail (schedule, prompt,
/// runs, next fire).
struct AutomationsView: View {
    @ObservedObject var model: AutomationCenterModel

    @State private var editingAutomationID: String?
    @State private var editingSystemPrompt = false
    @State private var selectedAutomationID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.refresh()
            // Runs happen in another process, so the log is polled while this
            // tab is on screen and left alone when it is not.
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
        .overlay(alignment: .top) {
            if let message = model.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12))
                        .lineLimit(3)
                    Button {
                        model.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .padding(8)
            }
        }
        .sheet(
            item: Binding(
                get: { editingAutomationID.map { SheetTarget(automationID: $0) } },
                set: { if $0 == nil { editingAutomationID = nil; editingSystemPrompt = false } }
            )
        ) { target in
            AutomationEditorView(
                model: model,
                automationID: target.automationID,
                isPresented: Binding(
                    get: { editingAutomationID != nil },
                    set: { if !$0 { editingAutomationID = nil; editingSystemPrompt = false } }
                )
            )
        }
        .sheet(isPresented: Binding(
            get: { editingSystemPrompt && editingAutomationID == nil },
            set: { if !$0 { editingSystemPrompt = false } }
        )) {
            AutomationSystemPromptEditor(
                model: model,
                isPresented: Binding(
                    get: { editingSystemPrompt },
                    set: { if !$0 { editingSystemPrompt = false } }
                )
            )
        }
    }

    /// Identifies which editor sheet should be presented.
    private struct SheetTarget: Identifiable {
        let automationID: String
        var id: String { automationID }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
            Text("Automations")
                .font(.headline)
            Spacer()
            Button {
                editingSystemPrompt = true
            } label: {
                Label("System Prompt", systemImage: "text.quote")
            }
            .help("Edit the shared system prompt injected into every automation run")
            Button {
                editingAutomationID = newAutomationID
            } label: {
                Label("New Automation", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if model.automations.isEmpty {
            emptyState
        } else {
            // Resizable, so the balance between the list and the detail is the
            // user's call rather than a fixed guess.
            HSplitView {
                List(selection: $selectedAutomationID) {
                    ForEach(model.automations) { automation in
                        automationRow(automation)
                            .tag(automation.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 260, idealWidth: 380, maxWidth: 560)

                // The detail is the point of the tab: schedule, prompt and
                // every execution for the selected automation.
                Group {
                    if let automation = selectedAutomation {
                        AutomationDetailView(
                            model: model,
                            automation: automation,
                            edit: { editingAutomationID = automation.id }
                        )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("Select an automation")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 420)
            }
        }
    }

    /// The automation currently shown in the detail pane, defaulting to the
    /// first so the tab is never blank when automations exist.
    private var selectedAutomation: Automation? {
        if let selectedAutomationID,
           let match = model.automation(selectedAutomationID) {
            return match
        }
        return model.automations.first
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Automations")
                .font(.title3)
            Text(
                "Create an automation to run a Grok prompt on a cron schedule "
                    + "in a project of your choice. Each run opens a brand-new "
                    + "session."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            Button("Create Automation") {
                editingAutomationID = newAutomationID
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func automationRow(_ automation: Automation) -> some View {
        // Two lines: the name and controls on top, the schedule underneath, so
        // the schedule has the full row width instead of competing with the
        // status for space.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: automation.isPaused ? "pause.circle" : "clock")
                    .foregroundStyle(automation.isPaused ? .orange : .secondary)
                Text(automation.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if automation.isPaused {
                    Text("Paused")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if model.isRunning(automation.id) {
                    // Already in flight: a second kickstart would restart it.
                    ProgressView()
                        .controlSize(.small)
                        .help("Running now")
                } else {
                    Button {
                        model.runNow(automation.id)
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Run this automation now")
                }
            }

            HStack(spacing: 6) {
                Text(subtitle(for: automation))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                runStatus(for: automation)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAutomationID = automation.id
        }
        .contextMenu {
            Button("Edit…") {
                editingAutomationID = automation.id
            }
            Button("Run Now") {
                model.runNow(automation.id)
            }
            Button(automation.isPaused ? "Resume" : "Pause") {
                model.setPaused(automation.id, paused: !automation.isPaused)
            }
            Divider()
            Button("Delete", role: .destructive) {
                selectedAutomationID = nil
                model.deleteAutomation(automation.id)
            }
        }
    }

    /// What happened on the most recent run, so the row reports progress
    /// without the user having to open the automation.
    @ViewBuilder
    private func runStatus(for automation: Automation) -> some View {
        if model.isRunning(automation.id) {
            Text("Running…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let run = model.latestRun(for: automation.id) {
            HStack(spacing: 4) {
                switch run.status {
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .running:
                    EmptyView()
                }
                if let finished = run.finishedAt {
                    Text(finished.formatted(.relative(presentation: .numeric)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(run.errorMessage ?? "Last run \(run.status.rawValue)")
        }
    }

    /// The row's second line. Kept short on purpose: the next run time and the
    /// model are shown in full in the detail, so the row does not repeat them
    /// at the cost of truncating the schedule.
    private func subtitle(for automation: Automation) -> String {
        // Described the way it was configured, not as raw cron.
        var parts: [String] = [
            AutomationRecurrence.parse(automation.schedule).summary,
        ]
        let project = model.projectName(for: automation)
        if !project.isEmpty {
            parts.append(project)
        }
        return parts.joined(separator: " • ")
    }

    private var newAutomationID: String {
        let automation = Automation(
            name: "New automation",
            schedule: "0 * * * *"
        )
        return automation.id
    }
}

/// Sheet that edits the shared automation system prompt.
struct AutomationSystemPromptEditor: View {
    @ObservedObject var model: AutomationCenterModel
    @Binding var isPresented: Bool

    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Automation System Prompt")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(14)

            Divider()

            Text(
                "This instruction is injected ahead of every automation's own "
                    + "prompt. It is the standing policy for all automated runs."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .padding(.horizontal, 14)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setSystemPrompt(text)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 400)
        .onAppear {
            text = model.systemPrompt
        }
    }
}

/// Sheet that edits an existing automation (or creates a new one) and shows
/// its run history.
struct AutomationEditorView: View {
    @ObservedObject var model: AutomationCenterModel
    let automationID: String
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var recurrence: AutomationRecurrence = .daily(hour: 9, minute: 0)
    @State private var prompt = ""
    @State private var selectedProjectID: String?
    @State private var selectedModel: String?
    @State private var selectedEffort: AutomationReasoningEffort?
    @State private var isPaused = false

    /// Why the current schedule cannot be used, or `nil` when it is valid.
    private var scheduleProblem: String? {
        Self.scheduleProblem(in: recurrence.cronExpression)
    }

    /// Why this schedule cannot be used, or `nil` when it is valid.
    ///
    /// A schedule must both parse as cron and compile to a launchd calendar
    /// interval set, because launchd is what actually fires it.
    static func scheduleProblem(in expression: String) -> String? {
        do {
            let parsed = try CronSchedule.parse(expression)
            _ = try CronLaunchdCompiler.intervals(for: parsed)
            return nil
        } catch let error as CronSchedule.ParseError {
            return error.description
        } catch let error as CronLaunchdCompiler.CompileError {
            return error.description
        } catch {
            return "\(error)"
        }
    }

    private var isNew: Bool {
        model.automation(automationID) == nil
    }

    // MARK: - Schedule editor

    /// A recurrence picker rather than a cron field: the mode chooses which
    /// controls appear, and cron is generated underneath. `Custom` still
    /// exposes the raw expression for anything the friendly modes cannot say.
    @ViewBuilder
    private var scheduleEditor: some View {
        Picker("Repeat", selection: recurrenceKind) {
            ForEach(AutomationRecurrence.Kind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }

        switch recurrence {
        case let .everyMinutes(interval):
            Picker("Every", selection: Binding(
                get: { interval },
                set: { recurrence = .everyMinutes($0) }
            )) {
                ForEach(AutomationRecurrence.minuteIntervals, id: \.self) { value in
                    Text("\(value) minutes").tag(value)
                }
            }

        case let .hourly(minute):
            Picker("At minute", selection: Binding(
                get: { minute },
                set: { recurrence = .hourly(minute: $0) }
            )) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { value in
                    Text(":\(String(format: "%02d", value))").tag(value)
                }
            }

        case let .daily(hour, minute):
            timePicker(hour: hour, minute: minute) {
                .daily(hour: $0, minute: $1)
            }

        case let .weekly(weekdays, hour, minute):
            weekdayPicker(selected: weekdays) {
                recurrence = .weekly(weekdays: $0, hour: hour, minute: minute)
            }
            timePicker(hour: hour, minute: minute) {
                .weekly(weekdays: weekdays, hour: $0, minute: $1)
            }

        case let .monthly(day, hour, minute):
            Picker("On day", selection: Binding(
                get: { day },
                set: { recurrence = .monthly(day: $0, hour: hour, minute: minute) }
            )) {
                ForEach(1...28, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            timePicker(hour: hour, minute: minute) {
                .monthly(day: day, hour: $0, minute: $1)
            }

        case let .custom(expression):
            TextField("Cron expression", text: Binding(
                get: { expression },
                set: { recurrence = .custom($0) }
            ))
            .font(.system(size: 12, design: .monospaced))
            Text("minute hour day month weekday")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // What this actually means, in words, plus the next time it will run.
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(recurrence.summary)
                    .font(.callout)
                if let next = nextRun {
                    Text("Next run \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let scheduleProblem {
            Label(scheduleProblem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// The mode selector. Switching modes keeps the time already chosen.
    private var recurrenceKind: Binding<AutomationRecurrence.Kind> {
        Binding(
            get: { recurrence.kind },
            set: { kind in
                guard kind != recurrence.kind else { return }
                recurrence = .default(for: kind, from: recurrence)
            }
        )
    }

    private func timePicker(
        hour: Int,
        minute: Int,
        rebuild: @escaping (Int, Int) -> AutomationRecurrence
    ) -> some View {
        DatePicker(
            "At",
            selection: Binding(
                get: {
                    var components = DateComponents()
                    components.hour = hour
                    components.minute = minute
                    return Calendar.current.date(from: components) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents(
                        [.hour, .minute],
                        from: date
                    )
                    recurrence = rebuild(parts.hour ?? 0, parts.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }

    private func weekdayPicker(
        selected: Set<Int>,
        update: @escaping (Set<Int>) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text("On")
            Spacer()
            ForEach(0..<7, id: \.self) { day in
                let isOn = selected.contains(day)
                Button {
                    var next = selected
                    if isOn {
                        // Never leave the schedule with no day selected.
                        if next.count > 1 { next.remove(day) }
                    } else {
                        next.insert(day)
                    }
                    update(next)
                } label: {
                    Text(AutomationRecurrence.weekdayNames[day])
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .frame(width: 34, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isOn ? Color.accentColor : Color.clear)
                        )
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    isOn
                                        ? Color.clear
                                        : Color(nsColor: .separatorColor)
                                )
                        }
                }
                .buttonStyle(.plain)
                .help(AutomationRecurrence.weekdayNames[day])
            }
        }
    }

    /// The next time this schedule fires, so the user can sanity-check it.
    private var nextRun: Date? {
        guard scheduleProblem == nil,
              let parsed = try? CronSchedule.parse(recurrence.cronExpression) else {
            return nil
        }
        return parsed.nextFire(after: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Automation" : "Edit Automation")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(14)

            Divider()

            Form {
                TextField("Name", text: $name)

                Section("Schedule") {
                    scheduleEditor
                }

                Picker("Project", selection: $selectedProjectID) {
                    ForEach(model.projectSuggestions()) { suggestion in
                        Text(suggestion.name).tag(Optional(suggestion.id))
                    }
                }
                Picker("Model", selection: $selectedModel) {
                    Text("Grok default").tag(String?.none)
                    ForEach(model.models) { option in
                        Text(option.isDefault ? "\(option.id) (default)" : option.id)
                            .tag(Optional(option.id))
                    }
                }
                Picker("Effort", selection: $selectedEffort) {
                    Text("Model default").tag(AutomationReasoningEffort?.none)
                    ForEach(AutomationReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(Optional(effort))
                    }
                }
                Toggle("Paused", isOn: $isPaused)
                Text("Prompt")
                    .font(.callout)
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
                    .font(.system(size: 12, design: .monospaced))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)

            if !isNew {
                runHistory
            }

            Divider()

            HStack {
                if !isNew {
                    Spacer()
                    Button("Run Now") {
                        model.runNow(automationID)
                    }
                    .disabled(!canSave)
                }
                Button(isNew ? "Create" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .padding(.top, 0)
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && scheduleProblem == nil
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedProjectID != nil
    }

    private func load() {
        if let automation = model.automation(automationID) {
            name = automation.name
            recurrence = .parse(automation.schedule)
            prompt = automation.prompt
            isPaused = automation.isPaused
            selectedModel = automation.model
            selectedEffort = automation.reasoningEffort
            if !automation.workingDirectory.isEmpty {
                selectedProjectID = model.projectSuggestions().first {
                    $0.workingDirectory == automation.workingDirectory
                }?.id
            }
        } else {
            name = ""
            recurrence = .daily(hour: 9, minute: 0)
            prompt = ""
            isPaused = false
            selectedProjectID = model.projectSuggestions().first?.id
            selectedModel = nil
            selectedEffort = nil
        }
    }

    private func workingDirectory(from projectID: String?) -> String {
        guard let projectID else { return "" }
        return model.projectSuggestions().first { $0.id == projectID }?
            .workingDirectory ?? ""
    }

    private func save() {
        let automation = Automation(
            id: automationID,
            name: name.trimmingCharacters(in: .whitespaces),
            schedule: recurrence.cronExpression,
            workingDirectory: workingDirectory(from: selectedProjectID),
            prompt: prompt,
            model: selectedModel,
            reasoningEffort: selectedEffort,
            isPaused: isPaused
        )
        model.saveAutomation(automation)
        isPresented = false
    }

    private var runHistory: some View {
        let runs = model.runs(for: automationID)
        return Group {
            if runs.isEmpty {
                Text("No runs yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runs")
                        .font(.callout.weight(.medium))
                    List(runs) { run in
                        runRow(run)
                    }
                    .frame(height: 140)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func runRow(_ run: AutomationRun) -> some View {
        HStack(spacing: 8) {
            indicatorFor(run.status)
            Text(triggerLabel(run.trigger))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(run.startedAt.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "—")
                .font(.caption)
            Spacer()
            if let sessionID = run.sessionID {
                Button("Open") {
                    model.coordinator.selectConversation(sessionID)
                    isPresented = false
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func indicatorFor(_ status: AutomationRunStatus) -> some View {
        switch status {
        case .running:
            return ProgressView().controlSize(.small)
                .eraseToAnyView()
        case .succeeded:
            return Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .eraseToAnyView()
        case .failed:
            return Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .eraseToAnyView()
        }
    }

    private func triggerLabel(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .scheduled: return "Scheduled"
        case .forced: return "Manual"
        }
    }
}

extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
}
