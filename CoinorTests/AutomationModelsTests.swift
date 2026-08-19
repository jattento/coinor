import Foundation
import Testing

@testable import Coinor

// MARK: - Automation configuration CRUD

@Test
func upsertAndFetchAutomation() {
    var document = MetadataDocument.empty
    var automation = Automation(
        name: "Nightly tests",
        schedule: "0 2 * * *",
        workingDirectory: "/tmp/Proj",
        prompt: "Run the suite",
        model: "grok-4.6"
    )
    let id = automation.id
    document.upsertAutomation(automation)
    #expect(document.automation(id) == automation)

    automation.name = "Nightly tests v2"
    document.upsertAutomation(automation)
    #expect(document.automation(id)?.name == "Nightly tests v2")
    #expect(document.automationsOrdered.count == 1)
}

@Test
func deleteAutomationRemovesIt() {
    var document = MetadataDocument.empty
    let automation = Automation(
        name: "A",
        schedule: "* * * * *",
        workingDirectory: "/tmp",
        prompt: "p"
    )
    document.upsertAutomation(automation)

    let removed = document.deleteAutomation(automation.id)
    #expect(removed == automation)
    #expect(document.automation(automation.id) == nil)
    #expect(document.automationsOrdered.isEmpty)
}

@Test
func pauseSetsFlag() {
    var document = MetadataDocument.empty
    let automation = Automation(
        name: "A",
        schedule: "* * * * *",
        workingDirectory: "/tmp",
        prompt: "p"
    )
    document.upsertAutomation(automation)
    document.setAutomationPaused(automation.id, paused: true)
    #expect(document.automation(automation.id)?.isPaused == true)
    document.setAutomationPaused(automation.id, paused: false)
    #expect(document.automation(automation.id)?.isPaused == false)
}

@Test
func automationsAreOrderedByName() {
    var document = MetadataDocument.empty
    for name in ["zeta", "alpha", "Mike"] {
        document.upsertAutomation(
            Automation(name: name, schedule: "* * * * *")
        )
    }
    #expect(document.automationsOrdered.map(\.name) == ["alpha", "Mike", "zeta"])
}

// MARK: - Shared system prompt

@Test
func defaultSystemPromptIsUsedUntilOverridden() {
    var document = MetadataDocument.empty
    #expect(document.automationSystemPrompt == AutomationSettings.default.systemPrompt)

    document.setAutomationSystemPrompt("custom prompt")
    #expect(document.automationSystemPrompt == "custom prompt")

    // Restoring the default drops the override rather than storing a copy.
    document.setAutomationSystemPrompt(AutomationSettings.default.systemPrompt)
    #expect(document.automation.settings == nil)
    #expect(document.automationSystemPrompt == AutomationSettings.default.systemPrompt)
}

@Test
func defaultSystemPromptForbidsAskingTheUser() {
    let text = AutomationSettings.default.systemPrompt.lowercased()
    #expect(text.contains("automat"))
    #expect(text.contains("clarification"))
}

// MARK: - Run titling bookkeeping

@Test
func aRunIsOnlyTitledOnce() {
    var document = MetadataDocument.empty
    #expect(!document.hasTitledAutomationRun("run-1"))

    document.markAutomationRunTitled("run-1")
    #expect(document.hasTitledAutomationRun("run-1"))

    // Marking again must not duplicate the entry, so a manual rename later is
    // never overwritten by a second titling pass.
    document.markAutomationRunTitled("run-1")
    #expect(document.automation.titledRunIDs == ["run-1"])
}

@Test
func titledRunHistoryIsPruned() {
    var document = MetadataDocument.empty
    let limit = AutomationState.titledRunHistoryLimit
    for index in 0..<(limit + 25) {
        document.markAutomationRunTitled("run-\(index)")
    }
    let stored = document.automation.titledRunIDs
    #expect(stored.count == limit)
    // The oldest entries are dropped, the newest kept.
    #expect(stored.last == "run-\(limit + 24)")
    #expect(!stored.contains("run-0"))
}

@Test
func titledRunsSurviveRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationTitled-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        let store = try MetadataStore(directoryURL: directory)
        try await store.update { $0.markAutomationRunTitled("run-7") }
    }

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument
    #expect(document.hasTitledAutomationRun("run-7"))
}

/// An automation slice written before run titling existed must still decode.
@Test
func automationStateWithoutTitledRunsDecodes() throws {
    let json = #"{"automations":{}}"#
    let state = try JSONDecoder().decode(
        AutomationState.self,
        from: Data(json.utf8)
    )
    #expect(state.titledRunIDs.isEmpty)
    #expect(state.automations.isEmpty)
}

// MARK: - Persistence round trip

@Test
func automationConfigurationPersistsAcrossRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let automation = Automation(
        name: "Daily",
        schedule: "0 9 * * *",
        workingDirectory: "/tmp/Proj",
        prompt: "do the thing",
        model: "claude-opus-5"
    )
    do {
        let store = try MetadataStore(directoryURL: directory)
        try await store.update { document in
            document.setAutomationSystemPrompt("cron preamble")
            document.upsertAutomation(automation)
        }
    }

    // Re-open from disk: this is the relaunch path.
    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument
    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.automationSystemPrompt == "cron preamble")

    let restored = try #require(document.automation(automation.id))
    #expect(restored == automation)
    #expect(restored.model == "claude-opus-5")
}

/// A document written before automations existed (schema 6, no `automation`
/// key) must still load and migrate rather than failing the app launch.
@Test
func documentFromAnOlderSchemaMigratesToCurrent() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacy = """
    {
      "schemaVersion": 6,
      "sessions": {},
      "projects": {},
      "remoteHostAliases": [],
      "remoteProjectsHidden": false,
      "pinnedSessionIDs": [],
      "projectOrder": []
    }
    """
    try Data(legacy.utf8).write(
        to: directory.appendingPathComponent(MetadataStore.fileName)
    )

    let store = try MetadataStore(directoryURL: directory)
    let document = await store.currentDocument
    #expect(document.schemaVersion == MetadataSchema.currentVersion)
    #expect(document.automationsOrdered.isEmpty)
    #expect(document.automationSystemPrompt == AutomationSettings.default.systemPrompt)
}

/// An automation stored before the model field existed must decode with no
/// model rather than failing.
@Test
func automationWithoutAModelDecodes() throws {
    let json = """
    {"id":"a1","name":"Legacy","schedule":"0 9 * * *",
     "workingDirectory":"/tmp","prompt":"p","isPaused":false}
    """
    let automation = try JSONDecoder().decode(
        Automation.self,
        from: Data(json.utf8)
    )
    #expect(automation.model == nil)
    #expect(automation.name == "Legacy")
}

/// An empty automation slice must not be written, keeping the document sparse
/// for installs that never use the feature.
@Test
func emptyAutomationStateIsNotEncoded() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationSparseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try MetadataStore(directoryURL: directory)
    try await store.update { $0.pin("session-a") }

    let data = try Data(
        contentsOf: directory.appendingPathComponent(MetadataStore.fileName)
    )
    #expect(!String(decoding: data, as: UTF8.self).contains("\"automation\""))
}
