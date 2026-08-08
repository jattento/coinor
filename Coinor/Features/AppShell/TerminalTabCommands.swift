import AppKit
import SwiftUI

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

    private func handle(_ event: NSEvent) -> Bool {
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
