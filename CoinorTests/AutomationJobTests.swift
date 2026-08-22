import Foundation
import Testing

@testable import Coinor

// MARK: - Cron -> launchd calendar intervals

private func intervals(_ expression: String) throws -> [CronLaunchdCompiler.Interval] {
    try CronLaunchdCompiler.intervals(for: try CronSchedule.parse(expression))
}

@Test
func everyMinuteCompilesToASingleWildcardEntry() throws {
    // Every field is a wildcard, so launchd needs one entry with no keys,
    // which it fires every minute.
    let compiled = try intervals("* * * * *")
    #expect(compiled == [CronLaunchdCompiler.Interval()])
    #expect(compiled[0].plistValue.isEmpty)
}

@Test
func dailyScheduleCompilesToOneEntry() throws {
    let compiled = try intervals("0 9 * * *")
    #expect(compiled.count == 1)
    #expect(compiled[0].plistValue == ["Minute": 0, "Hour": 9])
}

@Test
func stepScheduleCompilesToOneEntryPerOccurrence() throws {
    let compiled = try intervals("*/15 * * * *")
    #expect(compiled.map { $0.plistValue["Minute"] } == [0, 15, 30, 45])
    // The hour stays wildcard, so it is omitted entirely.
    #expect(compiled.allSatisfy { $0.plistValue["Hour"] == nil })
}

@Test
func weekdayRangeCompilesToOneEntryPerDay() throws {
    let compiled = try intervals("0 9 * * MON-FRI")
    #expect(compiled.count == 5)
    #expect(compiled.map { $0.plistValue["Weekday"] } == [1, 2, 3, 4, 5])
    #expect(compiled.allSatisfy { $0.plistValue["Hour"] == 9 })
    #expect(compiled.allSatisfy { $0.plistValue["Minute"] == 0 })
}

@Test
func sundaySevenIsNormalisedToZeroWithoutDuplicating() throws {
    // Cron accepts both 0 and 7 for Sunday; launchd should get one entry.
    let compiled = try intervals("0 0 * * 0,7")
    #expect(compiled.count == 1)
    #expect(compiled[0].plistValue["Weekday"] == 0)
}

@Test
func combinedFieldsProduceTheCartesianProduct() throws {
    // 2 minutes x 2 hours = 4 entries.
    let compiled = try intervals("0,30 9,17 * * *")
    #expect(compiled.count == 4)
    let pairs = Set(compiled.map { [$0.plistValue["Hour"]!, $0.plistValue["Minute"]!] })
    #expect(pairs == [[9, 0], [9, 30], [17, 0], [17, 30]])
}

@Test
func anExplosiveScheduleIsRejectedRatherThanHandedToLaunchd() {
    // */1 over every minute AND every hour AND every weekday would expand far
    // past the limit once several fields are constrained.
    #expect(throws: (any Error).self) {
        _ = try intervals("*/2 9-17 1-28 * 1-5")
    }
}

@Test
func rejectedScheduleReportsItsSize() throws {
    let schedule = try CronSchedule.parse("*/2 9-17 1-28 * 1-5")
    do {
        _ = try CronLaunchdCompiler.intervals(for: schedule)
        Issue.record("expected the compiler to reject this schedule")
    } catch let error as CronLaunchdCompiler.CompileError {
        guard case let .tooManyIntervals(count, limit) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
        #expect(count > limit)
        #expect(limit == CronLaunchdCompiler.intervalLimit)
    }
}

// MARK: - The launchd job definition

private func sampleAutomation(
    model: String? = nil,
    reasoningEffort: AutomationReasoningEffort? = nil,
    prompt: String = "review open PRs",
    schedule: String = "0 9 * * *"
) -> Automation {
    Automation(
        id: "11111111-2222-3333-4444-555555555555",
        name: "Nightly review",
        schedule: schedule,
        workingDirectory: "/Users/me/project",
        prompt: prompt,
        model: model,
        reasoningEffort: reasoningEffort
    )
}

private func definition(
    _ automation: Automation,
    systemPrompt: String = "Do not ask the user."
) throws -> [String: Any] {
    try AutomationJob.definition(
        automation: automation,
        systemPrompt: systemPrompt,
        grokExecutablePath: "/Users/me/bin/grok",
        runLogPath: "/Users/me/Library/Application Support/Coinor/automation-runs.ndjson",
        logPath: "/Users/me/Library/Logs/coinor.automation.log"
    )
}

@Test
func jobIsLabelledPerAutomationAndDoesNotRunAtLoad() throws {
    let automation = sampleAutomation()
    let job = try definition(automation)

    #expect(job["Label"] as? String == AutomationJob.label(for: automation.id))
    // Installing or editing an automation must never fire it immediately.
    #expect(job["RunAtLoad"] as? Bool == false)
    #expect(job["ProcessType"] as? String == "Background")
}

@Test
func jobCarriesTheCompiledSchedule() throws {
    let job = try definition(sampleAutomation(schedule: "*/15 * * * *"))
    let intervals = try #require(job["StartCalendarInterval"] as? [[String: Int]])
    #expect(intervals.count == 4)
    #expect(intervals.map { $0["Minute"] } == [0, 15, 30, 45])
}

@Test
func jobInvokesGrokHeadlesslyWithTheAutomationSettings() throws {
    let automation = sampleAutomation()
    let job = try definition(automation, systemPrompt: "AUTOMATION POLICY")
    let arguments = try #require(job["ProgramArguments"] as? [String])
    #expect(arguments.count == 3)
    #expect(arguments[0] == "/bin/sh")
    let script = arguments[2]

    // Headless single user turn (the agent still runs its full loop).
    #expect(script.contains("-p 'review open PRs'"))
    // Unattended: never blocks on a permission prompt.
    #expect(script.contains("--always-approve"))
    // The shared instruction is appended to Grok's system prompt.
    #expect(script.contains("--rules 'AUTOMATION POLICY'"))
    // Runs in the automation's project.
    #expect(script.contains("--cwd '/Users/me/project'"))
    // Uses the resolved Grok executable.
    #expect(script.contains("'/Users/me/bin/grok'"))
    // Mints a fresh session per run rather than reusing one.
    #expect(script.contains("--session-id \"$session_id\""))
    #expect(script.contains("uuidgen"))
}

/// The logical command line, independent of shell rendering.
@Test
func grokTokensCarryTheAutomationConfiguration() {
    let tokens = AutomationJob.grokTokens(
        automation: sampleAutomation(model: "grok-4.6"),
        systemPrompt: "policy"
    )
    #expect(tokens.contains(.flag("--always-approve")))
    #expect(tokens.contains(.flag("-p")))
    #expect(tokens.contains(.value("review open PRs")))
    #expect(tokens.contains(.value("policy")))
    #expect(tokens.contains(.value("grok-4.6")))
    #expect(tokens.contains(.sessionID))
}

/// A prompt that begins with a dash must still be passed as a value, never
/// mistaken for a flag.
@Test
func aPromptStartingWithADashIsTreatedAsAValue() {
    let script = AutomationJob.grokCommand(
        automation: sampleAutomation(prompt: "--version"),
        systemPrompt: "policy",
        grokExecutablePath: "/Users/me/bin/grok"
    )
    // Quoted, so grok receives it as the prompt rather than as its own flag.
    #expect(script.hasSuffix("-p '--version'"))
}

@Test
func jobPinsTheModelOnlyWhenOneIsChosen() throws {
    let withModel = try definition(sampleAutomation(model: "grok-4.6"))
    let withModelScript = try #require(withModel["ProgramArguments"] as? [String])[2]
    #expect(withModelScript.contains("--model 'grok-4.6'"))

    let withoutModel = try definition(sampleAutomation(model: nil))
    let withoutModelScript = try #require(withoutModel["ProgramArguments"] as? [String])[2]
    // No model pinned: Grok's own default is used.
    #expect(!withoutModelScript.contains("--model"))
}

@Test
func jobPassesTheReasoningEffortOnlyWhenOneIsChosen() throws {
    let withEffort = try definition(sampleAutomation(reasoningEffort: .high))
    let withEffortScript = try #require(withEffort["ProgramArguments"] as? [String])[2]
    #expect(withEffortScript.contains("--reasoning-effort 'high'"))

    let withoutEffort = try definition(sampleAutomation(reasoningEffort: nil))
    let withoutEffortScript = try #require(withoutEffort["ProgramArguments"] as? [String])[2]
    // No effort chosen: the model's own default applies.
    #expect(!withoutEffortScript.contains("--reasoning-effort"))
}

@Test
func jobRecordsRunsAndNotifiesOnCompletion() throws {
    let job = try definition(sampleAutomation())
    let script = (job["ProgramArguments"] as! [String])[2]

    // Appends a start and an end record to the run log.
    #expect(script.contains("automation-runs.ndjson"))
    #expect(script.contains("\"status\":\"running\""))
    #expect(script.contains("startedAt"))
    #expect(script.contains("finishedAt"))
    #expect(script.contains("succeeded"))
    #expect(script.contains("failed"))
    // Raises a native notification when it settles.
    #expect(script.contains("osascript"))
    #expect(script.contains("display notification"))
}

/// A prompt containing shell metacharacters must not be able to break out of
/// its argument and run arbitrary commands.
@Test
func aPromptWithShellMetacharactersCannotEscapeItsArgument() throws {
    let hostile = "'; touch /tmp/pwned; echo '"
    let job = try definition(sampleAutomation(prompt: hostile))
    let script = try #require(job["ProgramArguments"] as? [String])[2]

    // The payload appears only in its fully escaped, single-quoted form, so
    // the shell reads it as one argument instead of as commands.
    #expect(script.contains(AutomationJob.shellQuoted(hostile)))
    #expect(!script.contains("' ; touch"))

    // Proven by execution, not by inspection: run the generated script with a
    // stub "grok" that records its argv, and confirm the injected command
    // never ran and the prompt arrived intact as a single argument.
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("JobInjection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let marker = sandbox.appendingPathComponent("pwned")
    let argvDump = sandbox.appendingPathComponent("argv.txt")
    let stub = sandbox.appendingPathComponent("grok-stub")
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

    var automation = sampleAutomation(prompt: hostile.replacingOccurrences(
        of: "/tmp/pwned",
        with: marker.path
    ))
    automation.workingDirectory = sandbox.path
    let program = AutomationJob.script(
        automation: automation,
        systemPrompt: "policy",
        grokExecutablePath: stub.path,
        runLogPath: sandbox.appendingPathComponent("runs.ndjson").path,
        // This test is about grok's argument safety, not the live-GUI
        // hand-off, so pin the liveness check to "never live" — otherwise a
        // real Coinor process happening to run on the test machine would
        // divert execution away from the grok stub this test depends on.
        pgrepPath: "/usr/bin/false",
        openPath: "/usr/bin/false"
    )

    let scriptURL = sandbox.appendingPathComponent("job.sh")
    try program.write(to: scriptURL, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    // The injected `touch` never executed.
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    // And grok received the hostile text as one intact argument.
    let argv = (try? String(contentsOf: argvDump, encoding: .utf8)) ?? ""
    #expect(argv.contains("; touch \(marker.path); echo "))
}

@Test
func shellQuotingEscapesEmbeddedQuotes() {
    #expect(AutomationJob.shellQuoted("plain") == "'plain'")
    #expect(AutomationJob.shellQuoted("it's") == "'it'\\''s'")
}

@Test
func anAutomationWithAnUnparseableScheduleProducesNoJob() {
    var automation = sampleAutomation()
    automation.schedule = "not a cron"
    #expect(throws: (any Error).self) {
        _ = try definition(automation)
    }
}

// MARK: - The plist actually serialises

@Test
func jobSerialisesToAValidPlist() throws {
    let automation = sampleAutomation(model: "grok-4.6")
    let data = try AutomationJob.plistData(
        automation: automation,
        systemPrompt: "policy",
        grokExecutablePath: "/Users/me/bin/grok",
        runLogPath: "/tmp/runs.ndjson",
        logPath: "/tmp/job.log"
    )
    let decoded = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any]
    let plist = try #require(decoded)
    #expect(plist["Label"] as? String == AutomationJob.label(for: automation.id))
    #expect((plist["StartCalendarInterval"] as? [[String: Int]])?.isEmpty == false)
}

// MARK: - Live GUI hand-off

/// Runs the generated shell script for real, exactly like
/// `injectionInThePromptCannotEscapeItsQuotedArgument` above, but exercises
/// the branch that hands a run off to a live Coinor GUI instead of running
/// `grok` directly. `pgrepPath`/`openPath` are pointed at stand-ins so the
/// test never touches the real `/usr/bin/pgrep`/`open` or a real Coinor
/// process.
private func runScript(
    _ program: String,
    in sandbox: URL
) throws {
    let scriptURL = sandbox.appendingPathComponent("job.sh")
    try program.write(to: scriptURL, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
}

@Test
func aLiveGuiHandsTheRunOffInsteadOfRunningGrokDirectly() throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    // A grok stub that would prove it ran, if invoked.
    let grokRanMarker = sandbox.appendingPathComponent("grok-ran")
    let grokStub = sandbox.appendingPathComponent("grok")
    try "#!/bin/sh\ntouch \(grokRanMarker.path)\nexit 0\n"
        .write(to: grokStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokStub.path)

    // A stand-in for /usr/bin/pgrep that always reports the GUI as alive.
    let pgrepStub = sandbox.appendingPathComponent("pgrep")
    try "#!/bin/sh\nexit 0\n".write(to: pgrepStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepStub.path)

    // A stand-in for /usr/bin/open that records the URL it was asked to open.
    let openArgsFile = sandbox.appendingPathComponent("open-args")
    let openStub = sandbox.appendingPathComponent("open")
    try "#!/bin/sh\nprintf '%s' \"$1\" > \(openArgsFile.path)\nexit 0\n"
        .write(to: openStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openStub.path)

    let automation = sampleAutomation()
    let program = AutomationJob.script(
        automation: automation,
        systemPrompt: "policy",
        grokExecutablePath: grokStub.path,
        runLogPath: sandbox.appendingPathComponent("runs.ndjson").path,
        pgrepPath: pgrepStub.path,
        openPath: openStub.path
    )
    try runScript(program, in: sandbox)

    #expect(!FileManager.default.fileExists(atPath: grokRanMarker.path))
    let openedURL = try String(contentsOf: openArgsFile, encoding: .utf8)
    #expect(openedURL.hasPrefix("coinor://run-automation?automationID="))
    #expect(openedURL.contains("automationID=\(automation.id)"))
    #expect(openedURL.contains("&trigger=scheduled"))
    let openedURLValue = try #require(URL(string: openedURL))
    let request = try #require(AutomationRunRequestRouting.parse(openedURLValue))
    #expect(request.automationID == automation.id)
    #expect(request.trigger == .scheduled)
    #expect(!request.runID.isEmpty)
    #expect(!request.sessionID.isEmpty)

    let log = try String(
        contentsOf: sandbox.appendingPathComponent("runs.ndjson"),
        encoding: .utf8
    )
    // The script always writes the "running" line itself, regardless of who
    // ends up executing the automation.
    #expect(log.contains("\"status\":\"running\""))
    #expect(!log.contains("\"status\":\"succeeded\""))
    #expect(!log.contains("\"status\":\"failed\""))
}

@Test
func aRunFromTheForcedMarkerHandsOffWithTheForcedTrigger() throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let pgrepStub = sandbox.appendingPathComponent("pgrep")
    try "#!/bin/sh\nexit 0\n".write(to: pgrepStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepStub.path)

    let openArgsFile = sandbox.appendingPathComponent("open-args")
    let openStub = sandbox.appendingPathComponent("open")
    try "#!/bin/sh\nprintf '%s' \"$1\" > \(openArgsFile.path)\nexit 0\n"
        .write(to: openStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openStub.path)

    let automation = sampleAutomation()
    let runLogPath = sandbox.appendingPathComponent("runs.ndjson").path
    let marker = AutomationJob.forcedMarkerPath(
        runLogPath: runLogPath,
        automationID: automation.id
    )
    FileManager.default.createFile(atPath: marker, contents: Data())

    let program = AutomationJob.script(
        automation: automation,
        systemPrompt: "policy",
        grokExecutablePath: "/does/not/matter",
        runLogPath: runLogPath,
        pgrepPath: pgrepStub.path,
        openPath: openStub.path
    )
    try runScript(program, in: sandbox)

    let openedURL = try String(contentsOf: openArgsFile, encoding: .utf8)
    #expect(openedURL.contains("&trigger=forced"))
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test
func aGuiNotRunningStillFallsBackToRunningGrokDirectly() throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let grokRanMarker = sandbox.appendingPathComponent("grok-ran")
    let grokStub = sandbox.appendingPathComponent("grok")
    try "#!/bin/sh\ntouch \(grokRanMarker.path)\nexit 0\n"
        .write(to: grokStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokStub.path)

    // A stand-in for /usr/bin/pgrep that always reports no match, like the
    // real one when Coinor's GUI is not running.
    let pgrepStub = sandbox.appendingPathComponent("pgrep")
    try "#!/bin/sh\nexit 1\n".write(to: pgrepStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pgrepStub.path)

    let automation = sampleAutomation()
    let program = AutomationJob.script(
        automation: automation,
        systemPrompt: "policy",
        grokExecutablePath: grokStub.path,
        runLogPath: sandbox.appendingPathComponent("runs.ndjson").path,
        pgrepPath: pgrepStub.path,
        openPath: "/usr/bin/false"
    )
    try runScript(program, in: sandbox)

    #expect(FileManager.default.fileExists(atPath: grokRanMarker.path))
    let log = try String(
        contentsOf: sandbox.appendingPathComponent("runs.ndjson"),
        encoding: .utf8
    )
    #expect(log.contains("\"status\":\"succeeded\""))
}

@Test
func liveHandoffURLPrefixEncodesTheAutomationID() {
    let prefix = AutomationJob.liveHandoffURLPrefix(automationID: "with space & amp")
    #expect(prefix.hasPrefix("coinor://run-automation?automationID="))
    #expect(!prefix.contains(" "))
    #expect(!prefix.contains("&amp"))
}
