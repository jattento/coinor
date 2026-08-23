import Foundation

/// View state for the application shell.
@MainActor
final class AppShellModel: ObservableObject {
    @Published private(set) var startupChecks: [StartupCheck] = StartupCheck.allPending
    @Published private(set) var isRunningStartupChecks = false
    @Published private(set) var availableGrokRelease: GrokRelease?
    @Published private(set) var missingUpstreamGrokCommits: GrokUpstreamSyncStatus?

    private let diagnostics: any StartupDiagnosticsProviding
    private let grokUpdateChecker: any GrokUpdateChecking
    private let grokUpstreamSyncChecker: any GrokUpstreamSyncChecking
    let changelogLoader: any GrokChangelogLoading

    init(environment: AppEnvironment) {
        diagnostics = environment.startupDiagnostics
        grokUpdateChecker = environment.grokUpdateChecker
        grokUpstreamSyncChecker = environment.grokUpstreamSyncChecker
        changelogLoader = environment.grokChangelogLoader
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

    func checkForGrokUpdate() async {
        do {
            availableGrokRelease = try await grokUpdateChecker
                .availableUpdate()
        } catch {
            // Update availability is advisory. Keep the last successful state.
        }
    }

    func checkForMissingUpstreamGrokCommits() async {
        do {
            missingUpstreamGrokCommits = try await grokUpstreamSyncChecker
                .missingUpstreamCommits()
        } catch {
            // Sync status is advisory. Keep the last successful state.
        }
    }

    func monitorGrokUpdates() async {
        while !Task.isCancelled {
            await checkForGrokUpdate()
            await checkForMissingUpstreamGrokCommits()
            do {
                try await Task.sleep(for: .seconds(21_600))
            } catch {
                return
            }
        }
    }
}
