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

    private var installer: AutomationJobInstaller?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
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
        runs = AutomationRunLog.runs(at: installer.runLogURL)
        coordinator.registerAutomationSessions(runs)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
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
