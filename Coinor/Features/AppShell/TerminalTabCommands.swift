import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ConversationCommands: Commands {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var activityStack: ActivityStackModel

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

            Divider()

            Button(
                activityStack.isPresented
                    ? "Close Activity Stack"
                    : "Open Activity Stack"
            ) {
                activityStack.togglePresented()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
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
    let activityStack: ActivityStackModel

    func makeNSView(context: Context) -> TerminalTabShortcutView {
        TerminalTabShortcutView(
            coordinator: coordinator,
            activityStack: activityStack
        )
    }

    func updateNSView(
        _ nsView: TerminalTabShortcutView,
        context: Context
    ) {
        nsView.coordinator = coordinator
        nsView.activityStack = activityStack
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
    var activityStack: ActivityStackModel
    private var eventMonitor: Any?

    init(coordinator: AppCoordinator, activityStack: ActivityStackModel) {
        self.coordinator = coordinator
        self.activityStack = activityStack
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

        guard let characters = event.charactersIgnoringModifiers?
            .lowercased() else {
            return false
        }

        if modifiers == [.command, .shift], characters == "a" {
            return activityStack.togglePresented()
        }

        guard modifiers == .command else { return false }

        if activityStack.isPresented, let focusedID = activityStack.focusedID {
            switch characters {
            case "d":
                activityStack.dismissOrCloseFocused()
                return true
            case "s":
                activityStack.pushToEnd(focusedID)
                return true
            case "m":
                activityStack.mute(focusedID)
                return true
            default:
                break
            }
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
