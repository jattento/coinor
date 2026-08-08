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
    @State private var hoveredConversationID: String?
    @State private var hoveredProjectID: String?
    @State private var appearanceProjectID: String?
    @State private var searchText = ""
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

            HStack {
                Button {
                    addProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(sidebarControlColor)
                .help("Add Project")
                .accessibilityLabel("Add Project")

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
            Text("This changes only how the project appears in Coinor.")
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

    @ViewBuilder
    private func projectRow(_ project: ProjectRow) -> some View {
        if reorder.isDragging(project.projectID, in: .projects) {
            projectReorderPlaceholder(project)
        } else {
            projectDisclosureGroup(project)
        }
    }

    private func projectDisclosureGroup(
        _ project: ProjectRow
    ) -> some View {
        let showsNewConversation =
            hoveredProjectID == project.projectID
                || focusedProjectMenuID == project.projectID

        return DisclosureGroup(
            isExpanded: Binding(
                get: { project.isExpanded },
                set: {
                    coordinator.setProjectExpanded(
                        project.projectID,
                        expanded: $0
                    )
                }
            )
        ) {
            ForEach(displayConversations(in: project)) { conversation in
                conversationRow(
                    conversation,
                    pinned: false,
                    reorderScope: .project(project.projectID),
                    projectDropTargetID: project.projectID
                )
            }
        } label: {
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
                activityIndicator(coordinator.projectActivity(project))
                    .frame(width: 12, height: 12)
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
            .frame(height: SidebarReorderMetrics.projectHeaderHeight)
            .contentShape(Rectangle())
            .onDrag {
                hoveredProjectID = nil
                return reorder.begin(
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
            .onHover { hovering in
                guard !reorder.isActive else {
                    hoveredProjectID = nil
                    return
                }
                if hovering {
                    hoveredProjectID = project.projectID
                } else if hoveredProjectID == project.projectID {
                    hoveredProjectID = nil
                }
            }
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
        } else {
            conversationRowContent(
                conversation,
                pinned: pinned
            )
        }
    }

    private func conversationRowContent(
        _ conversation: ConversationRow,
        pinned: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Text(conversation.session.title)
                .font(.system(size: 13, weight: .light))
                .lineLimit(1)
            Spacer(minLength: 4)
            activityIndicator(coordinator.activity(for: conversation.id))
            if hoveredConversationID == conversation.id {
                Button {
                    if pinned {
                        coordinator.unpin(conversation.id)
                    } else {
                        coordinator.pin(conversation.id)
                    }
                } label: {
                    Image(systemName: pinned ? "pin.slash" : "pin")
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
        .tag(conversation.id)
        .frame(height: SidebarReorderMetrics.conversationHeight)
        .contentShape(Rectangle())
        .onHover { hovered in
            if reorder.isActive {
                hoveredConversationID = nil
            } else {
                hoveredConversationID = hovered ? conversation.id : nil
            }
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
                hoveredConversationID = nil
                return reorder.begin(
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

    @ViewBuilder
    private func activityIndicator(
        _ activity: RuntimeActivity
    ) -> some View {
        switch activity {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Working")
        case .needsInput:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .accessibilityLabel("Needs attention")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .idle:
            EmptyView()
        }
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
