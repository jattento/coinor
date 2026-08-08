import SwiftUI

@MainActor
final class CoinorApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?
    private var terminationInProgress = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let coordinator else {
            return .terminateNow
        }
        guard !terminationInProgress else {
            return .terminateLater
        }
        terminationInProgress = true
        Task {
            await coordinator.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CoinorApp: App {
    @NSApplicationDelegateAdaptor(CoinorApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var shell = AppShellModel(environment: .live())
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        Window("Conan Code", id: "coinor.main") {
            AppShellView(model: shell, coordinator: coordinator)
                .onAppear {
                    applicationDelegate.coordinator = coordinator
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            TerminalTabCommands(coordinator: coordinator)
        }
    }
}
