import AppKit
import SwiftUI

struct AppShellSidebar: View {
    @ObservedObject var coordinator: AppCoordinator

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
                            ForEach(coordinator.catalog.pinned) { conversation in
                                conversationRow(conversation, pinned: true)
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
                            ForEach(coordinator.catalog.projects) { project in
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

    private func projectRow(_ project: ProjectRow) -> some View {
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
            ForEach(project.conversations) { conversation in
                conversationRow(conversation, pinned: false)
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
            .frame(height: ProjectDropOrder.headerHeight)
            .contentShape(Rectangle())
            .draggable(
                ProjectDropPayload.encoded(
                    projectID: project.projectID
                )
            )
            .dropDestination(for: String.self) {
                payloads,
                location in
                handleProjectDrop(
                    payloads,
                    location: location,
                    targetProjectID: project.projectID
                )
            }
            .onHover { hovering in
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

    private func conversationRow(
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
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovered in
            hoveredConversationID = hovered ? conversation.id : nil
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

    private func handleProjectDrop(
        _ payloads: [String],
        location: CGPoint,
        targetProjectID: String
    ) -> Bool {
        let projectIDs = coordinator.catalog.projects.map(\.projectID)
        guard let sourceProjectID = payloads
            .compactMap({
                ProjectDropPayload.projectID(
                    from: $0,
                    validProjectIDs: projectIDs
                )
            })
            .first else {
            return false
        }
        let reordered = ProjectDropOrder.reorderedProjectIDs(
            projectIDs,
            moving: sourceProjectID,
            relativeTo: targetProjectID,
            dropY: location.y,
            targetHeight: ProjectDropOrder.headerHeight
        )
        if reordered != projectIDs {
            coordinator.reorderProjects(to: reordered)
        }
        return true
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

enum ProjectDropPayload {
    private static let prefix = "coinor-project-id:"

    static func encoded(projectID: String) -> String {
        prefix + projectID
    }

    static func projectID(
        from payload: String,
        validProjectIDs: [String]
    ) -> String? {
        guard payload.hasPrefix(prefix) else {
            return nil
        }
        let projectID = String(payload.dropFirst(prefix.count))
        guard !projectID.isEmpty,
              validProjectIDs.contains(projectID) else {
            return nil
        }
        return projectID
    }
}

enum ProjectDropOrder {
    static let headerHeight: CGFloat = 18

    static func reorderedProjectIDs(
        _ projectIDs: [String],
        moving sourceProjectID: String,
        relativeTo targetProjectID: String,
        dropY: CGFloat,
        targetHeight: CGFloat
    ) -> [String] {
        guard sourceProjectID != targetProjectID,
              let sourceIndex = projectIDs.firstIndex(
                  of: sourceProjectID
              ),
              projectIDs.contains(targetProjectID) else {
            return projectIDs
        }

        var reordered = projectIDs
        reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(
            of: targetProjectID
        ) else {
            return projectIDs
        }

        let insertAfter = dropY >= targetHeight / 2
        reordered.insert(
            sourceProjectID,
            at: targetIndex + (insertAfter ? 1 : 0)
        )
        return reordered
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
