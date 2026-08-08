import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ConversationCommands: Commands {
    @ObservedObject var coordinator: AppCoordinator

    var body: some Commands {
        CommandMenu("Conversations") {
            Button("Previous Conversation") {
                coordinator.navigateConversation(.previous)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Next Conversation") {
                coordinator.navigateConversation(.next)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}

struct TerminalTabCommands: Commands {
    @ObservedObject var coordinator: AppCoordinator

    var body: some Commands {
        CommandMenu("Tabs") {
            Button("New Tab") {
                coordinator.createTerminalTab()
            }

            Button("Close Tab") {
                coordinator.closeSelectedTerminalTab()
            }

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Select Last Tab" : "Select Tab \(number)") {
                    coordinator.selectTerminalTab(number: number)
                }
            }
        }
    }
}

struct TerminalTabShortcutMonitor: NSViewRepresentable {
    let coordinator: AppCoordinator

    func makeNSView(context: Context) -> TerminalTabShortcutView {
        TerminalTabShortcutView(coordinator: coordinator)
    }

    func updateNSView(
        _ nsView: TerminalTabShortcutView,
        context: Context
    ) {
        nsView.coordinator = coordinator
    }

    static func dismantleNSView(
        _ nsView: TerminalTabShortcutView,
        coordinator: ()
    ) {
        nsView.removeMonitor()
    }
}

enum ConversationNavigationShortcut {
    static func direction(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags
    ) -> SidebarConversationNavigation.Direction? {
        var modifiers = eventModifiers.intersection(
            .deviceIndependentFlagsMask
        )
        modifiers.remove([.capsLock, .numericPad, .function])
        guard modifiers == [.command, .option] else { return nil }

        switch Int(keyCode) {
        case kVK_UpArrow:
            return .previous
        case kVK_DownArrow:
            return .next
        default:
            return nil
        }
    }
}

@MainActor
final class TerminalTabShortcutView: NSView {
    var coordinator: AppCoordinator
    private var eventMonitor: Any?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let monitoredWindow = window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self, weak monitoredWindow] event in
            let handled = MainActor.assumeIsolated {
                guard let self,
                      let monitoredWindow,
                      event.window === monitoredWindow else {
                    return false
                }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeMonitor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        if let direction = ConversationNavigationShortcut.direction(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
            return coordinator.navigateConversation(direction)
        }

        guard !event.isARepeat else { return false }
        var modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        modifiers.remove([.capsLock, .numericPad])
        guard modifiers == .command,
              let characters = event.charactersIgnoringModifiers?
                  .lowercased() else {
            return false
        }
        switch characters {
        case "t":
            return coordinator.createTerminalTab()
        case "w":
            return coordinator.closeSelectedTerminalTab()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard let number = Int(characters) else { return false }
            return coordinator.selectTerminalTab(number: number)
        default:
            return false
        }
    }
}
