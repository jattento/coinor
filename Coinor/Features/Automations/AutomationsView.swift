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
        .onAppear { model.refresh() }
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
            List(selection: $selectedAutomationID) {
                ForEach(model.automations) { automation in
                    automationRow(automation)
                        .tag(automation.id)
                }
            }
            .listStyle(.sidebar)
        }
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
        HStack(spacing: 8) {
            Image(systemName: automation.isPaused ? "pause.circle" : "clock")
                .foregroundStyle(automation.isPaused ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle(for: automation))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if automation.isPaused {
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                model.runNow(automation.id)
            } label: {
                Label("Run Now", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Run this automation now")
        }
        .padding(.vertical, 2)
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

    private func subtitle(for automation: Automation) -> String {
        var parts: [String] = [automation.schedule]
        let project = model.projectName(for: automation)
        if !project.isEmpty {
            parts.append(project)
        }
        if let modelID = automation.model, !modelID.isEmpty {
            parts.append(modelID)
        }
        if let next = nextFire(for: automation) {
            parts.append("next \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " • ")
    }

    private func nextFire(for automation: Automation) -> Date? {
        guard let schedule = try? CronSchedule.parse(automation.schedule),
              !automation.isPaused else { return nil }
        return schedule.nextFire(after: Date())
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
    @State private var schedule = ""
    @State private var scheduleProblem: String?
    @State private var prompt = ""
    @State private var selectedProjectID: String?
    @State private var selectedModel: String?
    @State private var isPaused = false

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
                TextField("Schedule (cron)", text: $schedule)
                    .onChange(of: schedule) { newValue in
                        scheduleProblem = Self.scheduleProblem(in: newValue)
                    }
                if let scheduleProblem {
                    Label(scheduleProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
            && Self.scheduleProblem(in: schedule) == nil
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedProjectID != nil
    }

    private func load() {
        if let automation = model.automation(automationID) {
            name = automation.name
            schedule = automation.schedule
            prompt = automation.prompt
            isPaused = automation.isPaused
            selectedModel = automation.model
            if !automation.workingDirectory.isEmpty {
                selectedProjectID = model.projectSuggestions().first {
                    $0.workingDirectory == automation.workingDirectory
                }?.id
            }
        } else {
            name = ""
            schedule = "0 * * * *"
            prompt = ""
            isPaused = false
            selectedProjectID = model.projectSuggestions().first?.id
            selectedModel = nil
        }
        scheduleProblem = Self.scheduleProblem(in: schedule)
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
            schedule: schedule.trimmingCharacters(in: .whitespaces),
            workingDirectory: workingDirectory(from: selectedProjectID),
            prompt: prompt,
            model: selectedModel,
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
