import Foundation
import Testing

@testable import Coinor

/// Captures the `launchctl` invocations instead of registering real jobs.
private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock()
        invocations.append(arguments)
        lock.unlock()
    }

    var recorded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    var operations: [String] {
        recorded.compactMap(\.first)
    }
}

private struct Harness {
    let directory: URL
    let launchAgents: URL
    let support: URL
    let recorder: LaunchctlRecorder
    let installer: AutomationJobInstaller

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationInstaller-\(UUID().uuidString)", isDirectory: true)
        launchAgents = directory.appendingPathComponent("LaunchAgents", isDirectory: true)
        support = directory.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let recorder = LaunchctlRecorder()
        self.recorder = recorder
        installer = AutomationJobInstaller(
            launchAgentsDirectory: launchAgents,
            supportDirectory: support,
            grokExecutablePath: "/Users/me/bin/grok",
            runLaunchctl: { recorder.record($0) }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func automation(
    id: String = "auto-1",
    paused: Bool = false,
    workingDirectory: String = "/tmp/project",
    prompt: String = "do it"
) -> Automation {
    Automation(
        id: id,
        name: "Test",
        schedule: "0 9 * * *",
        workingDirectory: workingDirectory,
        prompt: prompt,
        isPaused: paused
    )
}

// MARK: - Install

@Test
func installWritesThePlistAndBootstrapsIt() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(
        automation: automation(),
        systemPrompt: "policy"
    )

    let plistURL = harness.installer.plistURL(for: "auto-1")
    #expect(FileManager.default.fileExists(atPath: plistURL.path))

    // The written file is a real launchd job for this automation.
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
    ) as? [String: Any]
    #expect(plist?["Label"] as? String == AutomationJob.label(for: "auto-1"))

    // It replaces any prior definition, then loads the new one.
    #expect(harness.recorder.operations == ["bootout", "bootstrap"])
    #expect(harness.recorder.recorded.last?.contains(plistURL.path) == true)
}

/// Reinstalling an unchanged job would `bootout` it, and launchd kills
/// whatever that job is running, so an in-flight automation run would be
/// aborted by nothing more than a UI refresh.
@Test
func reinstallingAnUnchangedLoadedJobLeavesLaunchdAlone() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(automation: automation(), systemPrompt: "policy")
    try harness.installer.install(automation: automation(), systemPrompt: "policy")

    // Only the first install touched launchd; the second merely checked that
    // the job is still loaded.
    #expect(harness.recorder.operations == ["bootout", "bootstrap", "print"])
}

@Test
func installingAChangedDefinitionReloadsTheJob() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(automation: automation(), systemPrompt: "policy")
    try harness.installer.install(
        automation: automation(prompt: "do something else"),
        systemPrompt: "policy"
    )

    #expect(harness.recorder.operations == [
        "bootout", "bootstrap", "bootout", "bootstrap",
    ])
}

/// An unchanged plist that launchd does not know about still has to be
/// bootstrapped, otherwise the automation would never fire again.
@Test
func anUnchangedButUnloadedJobIsBootstrapped() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(automation: automation(), systemPrompt: "policy")

    struct NotLoaded: Error {}
    let recorder = LaunchctlRecorder()
    let installer = AutomationJobInstaller(
        launchAgentsDirectory: harness.launchAgents,
        supportDirectory: harness.support,
        grokExecutablePath: "/Users/me/bin/grok",
        runLaunchctl: { arguments in
            recorder.record(arguments)
            if arguments.first == "print" { throw NotLoaded() }
        }
    )
    try installer.install(automation: automation(), systemPrompt: "policy")

    #expect(recorder.operations == ["print", "bootout", "bootstrap"])
}

@Test
func installingAPausedAutomationUnloadsItInsteadOfScheduling() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(
        automation: automation(paused: true),
        systemPrompt: "policy"
    )

    // A paused automation must never be bootstrapped, otherwise launchd would
    // still fire it (and catch it up on wake).
    #expect(harness.recorder.operations == ["bootout"])
    #expect(!harness.recorder.operations.contains("bootstrap"))
}

@Test
func anIncompleteAutomationIsNotScheduled() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    // No project chosen yet.
    try harness.installer.install(
        automation: automation(workingDirectory: ""),
        systemPrompt: "policy"
    )
    #expect(!harness.recorder.operations.contains("bootstrap"))
    #expect(!FileManager.default.fileExists(
        atPath: harness.installer.plistURL(for: "auto-1").path
    ))
}

// MARK: - Remove

@Test
func removeUnloadsAndDeletesThePlist() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(automation: automation(), systemPrompt: "p")
    let plistURL = harness.installer.plistURL(for: "auto-1")
    #expect(FileManager.default.fileExists(atPath: plistURL.path))

    try harness.installer.remove(automationID: "auto-1")
    #expect(!FileManager.default.fileExists(atPath: plistURL.path))
    #expect(harness.recorder.operations.contains("bootout"))
}

// MARK: - Run now

@Test
func runNowKickstartsTheJob() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.runNow(automationID: "auto-1")

    let invocation = try #require(harness.recorder.recorded.last)
    #expect(invocation.first == "kickstart")
    // -k restarts the job even if a previous run is still going.
    #expect(invocation.contains("-k"))
    #expect(invocation.last?.hasSuffix(AutomationJob.label(for: "auto-1")) == true)

    // A marker is left so the job records this run as manual rather than
    // scheduled; launchd starts both the same way.
    let marker = AutomationJob.forcedMarkerPath(
        runLogPath: harness.installer.runLogURL.path,
        automationID: "auto-1"
    )
    #expect(FileManager.default.fileExists(atPath: marker))
}

/// A failed kickstart must not leave a marker behind, or the next scheduled
/// run would be mislabelled as manual.
@Test
func aFailedRunNowRemovesItsMarker() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationMarker-\(UUID().uuidString)", isDirectory: true)
    let launchAgents = directory.appendingPathComponent("LaunchAgents", isDirectory: true)
    let support = directory.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    struct Boom: Error {}
    let installer = AutomationJobInstaller(
        launchAgentsDirectory: launchAgents,
        supportDirectory: support,
        grokExecutablePath: "/Users/me/bin/grok",
        runLaunchctl: { _ in throw Boom() }
    )

    #expect(throws: (any Error).self) {
        try installer.runNow(automationID: "auto-1")
    }
    let marker = AutomationJob.forcedMarkerPath(
        runLogPath: installer.runLogURL.path,
        automationID: "auto-1"
    )
    #expect(!FileManager.default.fileExists(atPath: marker))
}

/// The generated job must consume the marker, so a forced run is recorded as
/// manual exactly once and the next scheduled run is not.
@Test
func theJobConsumesTheForcedMarker() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    let script = AutomationJob.script(
        automation: automation(),
        systemPrompt: "policy",
        grokExecutablePath: "/usr/bin/true",
        runLogPath: harness.installer.runLogURL.path
    )
    #expect(script.contains("trigger=forced"))
    #expect(script.contains("trigger=scheduled"))
    #expect(script.contains("/bin/rm -f \"$marker\""))
}

// MARK: - Synchronise

@Test
func synchronizeRemovesJobsForDeletedAutomations() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    try harness.installer.install(automation: automation(id: "keep"), systemPrompt: "p")
    try harness.installer.install(automation: automation(id: "drop"), systemPrompt: "p")
    #expect(FileManager.default.fileExists(
        atPath: harness.installer.plistURL(for: "drop").path
    ))

    // "drop" is no longer configured.
    harness.installer.synchronize(
        automations: [automation(id: "keep")],
        systemPrompt: "p"
    )

    #expect(FileManager.default.fileExists(
        atPath: harness.installer.plistURL(for: "keep").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: harness.installer.plistURL(for: "drop").path
    ))
}

@Test
func synchronizeLeavesUnrelatedFilesAlone() throws {
    let harness = try Harness()
    defer { harness.cleanUp() }

    // Another application's LaunchAgent must never be touched.
    let foreign = harness.launchAgents
        .appendingPathComponent("com.example.other.plist")
    try Data("x".utf8).write(to: foreign)

    harness.installer.synchronize(automations: [], systemPrompt: "p")

    #expect(FileManager.default.fileExists(atPath: foreign.path))
}
