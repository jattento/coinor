import Foundation
import Testing

@testable import Coinor

/// End-to-end against the real launchd, opt-in through
/// `COINOR_RUN_LIVE_LAUNCHD=1` the same way the live Grok finder test is
/// gated. It proves the whole scheduling path Conan Code ships:
///
/// 1. `AutomationJobInstaller` writes a job built by `AutomationJob` and
///    bootstraps it into the user's launchd domain,
/// 2. `launchctl kickstart` (the "Run Now" control) actually starts it,
/// 3. the job's shell records the run in the log, and
/// 4. `AutomationRunLog` reads that run back with its session ID.
///
/// A stub stands in for `grok` so the test stays fast and offline; that the
/// real `grok` runs a full agentic turn from this command line is verified
/// separately.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "COINOR_RUN_LIVE_LAUNCHD"
        ] == "1"
    ),
    .timeLimit(.minutes(5))
)
func liveLaunchdJobRunsAnAutomationAndRecordsIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchdLive-\(UUID().uuidString)", isDirectory: true)
    let launchAgents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    for directory in [launchAgents, support, project] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // A stub `grok` that records the argv it was invoked with.
    let argvDump = support.appendingPathComponent("argv.txt")
    let stub = root.appendingPathComponent("grok-stub")
    try """
    #!/bin/sh
    : > \(argvDump.path)
    for arg in "$@"; do printf '%s\\n' "$arg" >> \(argvDump.path); done
    exit 0
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: stub.path
    )

    let installer = AutomationJobInstaller(
        launchAgentsDirectory: launchAgents,
        supportDirectory: support,
        grokExecutablePath: stub.path
    )
    // A schedule far in the future: the run must come from "Run Now", never
    // from the calendar, so the test cannot pass by accident.
    let automation = Automation(
        id: "live-\(UUID().uuidString)",
        name: "Live smoke",
        schedule: "0 4 1 1 *",
        workingDirectory: project.path,
        prompt: "smoke prompt",
        model: "grok-4.6"
    )

    defer {
        try? installer.remove(automationID: automation.id)
        try? FileManager.default.removeItem(at: root)
    }

    try installer.install(automation: automation, systemPrompt: "LIVE POLICY")

    // launchd now owns the job.
    let label = AutomationJob.label(for: automation.id)
    #expect(loadedLabels().contains(label))

    // "Run Now".
    try installer.runNow(automationID: automation.id)

    // Wait for the job's shell to finish writing both log lines.
    var runs: [AutomationRun] = []
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        runs = AutomationRunLog.runs(at: installer.runLogURL)
        if runs.first?.finishedAt != nil { break }
        try await Task.sleep(for: .milliseconds(250))
    }

    let run = try #require(runs.first, "the job never recorded a run")
    #expect(run.automationID == automation.id)
    #expect(run.status == .succeeded)
    #expect(run.finishedAt != nil)
    let sessionID = try #require(run.sessionID)
    #expect(UUID(uuidString: sessionID) != nil, "a real session UUID is minted")

    // grok was invoked with the automation's configuration.
    let argv = try String(contentsOf: argvDump, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(argv.contains("--cwd"))
    #expect(argv.contains(project.path))
    #expect(argv.contains("--always-approve"))
    #expect(argv.contains("-p"))
    #expect(argv.contains("smoke prompt"))
    #expect(argv.contains("LIVE POLICY"))
    #expect(argv.contains("--model"))
    #expect(argv.contains("grok-4.6"))
    // The session ID handed to grok is the one recorded for the run, which is
    // what lets the sidebar badge that conversation.
    #expect(argv.contains(sessionID))

    // Removing the automation unloads the job.
    try installer.remove(automationID: automation.id)
    #expect(!loadedLabels().contains(label))
}

/// The labels currently loaded in this user's launchd domain.
private func loadedLabels() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "" }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
