import SwiftUI

/// The workflow center: browse launchable workflow definitions for the
/// current conversation, launch one, and watch/control its runs.
///
/// Grok owns every run's authoritative state; this view only renders what
/// `WorkflowCenterModel` mirrors and forwards user intent to
/// `AppCoordinator`.
struct WorkflowCenterView: View {
    @ObservedObject var model: WorkflowCenterModel
    @ObservedObject var coordinator: AppCoordinator
    let returnToConversation: () -> Void

    @State private var catalogQuery: String = ""

    private var isLoading: Bool {
        model.catalogState == .loading || model.runsState == .loading
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.context == nil {
                noContextState
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 900 {
                        HStack(spacing: 0) {
                            catalogPanel
                                .frame(width: 300)
                            Divider()
                            detailPanel
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            catalogPanel
                                .frame(height: min(260, geometry.size.height * 0.38))
                            Divider()
                            detailPanel
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.workflowCenter)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: returnToConversation) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to Conversation")
            .accessibilityLabel("Back to Conversation")
            .accessibilityIdentifier(AppShellIdentifier.workflowBackButton)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workflows")
                    .font(.title2.bold())
                if let context = model.context {
                    Text(context.conversationTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(context.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let remoteHostTitle = context.remoteHostTitle, !remoteHostTitle.isEmpty {
                            remoteBadge(remoteHostTitle)
                        }
                    }
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                coordinator.refreshWorkflowCenter()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.context == nil || isLoading)
            .accessibilityLabel("Refresh Workflows")
            .accessibilityIdentifier(AppShellIdentifier.workflowRefreshButton)
        }
        .padding(16)
    }

    private func remoteBadge(_ title: String) -> some View {
        Label(title, systemImage: "network")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(Color.accentColor)
    }

    // MARK: - No context

    private var noContextState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Conversation Selected")
                .font(.headline)
            Text("Select a conversation to browse and launch workflows for it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Catalog

    private var catalogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search workflows", text: $catalogQuery)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .accessibilityIdentifier(AppShellIdentifier.workflowCatalogSearch)

            Divider()

            catalogContent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.workflowCatalog)
    }

    @ViewBuilder
    private var catalogContent: some View {
        switch model.catalogState {
        case .idle, .loading:
            VStack {
                Spacer(minLength: 40)
                ProgressView("Loading workflows…")
                    .controlSize(.small)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        case let .failed(message):
            VStack(spacing: 8) {
                Spacer(minLength: 24)
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 24)
            }
            .padding()
        case .loaded:
            let groups = model.definitionGroups(matching: catalogQuery)
            if groups.isEmpty {
                VStack {
                    Spacer(minLength: 40)
                    Text(catalogQuery.isEmpty ? "No workflows available." : "No workflows match \"\(catalogQuery)\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.definitions) { definition in
                                    definitionRow(definition)
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor))
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func definitionRow(_ definition: GrokWorkflowDefinition) -> some View {
        let isSelected = model.selectedDefinitionID == definition.id
        return Button {
            model.selectedDefinitionID = definition.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: sourceIcon(definition.source))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let description = definition.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let path = definition.path, !path.isEmpty {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AppShellIdentifier.workflowDefinition(definition.name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func sourceIcon(_ source: GrokWorkflowDefinition.Source) -> String {
        switch source {
        case .project: return "folder"
        case .user: return "person"
        case .builtin: return "shippingbox"
        case .unknown: return "questionmark.folder"
        }
    }

    // MARK: - Detail

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let definition = model.selectedDefinition {
                    WorkflowLaunchCard(
                        definition: definition,
                        isLaunching: model.activeAction != nil,
                        onLaunch: { args, agentBudget in
                            coordinator.launchWorkflow(
                                name: definition.name,
                                args: args,
                                agentBudget: agentBudget
                            )
                        }
                    )
                    .id(definition.id)
                } else {
                    emptyLaunchCard
                }

                if let actionError = model.actionError {
                    actionErrorBanner(actionError)
                }

                runsSection

                if let run = model.selectedRun {
                    WorkflowRunInspector(
                        run: run,
                        isBusy: model.activeAction != nil,
                        onControl: { operation, agentBudget in
                            coordinator.controlWorkflow(
                                runID: run.runID,
                                operation: operation,
                                agentBudget: agentBudget
                            )
                        }
                    )
                    .id(run.runID)
                }
            }
            .padding(16)
        }
    }

    private var emptyLaunchCard: some View {
        WorkflowCard {
            VStack(spacing: 6) {
                Text("Select a workflow from the catalog to see its details and launch it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35))
        )
    }

    // MARK: - Runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs")
                .font(.headline)

            runsContent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.workflowRuns)
    }

    @ViewBuilder
    private var runsContent: some View {
        switch model.runsState {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView("Loading runs…")
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 12)
        case let .failed(message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        case .loaded:
            if model.visibleRuns.isEmpty {
                Text("No runs yet for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.visibleRuns) { run in
                        runRow(run)
                    }
                }
            }
        }
    }

    private func runRow(_ run: GrokWorkflowRun) -> some View {
        let isSelected = model.selectedRunID == run.id
        return Button {
            model.selectedRunID = run.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                statusIcon(run.status)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(run.status.displayName)
                        if let currentPhase = run.currentPhase, !currentPhase.isEmpty {
                            Text("· \(currentPhase)")
                        }
                        Text("· \(formatDuration(milliseconds: run.elapsedMilliseconds))")
                        Text("· \(run.agentsUsed) agents")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkflowCardBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AppShellIdentifier.workflowRun(run.runID))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Launch card

private struct WorkflowLaunchCard: View {
    let definition: GrokWorkflowDefinition
    let isLaunching: Bool
    let onLaunch: (GrokJSONValue?, Int?) -> Void

    @State private var draft = WorkflowLaunchDraft()

    var body: some View {
        WorkflowCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                Picker("Arguments", selection: $draft.mode) {
                    Text("Fields").tag(WorkflowLaunchDraft.Mode.fields)
                    Text("Raw JSON").tag(WorkflowLaunchDraft.Mode.rawJSON)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch draft.mode {
                case .fields:
                    fieldsEditor
                case .rawJSON:
                    rawJSONEditor
                }

                budgetPicker

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button {
                        launch()
                    } label: {
                        Label("Launch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLaunching || !isValid)
                    .accessibilityIdentifier(AppShellIdentifier.workflowLaunchButton)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.workflowLauncher)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.name)
                .font(.headline)
            if let description = definition.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let whenToUse = definition.whenToUse, !whenToUse.isEmpty {
                Text(whenToUse)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(draft.rows) { row in
                HStack(spacing: 6) {
                    TextField("key", text: binding(for: row.id, \.key))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    TextField("value", text: binding(for: row.id, \.value))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        draft.removeRow(id: row.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.rows.count <= 1)
                    .accessibilityLabel("Remove argument")
                }
            }
            Button {
                draft.addRow()
            } label: {
                Label("Add Argument", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func binding(
        for id: UUID,
        _ keyPath: WritableKeyPath<WorkflowLaunchArgumentRow, String>
    ) -> Binding<String> {
        Binding(
            get: {
                draft.rows.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let index = draft.rows.firstIndex(where: { $0.id == id }) else { return }
                draft.rows[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var rawJSONEditor: some View {
        TextEditor(text: $draft.rawJSON)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 100, maxHeight: 180)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .accessibilityLabel("Raw JSON arguments")
    }

    private var budgetPicker: some View {
        HStack {
            Text("Agent Budget")
                .font(.callout)
            Picker("Agent Budget", selection: $draft.agentBudget) {
                ForEach(WorkflowLaunchDraft.budgetPresets, id: \.self) { preset in
                    Text("\(preset)").tag(preset)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            Stepper(
                "Agent Budget \(draft.agentBudget)",
                value: $draft.agentBudget,
                in: 1...1024
            )
            .labelsHidden()
            Text("\(draft.agentBudget)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var errorMessage: String? {
        if case let .failure(error) = draft.resolvedArguments() {
            return error.errorDescription
        }
        if case let .failure(error) = draft.validatedAgentBudget() {
            return error.errorDescription
        }
        return nil
    }

    private var isValid: Bool {
        errorMessage == nil
    }

    private func launch() {
        guard case let .success(args) = draft.resolvedArguments(),
              case let .success(agentBudget) = draft.validatedAgentBudget() else {
            return
        }
        onLaunch(args, agentBudget)
    }
}

// MARK: - Run inspector

private struct WorkflowRunInspector: View {
    let run: GrokWorkflowRun
    let isBusy: Bool
    let onControl: (GrokWorkflowControlOperation, Int?) -> Void

    @State private var resumeBudget: Int?

    var body: some View {
        WorkflowCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !run.phases.isEmpty {
                    phaseTimeline
                }
                if let agentBudget = run.agentBudget, agentBudget > 0 {
                    budgetProgress(agentBudget)
                }
                if !run.agents.isEmpty {
                    agentList
                }
                eventDetails
                if let pauseMessage = run.pauseMessage, !pauseMessage.isEmpty {
                    Text(pauseMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
                if let resultSummary = run.resultSummary, !resultSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result")
                            .font(.subheadline.weight(.semibold))
                        Text(resultSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.workflowInspector)
        .onAppear {
            resumeBudget = WorkflowControlPresentation.suggestedHigherBudget(for: run)
        }
        .onChange(of: run.revision) { _ in
            let requiredFloor = max(run.agentsUsed, run.agentBudget ?? 0)
            if resumeBudget.map({ $0 > requiredFloor }) != true {
                resumeBudget = WorkflowControlPresentation.suggestedHigherBudget(for: run)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(run.status)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(.headline)
                Text(statusExplanation(run.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !run.objective.isEmpty {
                    Text(run.objective)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(run.status.displayName)
                    .font(.caption.weight(.semibold))
                Text(formatDuration(milliseconds: run.elapsedMilliseconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseTimeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phases")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(run.phases.enumerated()), id: \.offset) { _, phase in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(phase.title == run.currentPhase ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(phase.title)
                            .font(.callout)
                            .fontWeight(phase.title == run.currentPhase ? .semibold : .regular)
                        Spacer(minLength: 0)
                        Text(phase.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func budgetProgress(_ agentBudget: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agent Budget")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(run.agentsUsed) / \(agentBudget)\(run.agentUsageIncomplete ? "+" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, Double(run.agentsUsed) / Double(max(agentBudget, 1))))
        }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agents")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 4) {
                ForEach(run.agents) { agent in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.label)
                                .font(.callout)
                            if let phase = agent.phase, !phase.isEmpty {
                                Text(phase)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let model = agent.model, !model.isEmpty {
                            Text(model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(agent.state)
                            .font(.caption2.weight(.medium))
                        Text(formatDuration(milliseconds: agent.durationMilliseconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(formatTokens(agent.tokensUsed))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lastEvent = run.lastEvent, !lastEvent.isEmpty {
                Text(lastEvent)
                    .font(.callout)
            }
            if let lastEventDetail = run.lastEventDetail, !lastEventDetail.isEmpty {
                Text(lastEventDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastEventTimestamp = run.lastEventTimestamp, !lastEventTimestamp.isEmpty {
                Text(lastEventTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if run.status.canPause {
                Button("Pause") {
                    onControl(.pause, nil)
                }
                .disabled(isBusy)
            }
            if run.status.canResumeNormally {
                Button("Resume") {
                    onControl(.resume, nil)
                }
                .disabled(isBusy)
            }
            if run.status.canStop {
                Button("Stop", role: .destructive) {
                    onControl(.stop, nil)
                }
                .disabled(isBusy)
            }
            Spacer(minLength: 0)
        }

        if run.status.requiresHigherBudgetToResume {
            budgetResumeControl
        }
    }

    private var budgetResumeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let suggestion = WorkflowControlPresentation.suggestedHigherBudget(for: run) {
                HStack {
                    Text("Resume Budget")
                        .font(.callout)
                    Picker("Resume Budget", selection: Binding(
                        get: { resumeBudget ?? suggestion },
                        set: { resumeBudget = $0 }
                    )) {
                        ForEach(
                            WorkflowLaunchDraft.budgetPresets.filter {
                                $0 > max(run.agentsUsed, run.agentBudget ?? 0)
                            },
                            id: \.self
                        ) { preset in
                            Text("\(preset)").tag(preset)
                        }
                        if !WorkflowLaunchDraft.budgetPresets.contains(suggestion) {
                            Text("\(suggestion)").tag(suggestion)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Button("Resume with Higher Budget") {
                        onControl(.resume, resumeBudget ?? suggestion)
                    }
                    .disabled(isBusy)
                }
                if let explanation = WorkflowControlPresentation.budgetResumeExplanation(for: run) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let explanation = WorkflowControlPresentation.budgetResumeExplanation(for: run) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared card chrome

private struct WorkflowCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkflowCardBackground(isSelected: false))
    }
}

private struct WorkflowCardBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 1 : 0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)
                    )
            )
    }
}

// MARK: - Status presentation

private func statusIcon(_ status: GrokWorkflowStatus) -> some View {
    let (systemName, color) = statusGlyph(status)
    return Image(systemName: systemName)
        .foregroundStyle(color)
}

private func statusGlyph(_ status: GrokWorkflowStatus) -> (String, Color) {
    switch status {
    case .active:
        return ("bolt.fill", .green)
    case .userPaused:
        return ("pause.circle.fill", .orange)
    case .backOffPaused:
        return ("clock.arrow.circlepath", .orange)
    case .noProgressPaused:
        return ("hourglass", .orange)
    case .infraPaused:
        return ("exclamationmark.triangle.fill", .orange)
    case .blocked:
        return ("hand.raised.fill", .red)
    case .budgetLimited:
        return ("gauge.with.dots.needle.67percent", .purple)
    case .interrupted:
        return ("pause.octagon.fill", .secondary)
    case .complete:
        return ("checkmark.circle.fill", .green)
    case .failed:
        return ("xmark.circle.fill", .red)
    case .cancelled:
        return ("slash.circle.fill", .secondary)
    case .unknown:
        return ("questionmark.circle.fill", .secondary)
    }
}

private func statusExplanation(_ status: GrokWorkflowStatus) -> String {
    switch status {
    case .active:
        return "Grok is actively working on this run."
    case .userPaused:
        return "Paused. Resume to continue."
    case .backOffPaused:
        return "Paused after a transient error; it can resume from where it left off."
    case .noProgressPaused:
        return "Paused because it made no progress; review and resume when ready."
    case .infraPaused:
        return "Paused because of an infrastructure issue; resume once it clears."
    case .blocked:
        return "Blocked and waiting on something outside the run; resume once unblocked."
    case .budgetLimited:
        return "Stopped after using its full agent budget; resume with a higher budget to continue."
    case .interrupted:
        return "Interrupted before it could finish."
    case .complete:
        return "Finished successfully."
    case .failed:
        return "Failed; it can be resumed to retry."
    case .cancelled:
        return "Cancelled and will not resume."
    case let .unknown(value):
        return value.isEmpty ? "Grok reported a status Coinor does not recognize yet." : "Grok reported status \"\(value)\", which Coinor does not recognize yet."
    }
}

// MARK: - Formatting

private func formatDuration(milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds) / 1000
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%dh %02dm", hours, minutes)
    }
    if minutes > 0 {
        return String(format: "%dm %02ds", minutes, seconds)
    }
    return String(format: "%ds", seconds)
}

private func formatTokens(_ tokens: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return (formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)") + " tok"
}
