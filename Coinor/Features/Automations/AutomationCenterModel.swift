import Foundation
import SwiftUI

/// UI-facing state for the Automations feature.
///
/// Configuration lives in the shared metadata document (through
/// `AppCoordinator.persist`); scheduling lives in launchd. Every mutation
/// therefore does two things: persist the change, then reconcile the
/// automation's launchd job so what the user sees and what the system will
/// actually fire cannot drift apart.
@MainActor
final class AutomationCenterModel: ObservableObject {
    let coordinator: AppCoordinator

    @Published private(set) var errorMessage: String?
    @Published private(set) var runs: [AutomationRun] = []
    @Published private(set) var models: [GrokModelOption] = []
    /// Automations the user just asked to run, before their job has managed to
    /// append a run line. Without this the "Run Now" button would look inert
    /// for the second or two launchd takes to start the job.
    @Published private(set) var startingAutomationIDs: Set<String> = []

    private var installer: AutomationJobInstaller?
    private var pollTask: Task<Void, Never>?

    /// How often the run log is re-read while the tab is on screen. Runs are
    /// started by launchd out of process, so polling the log is what makes
    /// their progress visible.
    private static let pollInterval: Duration = .seconds(2)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Live state

    /// Whether this automation has a run in flight right now.
    func isRunning(_ automationID: String) -> Bool {
        if startingAutomationIDs.contains(automationID) { return true }
        return runs.contains {
            $0.automationID == automationID && $0.status == .running
        }
    }

    /// The most recent run of an automation, for the row's status line.
    func latestRun(for automationID: String) -> AutomationRun? {
        runs.first { $0.automationID == automationID }
    }

    /// Starts polling the run log while the Automations tab is visible.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AutomationCenterModel.pollInterval)
                guard !Task.isCancelled else { return }
                await self?.reloadRuns()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Derived configuration

    var automations: [Automation] {
        coordinator.metadata.automationsOrdered
    }

    var systemPrompt: String {
        coordinator.metadata.automationSystemPrompt
    }

    func automation(_ id: String) -> Automation? {
        coordinator.metadata.automation(id)
    }

    func runs(for automationID: String) -> [AutomationRun] {
        runs.filter { $0.automationID == automationID }
    }

    func projectName(for automation: Automation) -> String {
        guard !automation.workingDirectory.isEmpty else { return "No project" }
        return coordinator.projectDisplayName(
            coordinator.projectID(matchingWorkingDirectory: automation.workingDirectory)
        )
    }

    func projectSuggestions() -> [AutomationProjectSuggestion] {
        coordinator.catalog.projects.map { project in
            AutomationProjectSuggestion(
                id: project.projectID,
                name: coordinator.projectDisplayName(project.projectID),
                workingDirectory: coordinator.mainCheckout(for: project.projectID)
            )
        }
    }

    // MARK: - Lifecycle

    /// Loads the run history and the model list, and reconciles every launchd
    /// job with the stored configuration.
    func refresh() {
        guard let installer = resolveInstaller() else { return }
        reloadRuns()
        if models.isEmpty {
            let path = installer.grokExecutablePath
            Task.detached {
                let discovered = AutomationModelCatalog.available(
                    grokExecutablePath: path
                )
                await MainActor.run { self.models = discovered }
            }
        }
        installer.synchronize(
            automations: automations,
            systemPrompt: systemPrompt
        )
    }

    /// Re-reads the run log written by the launchd jobs.
    ///
    /// This is the only channel through which Conan Code learns that a run
    /// started or finished, because the runs happen in another process.
    func reloadRuns() {
        guard let installer = resolveInstaller() else { return }
        let loaded = AutomationRunLog.runs(at: installer.runLogURL)
        guard loaded != runs else { return }
        runs = loaded
        // Once a run has appeared in the log, the optimistic marker is no
        // longer needed for that automation.
        startingAutomationIDs = startingAutomationIDs.filter { id in
            !loaded.contains { $0.automationID == id }
        }
        coordinator.registerAutomationSessions(loaded)
        titleNewRuns(loaded)
    }

    /// Names each new run's conversation after its automation.
    ///
    /// `grok` titles the session from the prompt's contents, which makes an
    /// automation run indistinguishable from a hand-started conversation in
    /// the sidebar. Renaming happens once per run, so a title the user later
    /// changes by hand is never overwritten.
    private func titleNewRuns(_ loaded: [AutomationRun]) {
        let document = coordinator.metadata
        let pending = loaded.filter { run in
            run.sessionID != nil && !document.hasTitledAutomationRun(run.id)
        }
        guard !pending.isEmpty else { return }

        Task {
            for run in pending {
                guard let sessionID = run.sessionID,
                      let automation = coordinator.metadata.automation(run.automationID)
                else { continue }
                let renamed = await coordinator.titleAutomationRun(
                    sessionID: sessionID,
                    workingDirectory: automation.workingDirectory,
                    title: automation.name
                )
                guard renamed else { continue }
                await coordinator.persist(
                    { $0.markAutomationRunTitled(run.id) },
                    rebuildCatalog: false
                )
            }
        }
    }

    // MARK: - Mutations

    func saveAutomation(_ automation: Automation) {
        Task {
            await coordinator.persist { $0.upsertAutomation(automation) }
            applyJob(for: automation)
            refresh()
        }
    }

    func deleteAutomation(_ id: String) {
        Task {
            await coordinator.persist { _ = $0.deleteAutomation(id) }
            do {
                try resolveInstaller()?.remove(automationID: id)
            } catch {
                errorMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func setPaused(_ id: String, paused: Bool) {
        Task {
            await coordinator.persist { $0.setAutomationPaused(id, paused: paused) }
            if let automation = self.automation(id) {
                applyJob(for: automation)
            }
            refresh()
        }
    }

    func setSystemPrompt(_ prompt: String) {
        Task {
            await coordinator.persist { $0.setAutomationSystemPrompt(prompt) }
            // The shared instruction is baked into every job, so they all have
            // to be rewritten.
            resolveInstaller()?.synchronize(
                automations: automations,
                systemPrompt: prompt
            )
            refresh()
        }
    }

    /// Fires an automation immediately, independently of its schedule.
    func runNow(_ automationID: String) {
        guard let installer = resolveInstaller() else { return }
        do {
            // The job has to exist before it can be kickstarted; a paused or
            // never-installed automation is installed on demand.
            if let automation = automation(automationID), !automation.isPaused {
                try installer.install(
                    automation: automation,
                    systemPrompt: systemPrompt
                )
            }
            try installer.runNow(automationID: automationID)
            // Show the run as in flight straight away: launchd takes a moment
            // to start the job, and the log line only lands after that.
            startingAutomationIDs.insert(automationID)
            errorMessage = nil
            startPolling()
            Task {
                // Give the job time to append its first line, then reconcile.
                try? await Task.sleep(for: .seconds(1))
                reloadRuns()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Opens the conversation a run created, in the ordinary conversation
    /// view. The session is Grok's, so it behaves like any other.
    func openConversation(_ sessionID: String) {
        coordinator.selectConversation(sessionID)
    }

    // MARK: - Job plumbing

    private func applyJob(for automation: Automation) {
        guard let installer = resolveInstaller() else { return }
        do {
            try installer.install(
                automation: automation,
                systemPrompt: systemPrompt
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveInstaller() -> AutomationJobInstaller? {
        if let installer { return installer }
        guard let supportDirectory = try? CoinorRuntimeEnvironment
            .applicationSupportDirectory(),
            let executable = try? GrokExecutable.resolve() else {
            errorMessage = "Conan Code could not locate Grok, so automations "
                + "cannot be scheduled."
            return nil
        }
        let created = AutomationJobInstaller(
            launchAgentsDirectory: FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            supportDirectory: supportDirectory,
            grokExecutablePath: executable.path
        )
        installer = created
        return created
    }
}

/// A project a user can attach an automation to, resolved from the catalog.
struct AutomationProjectSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let workingDirectory: String
}
