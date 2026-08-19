import Foundation

/// Automation configuration mutations over the persisted metadata document.
///
/// These live on `MetadataDocument` so every change goes through the single
/// actor (`MetadataStore.update`) that owns atomic persistence, exactly like
/// the rest of Conan Code's organization state.
extension MetadataDocument {
    // MARK: - Shared system prompt

    var automationSystemPrompt: String {
        automation.settings?.systemPrompt ?? AutomationSettings.default.systemPrompt
    }

    mutating func setAutomationSystemPrompt(_ prompt: String) {
        var state = automation
        // Returning to the shipped default drops the override instead of
        // persisting a copy of it, keeping the document sparse.
        if prompt == AutomationSettings.default.systemPrompt {
            state.settings = nil
        } else {
            state.settings = AutomationSettings(systemPrompt: prompt)
        }
        automation = state
    }

    // MARK: - Automations

    /// Automations for display, ordered by name so the list is stable.
    var automationsOrdered: [Automation] {
        automation.automations.values.sorted {
            ($0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending)
                || ($0.name == $1.name && $0.id < $1.id)
        }
    }

    func automation(_ id: String) -> Automation? {
        automation.automations[id]
    }

    mutating func upsertAutomation(_ value: Automation) {
        var state = automation
        state.automations[value.id] = value
        automation = state
    }

    @discardableResult
    mutating func deleteAutomation(_ id: String) -> Automation? {
        var state = automation
        let removed = state.automations.removeValue(forKey: id)
        automation = state
        return removed
    }

    mutating func setAutomationPaused(_ id: String, paused: Bool) {
        guard var value = automation.automations[id] else { return }
        value.isPaused = paused
        upsertAutomation(value)
    }
}
