import AppKit
import SwiftUI

struct AppShellSidebar: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var destination: AppShellDestination
    @StateObject private var reorder = SidebarReorderModel()

    @State private var renameSessionID: String?
    @State private var renameText = ""
    @State private var renameProjectID: String?
    @State private var renameProjectText = ""
    @State private var worktreeProjectID: String?
    @State private var worktreeName = ""
    @State private var appearanceProjectID: String?
    @State private var searchText = ""
    @State private var agenticSearch = AgenticSearchPanelState()
    @State private var remoteSheet: RemoteSidebarSheet?
    @FocusState private var focusedProjectMenuID: String?
    @FocusState private var agenticSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if agenticSearch.isPresented {
                if let model = agenticSearch.model {
                    AgenticSearchPanelView(
                        model: model,
                        coordinator: coordinator,
                        submit: { submitAgenticSearch() },
                        dismiss: { dismissAgenticSearch() }
                    )
                } else {
                    AgenticSearchUnavailablePanelView(
                        unavailableMessage: agenticSearch.unavailableMessage
                            ?? AgenticSearchPanelState.unavailableMessage,
                        dismiss: { dismissAgenticSearch() }
                    )
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearching && !agenticSearch.isPresented {
                        searchResultsSection
                    } else {
                        automationsDestinationRow
                        pinnedSection
                        projectsSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            }
            .scrollContentBackground(.hidden)
            .onDrop(
                of: [
                    .coinorProjectReorder,
                    .coinorConversationReorder,
                ],
                delegate: SidebarReorderBackgroundDropDelegate(
                    model: reorder,
                    currentOrder: {
                        currentOrder(for: $0)
                    },
                    commit: {
                        commitReorder(scope: $0, order: $1)
                    }
                )
            )

            sidebarFooterSeparator

            HStack(spacing: 2) {
                Menu {
                    Button("On This Mac…") {
                        addProject()
                    }
                    Menu("From Remote Computer") {
                        if coordinator.registeredRemoteHosts.isEmpty {
                            Button("No Remote Computers Registered") {}
                                .disabled(true)
                        } else {
                            ForEach(
                                coordinator.registeredRemoteHosts,
                                id: \.rawValue
                            ) { alias in
                                Button(alias.rawValue) {
                                    remoteSheet = .addProject(alias)
                                }
                            }
                        }
                    }
                } label: {
                    SidebarFooterGlyph(systemName: "folder.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(sidebarControlColor)
                .fixedSize()
                .help("Add Project")
                .accessibilityLabel("Add Project")

                Menu {
                    Button("Add Remote Computer…") {
                        remoteSheet = .addHost
                    }
                    Button("Manage Remote Computers…") {
                        remoteSheet = .manageHosts
                    }
                    Divider()
                    Button(
                        coordinator.remoteProjectsHidden
                            ? "Show Remote Projects"
                            : "Hide Remote Projects"
                    ) {
                        coordinator.setRemoteProjectsHidden(
                            !coordinator.remoteProjectsHidden
                        )
                    }
                    .disabled(coordinator.registeredRemoteHosts.isEmpty)
                } label: {
                    SidebarFooterGlyph(systemName: "desktopcomputer")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(sidebarControlColor)
                .fixedSize()
                .help("Remote Computers")
                .accessibilityLabel("Remote Computers")

                Spacer(minLength: 0)

                Button {
                    coordinator.showsArchivedItems = true
                } label: {
                    SidebarFooterGlyph(systemName: "archivebox")
                }
                .buttonStyle(.plain)
                .foregroundStyle(sidebarControlColor)
                .help("Archived Items")
                .accessibilityLabel("Archived Items")
            }
            .padding(.horizontal, SidebarStyle.rowInset)
            .frame(height: 36)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.sidebar)
        .sheet(item: $remoteSheet) { sheet in
            switch sheet {
            case .addHost:
                AddRemoteHostView(coordinator: coordinator)
            case .manageHosts:
                RemoteHostsManagementView(coordinator: coordinator)
            case let .addProject(alias):
                RemoteProjectPickerView(
                    coordinator: coordinator,
                    alias: alias
                )
            }
        }
        .onChange(of: remoteSheet) { sheet in
            coordinator.isRemoteHostsInterfacePresented = sheet != nil
        }
        .onDisappear {
            coordinator.isRemoteHostsInterfacePresented = false
        }
        .alert("Rename Conversation", isPresented: renamePresented) {
            TextField("Conversation name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renameSessionID = nil
            }
            Button("Rename") {
                if let renameSessionID {
                    coordinator.renameConversation(
                        renameSessionID,
                        title: renameText
                    )
                }
                renameSessionID = nil
            }
        }
        .alert("Rename Project", isPresented: renameProjectPresented) {
            TextField("Project name", text: $renameProjectText)
            Button("Cancel", role: .cancel) {
                renameProjectID = nil
            }
            Button("Rename") {
                if let renameProjectID {
                    coordinator.renameProject(
                        renameProjectID,
                        displayName: renameProjectText
                    )
                }
                renameProjectID = nil
            }
            .disabled(
                renameProjectText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        } message: {
            Text("This changes only how the project appears in Conan Code.")
        }
        .alert("New Worktree", isPresented: worktreePresented) {
            TextField("Worktree name", text: $worktreeName)
            Button("Cancel", role: .cancel) {
                worktreeProjectID = nil
            }
            Button("Create") {
                if let worktreeProjectID {
                    coordinator.createWorktreeConversation(
                        in: worktreeProjectID,
                        name: worktreeName
                    )
                }
                worktreeProjectID = nil
            }
            .disabled(worktreeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for the new worktree.")
        }
        .onChange(of: isSearching) { searching in
            if searching {
                reorder.cancel()
            }
        }
        .onAppear {
            coordinator.setVisibleConversationNavigationIDs(
                keyboardNavigationConversationIDs
            )
        }
        .onChange(of: keyboardNavigationConversationIDs) { conversationIDs in
            coordinator.setVisibleConversationNavigationIDs(conversationIDs)
        }
        .onDisappear {
            coordinator.setVisibleConversationNavigationIDs([])
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            sectionHeader("Search Results")

            if searchResults.isEmpty {
                emptyStateLabel("No matching conversations")
                    .accessibilityIdentifier(
                        AppShellIdentifier.searchEmptyState
                    )
            } else {
                ForEach(searchResults) { conversation in
                    conversationRow(
                        conversation,
                        pinned: coordinator.metadata
                            .isSessionPinned(conversation.id)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.searchResultsSection)
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !coordinator.catalog.pinned.isEmpty {
            VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                sectionHeader("Pinned")

                ForEach(displayPinnedConversations) { conversation in
                    conversationRow(
                        conversation,
                        pinned: true,
                        reorderScope: .pinned
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AppShellIdentifier.pinnedSection)
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Projects")

            if coordinator.catalog.projects.isEmpty {
                emptyStateLabel("No projects")
            } else {
                ForEach(displayProjects) { project in
                    projectRow(project)
                        .padding(
                            .top,
                            project.id == displayProjects.first?.id
                                ? 0
                                : SidebarStyle.groupSpacing
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AppShellIdentifier.projectsSection)
    }

    /// The top-level Automations destination row: switches the detail pane to
    /// the Automations tab.
    @ViewBuilder
    private var automationsDestinationRow: some View {
        let isSelected = destination == .automations
        Button {
            destination = .automations
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
                    )
                Text("Automations")
                    .font(SidebarStyle.conversationFont)
                    .foregroundStyle(
                        isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
                    )
                Spacer(minLength: 4)
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: SidebarReorderMetrics.conversationHeight)
            .background(
                SidebarRowBackground(
                    isSelected: isSelected,
                    isHovered: false
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarStyle.rowInset)
        .accessibilityLabel("Automations")
        .accessibilityIdentifier(AppShellIdentifier.automationsDestination)
    }

    private var sidebarFooterSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    private func emptyStateLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SidebarStyle.rowInset + 8)
            .frame(height: SidebarReorderMetrics.conversationHeight)
    }

    /// Opens a conversation from a primary click on its row.
    ///
    /// A row that is already selected still has to reach the coordinator,
    /// because a click can also mean "bring this conversation back". Calling it
    /// here is safe because `selectConversation` reuses an existing runtime
    /// instead of launching a second one.
    private func activateConversation(_ conversationID: String) {
        switch SidebarConversationActivation.primaryClick(
            conversationID: conversationID,
            isReordering: reorder.isActive
        ) {
        case let .activate(sessionID):
            destination = .conversation
            coordinator.selectConversation(sessionID)
        case .ignore:
            break
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameSessionID != nil },
            set: { if !$0 { renameSessionID = nil } }
        )
    }

    private var worktreePresented: Binding<Bool> {
        Binding(
            get: { worktreeProjectID != nil },
            set: { if !$0 { worktreeProjectID = nil } }
        )
    }

    private var renameProjectPresented: Binding<Bool> {
        Binding(
            get: { renameProjectID != nil },
            set: { if !$0 { renameProjectID = nil } }
        )
    }

    private var sidebarControlColor: Color {
        Color(nsColor: .labelColor)
    }

    private var isSearching: Bool {
        ConversationSearch.hasEffectiveQuery(searchText)
    }

    private var searchResults: [ConversationRow] {
        coordinator.searchConversations(searchText)
    }

    private var displayProjects: [ProjectRow] {
        orderedRows(
            coordinator.catalog.projects,
            scope: .projects
        )
    }

    private var displayPinnedConversations: [ConversationRow] {
        orderedRows(
            coordinator.catalog.pinned,
            scope: .pinned
        )
    }

    private var keyboardNavigationConversationIDs: [String] {
        guard !reorder.isActive else { return [] }
        if agenticSearch.isPresented, let model = agenticSearch.model,
           case .results(let response) = model.state {
            return response.matches.map(\.sessionID)
        }
        if isSearching {
            return searchResults.map(\.id)
        }
        return displayPinnedConversations.map(\.id)
            + displayProjects.flatMap { project in
                project.isExpanded
                    ? displayConversations(in: project).map(\.id)
                    : []
            }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(
                agenticSearch.isPresented
                    ? "Describe the conversation"
                    : "Search conversations",
                text: agenticSearch.isPresented
                    ? Binding(
                        get: { agenticSearch.model?.query ?? "" },
                        set: { agenticSearch.model?.query = $0 }
                    )
                    : $searchText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($agenticSearchFieldFocused)
                .disabled(
                    agenticSearch.isPresented && !agenticSearch.acceptsInput
                )
                .onSubmit {
                    submitAgenticSearch()
                }
                .onExitCommand {
                    if agenticSearch.isPresented {
                        dismissAgenticSearch()
                    } else {
                        searchText = ""
                    }
                }
                .accessibilityIdentifier(
                    AppShellIdentifier.conversationSearchField
                )
            if isSearching && !agenticSearch.isPresented {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
            Button {
                if agenticSearch.isPresented {
                    dismissAgenticSearch()
                } else {
                    presentAgenticSearch()
                }
            } label: {
                Image(
                    systemName: agenticSearch.isPresented
                        ? "sparkles"
                        : "sparkle.magnifyingglass"
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        agenticSearch.isPresented
                            ? Color.accentColor
                            : Color.secondary
                    )
            }
            .buttonStyle(.plain)
            .help(
                agenticSearch.isPresented
                    ? "Close Agent Search"
                    : "Search with Grok"
            )
            .accessibilityLabel("Search with Grok")
            .accessibilityValue(agenticSearch.isPresented ? "On" : "Off")
            .accessibilityHint(
                agenticSearch.isPresented
                    ? "Turns off semantic conversation search"
                    : "Turns on semantic conversation search"
            )
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .padding(.horizontal, SidebarStyle.rowInset)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func presentAgenticSearch() {
        let model = coordinator.makeAgenticFinderModel()
        let carried = searchText
        searchText = ""
        reorder.cancel()
        var shouldSubmit = false
        withAnimation(.easeOut(duration: 0.16)) {
            shouldSubmit = agenticSearch.present(model, carrying: carried)
        }
        if shouldSubmit {
            submitAgenticSearch()
        }
        Task { @MainActor in
            await Task.yield()
            agenticSearchFieldFocused = agenticSearch.acceptsInput
        }
    }

    private func dismissAgenticSearch() {
        guard agenticSearch.isPresented else { return }
        searchText = ""
        agenticSearchFieldFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            agenticSearch.dismiss()
        }
    }

    private func submitAgenticSearch() {
        guard let model = agenticSearch.model else { return }
        model.submit {
            await coordinator.agenticFinderCandidates()
        } onResponse: { response in
            response.explicitActions.forEach {
                coordinator.applyAgenticFinderMatch($0.requestedAction)
            }
        }
    }

    /// Emits a project as a header followed by the conversations it owns.
    ///
    /// The group is one stack so a project and its conversations move, indent,
    /// and space as a unit, and so the conversation titles start exactly under
    /// the project title above them.
    private func projectRow(_ project: ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            if reorder.isDragging(project.projectID, in: .projects) {
                projectReorderPlaceholder(project)
            } else {
                projectHeaderRow(project)

                if project.isExpanded {
                    ForEach(displayConversations(in: project)) { conversation in
                        conversationRow(
                            conversation,
                            pinned: false,
                            reorderScope: .project(project.projectID),
                            projectDropTargetID: project.projectID
                        )
                        .padding(.leading, SidebarStyle.conversationIndent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Recycled sidebar rows cross-fade their labels when an ambient
        // animation reaches them, which paints two project names on top of
        // each other. Row content updates stay instantaneous.
        .transaction { $0.animation = nil }
    }

    private func projectHeaderRow(
        _ project: ProjectRow
    ) -> some View {
        SidebarHoverState(isDisabled: reorder.isActive) { isHovered in
            let showsNewConversation =
                isHovered || focusedProjectMenuID == project.projectID

            HStack(spacing: SidebarStyle.iconGap) {
                projectLeadingSlot(project, isHovered: isHovered)
                Text(coordinator.projectDisplayName(project.projectID))
                    .font(SidebarStyle.projectFont)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let alias = coordinator.hostAlias(
                    forProject: project.projectID
                ) {
                    RemoteHostBadge(
                        alias: alias,
                        isUnavailable:
                            coordinator.remoteHost(alias) == nil
                            || coordinator.remoteHost(alias)?
                                .unreachableReason != nil
                    )
                }
                ConversationIndicatorView(
                    indicator: coordinator.projectIndicator(project)
                )
                Menu {
                    Button("In Main Checkout") {
                        coordinator.createConversation(
                            in: project.projectID
                        )
                    }
                    Button("In New Worktree") {
                        worktreeName = ""
                        worktreeProjectID = project.projectID
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(sidebarControlColor)
                .fixedSize()
                .opacity(showsNewConversation ? 1 : 0)
                .focused(
                    $focusedProjectMenuID,
                    equals: project.projectID
                )
                .help("New Conversation")
                .accessibilityLabel("New Conversation")
                .accessibilityHint(
                    "Choose where to start the conversation"
                )
            }
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(height: SidebarReorderMetrics.projectHeaderHeight)
            .background(
                SidebarRowBackground(
                    isSelected: false,
                    isHovered: isHovered
                )
            )
            .contentShape(Rectangle())
            .padding(.horizontal, SidebarStyle.rowInset)
            .onTapGesture {
                coordinator.setProjectExpanded(
                    project.projectID,
                    expanded: !project.isExpanded
                )
            }
            .onDrag {
                reorder.begin(
                    scope: .projects,
                    itemID: project.projectID,
                    currentOrder: currentOrder(for: .projects)
                )
            } preview: {
                projectDragPreview(project)
            }
            .onDrop(
                of: [.coinorProjectReorder],
                delegate: projectDropDelegate(
                    targetProjectID: project.projectID
                )
            )
            .contextMenu {
                Button("Rename Project") {
                    renameProjectText = coordinator.projectDisplayName(
                        project.projectID
                    )
                    renameProjectID = project.projectID
                }
                if coordinator.projectHasCustomDisplayName(project.projectID) {
                    Button("Use Folder Name") {
                        coordinator.useFolderName(for: project.projectID)
                    }
                }
                Button("Change Icon") {
                    appearanceProjectID = project.projectID
                }
                Divider()
                Button("Archive Project") {
                    coordinator.archiveProject(project.projectID)
                }
            }
            .popover(
                isPresented: projectAppearancePresented(project.projectID),
                arrowEdge: .trailing
            ) {
                ProjectAppearancePicker(
                    initialIconName: coordinator.projectIconName(
                        project.projectID
                    ),
                    initialColorName: coordinator.projectIconColorName(
                        project.projectID
                    ),
                    apply: { iconName, colorName in
                        coordinator.setProjectAppearance(
                            project.projectID,
                            iconName: iconName,
                            colorName: colorName
                        )
                    },
                    dismiss: {
                        appearanceProjectID = nil
                    }
                )
            }
        }
    }

    /// The project's identity and its disclosure control, in one slot.
    ///
    /// A project is recognized by its icon, and the chevron only matters while
    /// the pointer is on the row, so the two share a single leading slot: the
    /// icon reads at rest, the chevron takes over on hover. Sharing the slot
    /// also lets a conversation title start directly under its project title.
    private func projectLeadingSlot(
        _ project: ProjectRow,
        isHovered: Bool
    ) -> some View {
        Button {
            coordinator.setProjectExpanded(
                project.projectID,
                expanded: !project.isExpanded
            )
        } label: {
            ZStack {
                Image(
                    systemName: coordinator.projectIconName(
                        project.projectID
                    )
                )
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    ProjectIconColorChoice.choice(
                        for: coordinator.projectIconColorName(
                            project.projectID
                        )
                    ).color
                )
                .opacity(isHovered ? 0 : 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                    .opacity(isHovered ? 1 : 0)
            }
            .frame(
                width: SidebarStyle.iconWidth,
                height: SidebarReorderMetrics.projectHeaderHeight,
                alignment: .center
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            project.isExpanded ? "Collapse Project" : "Expand Project"
        )
    }

    private func projectReorderPlaceholder(
        _ project: ProjectRow
    ) -> some View {
        Color.clear
            .frame(
                height:
                    SidebarReorderMetrics.projectHeaderHeight
                    + (
                        project.isExpanded
                            ? CGFloat(project.conversations.count)
                                * SidebarReorderMetrics.listRowHeight
                            : 0
                    )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func conversationRow(
        _ conversation: ConversationRow,
        pinned: Bool,
        reorderScope: SidebarReorderScope? = nil,
        projectDropTargetID: String? = nil
    ) -> some View {
        if let reorderScope {
            reorderableConversationRow(
                conversation,
                pinned: pinned,
                scope: reorderScope,
                projectDropTargetID: projectDropTargetID
            )
            .transaction { $0.animation = nil }
        } else {
            conversationRowContent(
                conversation,
                pinned: pinned
            )
            .transaction { $0.animation = nil }
        }
    }

    private func conversationRowContent(
        _ conversation: ConversationRow,
        pinned: Bool
    ) -> some View {
        let pinSymbol = pinned ? "pin.slash" : "pin"

        // The activation button is the base layer and owns the whole row, so a
        // primary click anywhere that a control does not claim opens the
        // conversation. The controls sit in a sibling overlay above it rather
        // than inside its label, so neither one is nested in the other.
        return SidebarHoverState(isDisabled: reorder.isActive) { isHovered in
            let showsControls = SidebarConversationActivation.showsRowControls(
                isHovered: isHovered,
                isReordering: reorder.isActive
            )

            let isSelected = destination == .conversation
                && coordinator.selectedSessionID == conversation.id

            Button {
                activateConversation(conversation.id)
            } label: {
                HStack(spacing: 6) {
                    Text(conversation.session.title)
                        .font(SidebarStyle.conversationFont)
                        .foregroundStyle(
                            isSelected
                                ? Color(nsColor: .labelColor)
                                : Color(nsColor: .secondaryLabelColor)
                        )
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if coordinator.isAutomationRun(conversation.id) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Automation run")
                    }
                    ConversationIndicatorView(
                        indicator: coordinator.indicator(for: conversation.id)
                    )
                }
                // The pin and archive controls only exist while the pointer is
                // on the row, so a resting title keeps the full width instead
                // of truncating around space nothing is using.
                .padding(
                    .trailing,
                    showsControls ? SidebarStyle.controlsWidth : 0
                )
                .padding(.horizontal, SidebarStyle.rowPadding)
                .frame(height: SidebarReorderMetrics.conversationHeight)
                .background(
                    SidebarRowBackground(
                        isSelected: isSelected,
                        isHovered: isHovered
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                conversationControls(
                    conversation,
                    pinned: pinned,
                    pinSymbol: pinSymbol
                )
                .padding(.trailing, SidebarStyle.rowPadding)
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .accessibilityHidden(!showsControls)
            }
            .padding(.horizontal, SidebarStyle.rowInset)
            .contextMenu {
                if pinned {
                    Button("Unpin") {
                        coordinator.unpin(conversation.id)
                    }
                } else {
                    Button("Pin") {
                        coordinator.pin(conversation.id)
                    }
                }
                Button("Rename") {
                    renameText = conversation.session.title
                    renameSessionID = conversation.id
                }
                Divider()
                Button("Archive") {
                    coordinator.archiveConversation(conversation.id)
                }
            }
        }
    }

    /// The trailing pin and archive controls for a conversation row.
    ///
    /// These live in the row's overlay, above the activation button and beside
    /// it in the view tree, so each one claims only its own icon and a click
    /// on a control never doubles as a row activation.
    private func conversationControls(
        _ conversation: ConversationRow,
        pinned: Bool,
        pinSymbol: String
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                if pinned {
                    coordinator.unpin(conversation.id)
                } else {
                    coordinator.pin(conversation.id)
                }
            } label: {
                Image(systemName: pinSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin" : "Pin")
            .accessibilityLabel(pinned ? "Unpin" : "Pin")

            Button {
                coordinator.archiveConversation(conversation.id)
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Archive")
            .accessibilityLabel("Archive")
        }
    }

    @ViewBuilder
    private func reorderableConversationRow(
        _ conversation: ConversationRow,
        pinned: Bool,
        scope: SidebarReorderScope,
        projectDropTargetID: String?
    ) -> some View {
        let row = conversationRowContent(
            conversation,
            pinned: pinned
        )
            .opacity(
                reorder.isDragging(conversation.id, in: scope)
                    ? 0.001
                    : 1
            )
            .onDrag {
                reorder.begin(
                    scope: scope,
                    itemID: conversation.id,
                    currentOrder: currentOrder(for: scope)
                )
            } preview: {
                conversationDragPreview(conversation)
            }
            .onDrop(
                of: [scope.contentType],
                delegate: SidebarReorderDropDelegate(
                    scope: scope,
                    targetID: conversation.id,
                    targetHeight: SidebarReorderMetrics
                        .conversationHeight,
                    forceAfterTarget: false,
                    model: reorder,
                    currentOrder: {
                        currentOrder(for: scope)
                    },
                    commit: {
                        commitReorder(scope: scope, order: $0)
                    }
                )
            )
        if let projectDropTargetID {
            row.onDrop(
                of: [.coinorProjectReorder],
                delegate: projectDropDelegate(
                    targetProjectID: projectDropTargetID,
                    forceAfterTarget: true
                )
            )
        } else {
            row
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(.tertiary)
            .textCase(nil)
            .padding(.horizontal, SidebarStyle.rowInset + 8)
            .padding(.top, SidebarStyle.sectionTopSpacing)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func projectAppearancePresented(
        _ projectID: String
    ) -> Binding<Bool> {
        Binding(
            get: { appearanceProjectID == projectID },
            set: {
                if !$0, appearanceProjectID == projectID {
                    appearanceProjectID = nil
                }
            }
        )
    }

    private func displayConversations(
        in project: ProjectRow
    ) -> [ConversationRow] {
        orderedRows(
            project.conversations,
            scope: .project(project.projectID)
        )
    }

    private func orderedRows<Row: Identifiable>(
        _ rows: [Row],
        scope: SidebarReorderScope
    ) -> [Row] where Row.ID == String {
        let rowsByID = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.id, $0) }
        )
        let order = reorder.displayOrder(
            for: scope,
            currentOrder: rows.map(\.id)
        )
        return order.compactMap { rowsByID[$0] }
    }

    private func currentOrder(
        for scope: SidebarReorderScope
    ) -> [String] {
        switch scope {
        case .projects:
            coordinator.catalog.projects.map(\.projectID)
        case .pinned:
            coordinator.catalog.pinned.map(\.id)
        case .project(let projectID):
            coordinator.catalog.projects.first {
                $0.projectID == projectID
            }?.conversations.map(\.id) ?? []
        }
    }

    private func commitReorder(
        scope: SidebarReorderScope,
        order: [String]
    ) {
        switch scope {
        case .projects:
            coordinator.reorderProjects(to: order)
        case .pinned:
            coordinator.reorderPinnedConversations(to: order)
        case .project(let projectID):
            coordinator.reorderConversations(
                in: projectID,
                to: order
            )
        }
    }

    private func projectDropDelegate(
        targetProjectID: String,
        forceAfterTarget: Bool = false
    ) -> SidebarReorderDropDelegate {
        SidebarReorderDropDelegate(
            scope: .projects,
            targetID: targetProjectID,
            targetHeight: SidebarReorderMetrics.projectHeaderHeight,
            forceAfterTarget: forceAfterTarget,
            model: reorder,
            currentOrder: {
                currentOrder(for: .projects)
            },
            commit: {
                commitReorder(scope: .projects, order: $0)
            }
        )
    }

    private func projectDragPreview(
        _ project: ProjectRow
    ) -> some View {
        HStack(spacing: 7) {
            Image(
                systemName: coordinator.projectIconName(
                    project.projectID
                )
            )
                .frame(width: 20)
                .foregroundStyle(
                    ProjectIconColorChoice.choice(
                        for: coordinator.projectIconColorName(
                            project.projectID
                        )
                    ).color
                )
            Text(coordinator.projectDisplayName(project.projectID))
                .font(.system(size: 13, weight: .light))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let alias = coordinator.hostAlias(
                forProject: project.projectID
            ) {
                RemoteHostBadge(
                    alias: alias,
                    isUnavailable:
                        coordinator.remoteHost(alias) == nil
                        || coordinator.remoteHost(alias)?
                            .unreachableReason != nil
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 238, height: 32)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor))
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func conversationDragPreview(
        _ conversation: ConversationRow
    ) -> some View {
        Text(conversation.session.title)
            .font(.system(size: 13, weight: .light))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(width: 238, height: 32)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Add Project"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.addProject(url: url)
        }
    }
}

/// The sidebar's visual vocabulary.
///
/// The sidebar draws its own rows instead of leaning on `List`, so every inset,
/// height, and weight lives here: a row is a pill inset from the sidebar edges,
/// a project reads heavier than the conversations it owns, and a conversation
/// title starts exactly under its project's title.
enum SidebarStyle {
    /// Distance from the sidebar edge to the row pill.
    static let rowInset: CGFloat = 8
    /// Distance from the pill edge to its content.
    static let rowPadding: CGFloat = 6
    static let rowRadius: CGFloat = 6
    static let rowSpacing: CGFloat = 0
    /// Breathing room between one project group and the next.
    static let groupSpacing: CGFloat = 12
    static let sectionTopSpacing: CGFloat = 14
    /// One slot carries either the project icon or its disclosure chevron, so
    /// a project title starts as close to the edge as a conversation title.
    static let iconWidth: CGFloat = 17
    static let iconGap: CGFloat = 7
    /// Room the hover controls claim from a conversation title.
    static let controlsWidth: CGFloat = 42

    /// Lines a conversation title up with the title of the project above it.
    static let conversationIndent: CGFloat = iconWidth + iconGap

    static let projectFont = Font.system(size: 13, weight: .medium)
    static let conversationFont = Font.system(size: 13, weight: .regular)
}

/// The pill behind a sidebar row.
///
/// Selection and hover differ only in weight, so a selected row stays legible
/// while the pointer moves over its neighbours.
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: SidebarStyle.rowRadius, style: .continuous)
            .fill(fill)
    }

    private var fill: Color {
        if isSelected {
            return Color.primary.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}

/// A footer control's icon, sized so the three controls read as one row.
private struct SidebarFooterGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
    }
}

private enum RemoteSidebarSheet: Identifiable, Equatable {
    case addHost
    case manageHosts
    case addProject(RemoteHostAlias)

    var id: String {
        switch self {
        case .addHost:
            "add-host"
        case .manageHosts:
            "manage-hosts"
        case let .addProject(alias):
            "add-project-\(alias.rawValue)"
        }
    }
}

/// Row-local hover tracking that keeps a single row's `.onHover` state from
/// invalidating the rest of the sidebar.
///
/// SwiftUI scopes `@State` invalidation to the view that owns the property,
/// not to wherever a modifier happens to be attached. Reading and writing
/// hover through a `@State` declared on `AppShellSidebar` itself made every
/// hover change anywhere in the sidebar re-diff the whole `List`, which is
/// what made scrolling and resizing feel coarse. This wrapper is its own
/// `View`, so a hover flip here only recomputes this one row.
private struct SidebarHoverState<Content: View>: View {
    let isDisabled: Bool
    @ViewBuilder let content: (Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isDisabled ? false : isHovered)
            .onHover { hovering in
                isHovered = isDisabled ? false : hovering
            }
            .onChange(of: isDisabled) { disabled in
                if disabled {
                    isHovered = false
                }
            }
    }
}

private struct ProjectAppearancePicker: View {
    @State private var selectedIcon: ProjectIconChoice
    @State private var selectedColor: ProjectIconColorChoice

    let apply: (String?, String?) -> Void
    let dismiss: () -> Void

    private let columns = Array(
        repeating: GridItem(.fixed(34), spacing: 10),
        count: 6
    )

    init(
        initialIconName: String,
        initialColorName: String?,
        apply: @escaping (String?, String?) -> Void,
        dismiss: @escaping () -> Void
    ) {
        _selectedIcon = State(
            initialValue: ProjectIconChoice.choice(
                for: initialIconName
            )
        )
        _selectedColor = State(
            initialValue: ProjectIconColorChoice.choice(
                for: initialColorName
            )
        )
        self.apply = apply
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ProjectIconColorChoice.allCases) { choice in
                    Button {
                        selectedColor = choice
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 28, height: 28)
                            .padding(3)
                            .overlay {
                                if selectedColor == choice {
                                    Circle()
                                        .stroke(
                                            Color(nsColor: .labelColor),
                                            lineWidth: 2
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(choice.title)
                    .accessibilityLabel(
                        "\(choice.title) icon color"
                    )
                    .accessibilityValue(
                        selectedColor == choice ? "Selected" : ""
                    )
                }
            }

            Divider()

            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(ProjectIconChoice.allCases) { choice in
                    Button {
                        selectedIcon = choice
                    } label: {
                        Image(systemName: choice.systemName)
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(selectedColor.color)
                            .frame(width: 34, height: 32)
                            .background {
                                if selectedIcon == choice {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(
                                            Color(nsColor: .selectedContentBackgroundColor)
                                                .opacity(0.22)
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(choice.title)
                    .accessibilityLabel(choice.title)
                    .accessibilityValue(
                        selectedIcon == choice ? "Selected" : ""
                    )
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    apply(
                        selectedIcon.persistedName,
                        selectedColor.persistedName
                    )
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 286)
    }
}
