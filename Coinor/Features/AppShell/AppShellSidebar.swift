import AppKit
import SwiftUI

struct AppShellSidebar: View {
    @ObservedObject var coordinator: AppCoordinator

    @State private var renameSessionID: String?
    @State private var renameText = ""
    @State private var worktreeProjectID: String?
    @State private var worktreeName = ""
    @State private var hoveredConversationID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if !coordinator.catalog.pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(coordinator.catalog.pinned) { conversation in
                            conversationRow(conversation, pinned: true)
                        }
                    }
                    .accessibilityIdentifier(AppShellIdentifier.pinnedSection)
                }

                Section("Projects") {
                    if coordinator.catalog.projects.isEmpty {
                        Text("No projects")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(coordinator.catalog.projects) { project in
                            projectRow(project)
                        }
                    }
                }
                .accessibilityIdentifier(AppShellIdentifier.projectsSection)
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
                .help("Add Project")
                .accessibilityLabel("Add Project")

                Spacer()

                Button {
                    coordinator.showsArchivedItems = true
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
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

    private func projectRow(_ project: ProjectRow) -> some View {
        DisclosureGroup(
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
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(coordinator.projectDisplayName(project.projectID))
                    .lineLimit(1)
                Spacer(minLength: 4)
                activityIndicator(coordinator.projectActivity(project))
                Menu {
                    Button("In Main Checkout") {
                        coordinator.createConversation(in: project.projectID)
                    }
                    Button("In New Worktree") {
                        worktreeName = ""
                        worktreeProjectID = project.projectID
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New Conversation")
                .accessibilityLabel("New Conversation")
            }
            .contextMenu {
                Button("Archive Project") {
                    coordinator.archiveProject(project.projectID)
                }
            }
        }
    }

    private func conversationRow(
        _ conversation: ConversationRow,
        pinned: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Text(conversation.session.title)
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
