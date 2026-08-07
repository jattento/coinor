import Foundation

/// View state for the application shell.
@MainActor
final class AppShellModel: ObservableObject {
    @Published private(set) var startupChecks: [StartupCheck] = StartupCheck.allPending
    @Published private(set) var isRunningStartupChecks = false

    private let diagnostics: any StartupDiagnosticsProviding

    init(environment: AppEnvironment) {
        diagnostics = environment.startupDiagnostics
    }

    var unresolvedStartupCheckCount: Int {
        startupChecks.filter { $0.status == .failed || $0.status == .warning }.count
    }

    func runStartupChecks() async {
        guard !isRunningStartupChecks else { return }
        isRunningStartupChecks = true
        defer { isRunningStartupChecks = false }
        startupChecks = await diagnostics.runStartupChecks()
    }
}
