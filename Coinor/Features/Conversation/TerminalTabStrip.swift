import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let coinorTerminalTab = UTType(
        exportedAs: "dev.coinor.terminal-tab"
    )
}

@MainActor
struct ConversationTabbedView: View {
    @ObservedObject var runtime: ConversationRuntime
    let isConversationVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            TerminalTabStrip(
                runtime: runtime,
                ghosttyRuntime: runtime.root.runtime
            )

            ZStack {
                ConversationPaneView(
                    root: runtime.root,
                    descendants: runtime.descendants,
                    isVisible: isConversationVisible
                        && runtime.isMainTabSelected
                )
                .opacity(runtime.isMainTabSelected ? 1 : 0)
                .allowsHitTesting(runtime.isMainTabSelected)
                .accessibilityHidden(!runtime.isMainTabSelected)

                IDEPaneView(
                    fresh: runtime.ideFresh,
                    lazygit: runtime.ideLazygit,
                    isVisible: isConversationVisible
                        && runtime.isIDETabSelected
                )
                .opacity(runtime.isIDETabSelected ? 1 : 0)
                .allowsHitTesting(runtime.isIDETabSelected)
                .accessibilityHidden(!runtime.isIDETabSelected)

                ForEach(runtime.shellTabs) { session in
                    TerminalSurfaceRepresentable(
                        session: session,
                        isVisible: isConversationVisible
                            && runtime.selectedTabID == session.id
                    )
                        .id(
                            "\(session.id):\(session.generation):"
                                + session.launch.workingDirectory
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(runtime.selectedTabID == session.id ? 1 : 0)
                        .allowsHitTesting(
                            runtime.selectedTabID == session.id
                        )
                        .accessibilityHidden(
                            runtime.selectedTabID != session.id
                        )
                        .accessibilityIdentifier(
                            "terminal.shell.\(session.id)"
                        )
                }

                ForEach(runtime.managedTabs) { tab in
                    TerminalSurfaceRepresentable(
                        session: tab.session,
                        isVisible: isConversationVisible
                            && runtime.selectedTabID == tab.id
                    )
                        .id(
                            "\(tab.id):\(tab.session.generation):"
                                + tab.session.launch.workingDirectory
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(runtime.selectedTabID == tab.id ? 1 : 0)
                        .allowsHitTesting(runtime.selectedTabID == tab.id)
                        .accessibilityHidden(
                            runtime.selectedTabID != tab.id
                        )
                        .accessibilityIdentifier(
                            "terminal.managed.\(tab.id)"
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.tabs")
    }
}

@MainActor
private struct TerminalTabStrip: View {
    @ObservedObject var runtime: ConversationRuntime
    @ObservedObject var ghosttyRuntime: GhosttyRuntime

    @State private var hoveredTabID: String?
    @State private var draggedTabID: String?
    @State private var editingTabID: String?
    @State private var renameText = ""
    @FocusState private var focusedTabID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(runtime.tabs) { tab in
                        tabView(tab)
                            .id(tab.id)
                            .onDrop(
                                of: [.coinorTerminalTab],
                                delegate: TerminalTabDropDelegate(
                                    targetTabID: tab.id,
                                    runtime: runtime,
                                    draggedTabID: $draggedTabID
                                )
                            )
                    }

                    newTabButton
                        .id("terminal-tabs.add")
                        .onDrop(
                            of: [.coinorTerminalTab],
                            delegate: TerminalTabDropDelegate(
                                targetTabID: nil,
                                runtime: runtime,
                                draggedTabID: $draggedTabID
                            )
                        )
                }
                .frame(height: 34)
            }
            .onChange(of: runtime.selectedTabID) { selectedID in
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onAppear {
                let selectedID = runtime.selectedTabID
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .frame(height: 34)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(foregroundColor.opacity(0.18))
                .frame(height: 1)
        }
        .onChange(of: focusedTabID) { focusedID in
            if let editingTabID, focusedID != editingTabID {
                commitRename(refocusTerminal: false)
            }
        }
        .onChange(of: runtime.pendingRenameRequest) { request in
            guard let request else { return }
            beginRename(tabID: request.tabID)
            runtime.consumeRenameRequest(request.id)
        }
        .accessibilityIdentifier("terminal-tabs.bar")
    }

    @ViewBuilder
    private func tabView(_ tab: ConversationTerminalTab) -> some View {
        let isSelected = runtime.selectedTabID == tab.id
        let isHovered = hoveredTabID == tab.id

        HStack(spacing: 7) {
            Group {
                if editingTabID == tab.id {
                    TextField("", text: $renameText)
                        .textFieldStyle(.plain)
                        .foregroundColor(foregroundColor)
                        .focused($focusedTabID, equals: tab.id)
                        .onSubmit {
                            commitRename(refocusTerminal: true)
                        }
                        .onExitCommand {
                            cancelRename(refocusTerminal: true)
                        }
                        .frame(
                            minWidth: 72,
                            maxWidth: 180,
                            alignment: .leading
                        )
                        .accessibilityLabel("Tab name")
                } else {
                    Text(tab.name)
                        .foregroundColor(
                            foregroundColor.opacity(isSelected ? 1 : 0.78)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(tab.name)
                        .frame(
                            minWidth: 72,
                            maxWidth: 180,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            beginRename(tabID: tab.id)
                        }
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                guard editingTabID != tab.id else { return }
                                runtime.selectTab(tabID: tab.id)
                            }
                        )
                }
            }
            .font(.system(size: 12, weight: .regular))

            switch tab.kind {
            case .main:
                mainActivityIndicator
                    .frame(width: 14, height: 14)
            case .ide:
                EmptyView()
            case .shell, .managed:
                Button {
                    if tab.kind == .managed {
                        runtime.closeManagedTab(tabID: tab.id)
                    } else {
                        runtime.closeShellTab(tabID: tab.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundColor(foregroundColor.opacity(0.76))
                .opacity(isSelected || isHovered ? 1 : 0)
                .allowsHitTesting(isSelected || isHovered)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.name)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 33)
        .background {
            if isSelected {
                foregroundColor.opacity(0.13)
            } else if isHovered {
                foregroundColor.opacity(0.07)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(foregroundColor.opacity(0.12))
                .frame(width: 1)
        }
        .onHover { hovered in
            hoveredTabID = hovered ? tab.id : nil
        }
        .modifier(
            ShellTabDragModifier(
                tab: tab,
                runtimeID: runtime.id,
                draggedTabID: $draggedTabID
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-tabs.tab.\(tab.id)")
    }

    private var newTabButton: some View {
        Button {
            runtime.createShellTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(foregroundColor.opacity(0.84))
        .help("New Tab")
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier("terminal-tabs.add")
    }

    private var mainActivityIndicator: some View {
        ConversationIndicatorView(
            indicator: ConversationIndicator.resolve(
                activity: runtime.aggregateActivity,
                attention: nil
            ),
            spinnerTint: foregroundColor
        )
    }

    private var backgroundColor: Color {
        (
            ghosttyRuntime.themeColors.background?.swiftUIColor
                ?? Color(nsColor: .textBackgroundColor)
        ).opacity(
            min(
                max(ghosttyRuntime.themeColors.backgroundOpacity, 0),
                1
            )
        )
    }

    private var foregroundColor: Color {
        ghosttyRuntime.themeColors.foreground?.swiftUIColor
            ?? Color(nsColor: .labelColor)
    }

    private func beginRename(tabID: String) {
        guard let tab = runtime.tabs.first(where: { $0.id == tabID }),
              tab.kind != .ide else {
            return
        }
        runtime.selectTab(tabID: tabID)
        editingTabID = tabID
        renameText = tab.name
        DispatchQueue.main.async {
            focusedTabID = tabID
        }
    }

    private func commitRename(refocusTerminal: Bool) {
        guard let editingTabID else { return }
        self.editingTabID = nil
        focusedTabID = nil
        runtime.renameTab(tabID: editingTabID, to: renameText)
        if refocusTerminal {
            runtime.focusSelectedTab()
        }
    }

    private func cancelRename(refocusTerminal: Bool) {
        editingTabID = nil
        focusedTabID = nil
        if refocusTerminal {
            runtime.focusSelectedTab()
        }
    }
}

private struct ShellTabDragModifier: ViewModifier {
    let tab: ConversationTerminalTab
    let runtimeID: String
    @Binding var draggedTabID: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if tab.kind == .shell {
            content.onDrag {
                draggedTabID = tab.id
                return NSItemProvider(
                    item: "\(runtimeID):\(tab.id)" as NSString,
                    typeIdentifier: UTType.coinorTerminalTab.identifier
                )
            }
        } else {
            content
        }
    }
}

@MainActor
private struct TerminalTabDropDelegate: DropDelegate {
    let targetTabID: String?
    let runtime: ConversationRuntime
    @Binding var draggedTabID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedTabID,
              draggedTabID != targetTabID else {
            return
        }
        runtime.moveShellTab(
            tabID: draggedTabID,
            toward: targetTabID
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }
}

private extension GhosttyRGBColor {
    var swiftUIColor: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }
}
