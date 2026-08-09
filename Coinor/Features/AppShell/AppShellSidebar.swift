import AppKit
import SwiftUI

struct AppShellSidebar: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var reorder = SidebarReorderModel()

    @State private var renameSessionID: String?
    @State private var renameText = ""
    @State private var renameProjectID: String?
    @State private var renameProjectText = ""
    @State private var worktreeProjectID: String?
    @State private var worktreeName = ""
    @State private var appearanceProjectID: String?
    @State private var searchText = ""
    @State private var remoteSheet: RemoteSidebarSheet?
    @FocusState private var focusedProjectMenuID: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField

            List(selection: selection) {
                if isSearching {
                    Section {
                        if searchResults.isEmpty {
                            Text("No matching conversations")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
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
                    } header: {
                        sectionHeader("Search Results")
                    }
                    .accessibilityIdentifier(
                        AppShellIdentifier.searchResultsSection
                    )
                } else {
                    if !coordinator.catalog.pinned.isEmpty {
                        Section {
                            ForEach(displayPinnedConversations) { conversation in
                                conversationRow(
                                    conversation,
                                    pinned: true,
                                    reorderScope: .pinned
                                )
                            }
                        } header: {
                            sectionHeader("Pinned")
                        }
                        .accessibilityIdentifier(
                            AppShellIdentifier.pinnedSection
                        )
                    }

                    Section {
                        if coordinator.catalog.projects.isEmpty {
                            Text("No projects")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(displayProjects) { project in
                                projectRow(project)
                            }
                        }
                    } header: {
                        sectionHeader("Projects")
                    }
                    .accessibilityIdentifier(
                        AppShellIdentifier.projectsSection
                    )
                }
            }
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
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 12) {
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
                    Image(systemName: "folder.badge.plus")
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
                    Image(systemName: "desktopcomputer")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(sidebarControlColor)
                .fixedSize()
                .help("Remote Computers")
                .accessibilityLabel("Remote Computers")

                Spacer()

                Button {
                    coordinator.showsArchivedItems = true
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(sidebarControlColor)
                .help("Archived Items")
                .accessibilityLabel("Archived Items")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
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

    private var selection: Binding<String?> {
        Binding(
            get: { coordinator.selectedSessionID },
            set: { value in
                if let value {
                    coordinator.selectConversation(value)
                }
            }
        )
    }

    /// Opens a conversation from a primary click on its row.
    ///
    /// `List` only reports a selection that actually changed, so clicking the
    /// current row, or clicking after a selection attempt left the coordinator
    /// unchanged, would otherwise never reach the coordinator. Calling it here
    /// is safe because `selectConversation` reuses an existing runtime instead
    /// of launching a second one.
    private func activateConversation(_ conversationID: String) {
        switch SidebarConversationActivation.primaryClick(
            conversationID: conversationID,
            isReordering: reorder.isActive
        ) {
        case let .activate(sessionID):
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
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $searchText)
                .textFieldStyle(.plain)
                .onExitCommand {
                    searchText = ""
                }
                .accessibilityIdentifier(
                    AppShellIdentifier.conversationSearchField
                )
            if isSearching {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Emits a project as flat sibling rows instead of a `DisclosureGroup`.
    ///
    /// `List` keeps its own outline indentation per row, and a long-lived
    /// sidebar can leave a collapsed project header sitting at the indentation
    /// of the conversations it owns. Owning the indentation here keeps every
    /// header on the same leading edge for the life of the session.
    @ViewBuilder
    private func projectRow(_ project: ProjectRow) -> some View {
        if reorder.isDragging(project.projectID, in: .projects) {
            projectReorderPlaceholder(project)
                .transaction { $0.animation = nil }
        } else {
            projectHeaderRow(project)
                // Recycled sidebar rows cross-fade their labels when an
                // ambient animation reaches them, which paints two project
                // names on top of each other. Row content updates stay
                // instantaneous.
                .transaction { $0.animation = nil }

            if project.isExpanded {
                ForEach(displayConversations(in: project)) { conversation in
                    conversationRow(
                        conversation,
                        pinned: false,
                        reorderScope: .project(project.projectID),
                        projectDropTargetID: project.projectID
                    )
                    .padding(.leading, SidebarLayout.conversationIndent)
                }
            }
        }
    }

    private func projectHeaderRow(
        _ project: ProjectRow
    ) -> some View {
        SidebarHoverState(isDisabled: reorder.isActive) { isHovered in
            let showsNewConversation =
                isHovered || focusedProjectMenuID == project.projectID

            HStack(spacing: 0) {
                projectDisclosureControl(project)
                HStack(spacing: 7) {
                    Image(
                        systemName: coordinator.projectIconName(
                            project.projectID
                        )
                    )
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 20, alignment: .center)
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
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                                .font(
                                    .system(
                                        size: 11,
                                        weight: .medium
                                    )
                                )
                            Image(systemName: "chevron.down")
                                .font(
                                    .system(
                                        size: 7,
                                        weight: .semibold
                                    )
                                )
                        }
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(sidebarControlColor)
                        .frame(width: 26, height: 18)
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
            }
            .frame(height: SidebarReorderMetrics.projectHeaderHeight)
            .contentShape(Rectangle())
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

    /// Chevron that mirrors the sidebar's disclosure affordance.
    ///
    /// Project rows are flat `List` rows, so the sidebar draws and positions
    /// this control itself instead of inheriting one from `DisclosureGroup`.
    private func projectDisclosureControl(
        _ project: ProjectRow
    ) -> some View {
        Button {
            coordinator.setProjectExpanded(
                project.projectID,
                expanded: !project.isExpanded
            )
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                .frame(
                    width: SidebarLayout.disclosureWidth,
                    height: SidebarLayout.disclosureWidth,
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
            .tag(conversation.id)
            .transaction { $0.animation = nil }
        } else {
            conversationRowContent(
                conversation,
                pinned: pinned
            )
            .tag(conversation.id)
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

            Button {
                activateConversation(conversation.id)
            } label: {
                HStack(spacing: 7) {
                    Text(conversation.session.title)
                        .font(.system(size: 13, weight: .light))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ConversationIndicatorView(
                        indicator: coordinator.indicator(for: conversation.id)
                    )
                    conversationControlFootprint(pinSymbol: pinSymbol)
                }
                .frame(height: SidebarReorderMetrics.conversationHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                conversationControls(
                    conversation,
                    pinned: pinned,
                    pinSymbol: pinSymbol
                )
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .accessibilityHidden(!showsControls)
            }
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
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin" : "Pin")
            .accessibilityLabel(pinned ? "Unpin" : "Pin")

            Button {
                coordinator.archiveConversation(conversation.id)
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.plain)
            .help("Archive")
            .accessibilityLabel("Archive")
        }
    }

    /// Inert stand-in that holds the trailing controls' width inside the
    /// activation button's label.
    ///
    /// It mirrors the control icons instead of a fixed number so the reserved
    /// space cannot drift from the real controls, and it stays out of the view
    /// tree's interactive and accessibility surfaces.
    private func conversationControlFootprint(
        pinSymbol: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: pinSymbol)
            Image(systemName: "archivebox")
        }
        .hidden()
        .accessibilityHidden(true)
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
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.tertiary)
            .textCase(nil)
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

/// Leading geometry the sidebar controls itself.
///
/// `List` no longer indents project conversations, so these constants keep the
/// disclosure chevron and the conversation rows aligned with the project header
/// they belong to.
private enum SidebarLayout {
    static let disclosureWidth: CGFloat = 9
    static let conversationIndent: CGFloat = 21
}

private enum RemoteSidebarSheet: Identifiable {
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
