import Foundation
import Testing

@testable import Coinor

// MARK: - Folding the run log

@Test
func aStartedRunIsReportedAsRunning() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs.count == 1)
    #expect(runs[0].id == "r1")
    #expect(runs[0].automationID == "a1")
    #expect(runs[0].sessionID == "s1")
    #expect(runs[0].status == .running)
    #expect(runs[0].finishedAt == nil)
}

@Test
func startAndFinishEventsFoldIntoOneRun() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    {"runID":"r1","automationID":"a1","sessionID":"s1","finishedAt":"2026-01-01T09:05:00Z","status":"succeeded","exitCode":0}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs.count == 1)
    #expect(runs[0].status == .succeeded)
    #expect(runs[0].startedAt != nil)
    #expect(runs[0].finishedAt != nil)
    #expect(runs[0].errorMessage == nil)
}

@Test
func aNonZeroExitIsRecordedAsAFailureWithItsStatus() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    {"runID":"r1","automationID":"a1","sessionID":"s1","finishedAt":"2026-01-01T09:05:00Z","status":"failed","exitCode":2}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs[0].status == .failed)
    #expect(runs[0].errorMessage?.contains("2") == true)
}

@Test
func runsAreOrderedNewestFirst() {
    let log = """
    {"runID":"old","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    {"runID":"new","automationID":"a1","sessionID":"s2","startedAt":"2026-01-02T09:00:00Z","status":"running"}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs.map(\.id) == ["new", "old"])
}

@Test
func runsFromSeveralAutomationsAreAllRead() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    {"runID":"r2","automationID":"a2","sessionID":"s2","startedAt":"2026-01-01T09:01:00Z","status":"running"}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(Set(runs.map(\.automationID)) == ["a1", "a2"])
}

/// Jobs append concurrently, so the reader can catch a half-written trailing
/// line. It must skip it rather than discarding the whole history.
@Test
func aPartiallyWrittenTrailingLineIsSkipped() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    {"runID":"r2","automationID":"a1","sessi
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs.map(\.id) == ["r1"])
}

// MARK: - Trigger

@Test
func aForcedRunIsReportedAsManual() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running","trigger":"forced"}
    {"runID":"r1","automationID":"a1","sessionID":"s1","finishedAt":"2026-01-01T09:01:00Z","status":"succeeded","exitCode":0,"trigger":"forced"}
    """
    let runs = AutomationRunLog.runs(from: log)
    #expect(runs[0].trigger == .forced)
}

@Test
func aScheduledRunIsReportedAsScheduled() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running","trigger":"scheduled"}
    """
    #expect(AutomationRunLog.runs(from: log)[0].trigger == .scheduled)
}

/// Logs written before runs recorded a trigger must still read back.
@Test
func aRunWithoutATriggerDefaultsToScheduled() {
    let log = """
    {"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}
    """
    #expect(AutomationRunLog.runs(from: log)[0].trigger == .scheduled)
}

@Test
func anEmptyLogYieldsNoRuns() {
    #expect(AutomationRunLog.runs(from: "").isEmpty)
}

@Test
func aMissingLogFileYieldsNoRuns() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("definitely-missing-\(UUID().uuidString).ndjson")
    #expect(AutomationRunLog.runs(at: url).isEmpty)
}

/// End to end against a file written the way the launchd job writes it: with
/// `printf` appends, one line at a time.
@Test
func readsALogWrittenByAppendingLikeTheJobDoes() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("runs-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: url) }

    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    for line in [
        #"{"runID":"r1","automationID":"a1","sessionID":"s1","startedAt":"2026-01-01T09:00:00Z","status":"running"}"#,
        #"{"runID":"r1","automationID":"a1","sessionID":"s1","finishedAt":"2026-01-01T09:02:00Z","status":"succeeded","exitCode":0}"#,
    ] {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }
    try handle.close()

    let runs = AutomationRunLog.runs(at: url)
    #expect(runs.count == 1)
    #expect(runs[0].status == .succeeded)
    #expect(runs[0].sessionID == "s1")
}

/// Coinor's own live automation runner appends the "finished" event in
/// Swift instead of the shell script when it drives the run itself; the
/// written line must fold identically to one the shell script would write.
@Test
func appendWritesAnEventTheReaderFoldsCorrectly() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("runs-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: url) }

    try AutomationRunLog.append(
        .init(
            runID: "r1",
            automationID: "a1",
            sessionID: "s1",
            startedAt: Date(timeIntervalSince1970: 1_735_722_000),
            status: "running",
            trigger: "scheduled"
        ),
        to: url
    )
    try AutomationRunLog.append(
        .init(
            runID: "r1",
            automationID: "a1",
            sessionID: "s1",
            finishedAt: Date(timeIntervalSince1970: 1_735_722_300),
            status: "succeeded",
            exitCode: 0,
            trigger: "scheduled"
        ),
        to: url
    )

    let runs = AutomationRunLog.runs(at: url)
    #expect(runs.count == 1)
    #expect(runs[0].status == .succeeded)
    #expect(runs[0].sessionID == "s1")
    #expect(runs[0].trigger == .scheduled)
}

/// The shell script's fallback path and Coinor's own live-run path append to
/// the same file; each `append` call must not clobber lines already there.
@Test
func appendIsAdditiveAlongsideExistingLines() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("runs-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: url) }

    let existing = #"{"runID":"r0","automationID":"a0","sessionID":"s0","startedAt":"2026-01-01T09:00:00Z","status":"running"}"#
    try Data((existing + "\n").utf8).write(to: url)

    try AutomationRunLog.append(
        .init(runID: "r1", automationID: "a1", sessionID: "s1", status: "running"),
        to: url
    )

    let runs = AutomationRunLog.runs(at: url)
    #expect(Set(runs.map(\.id)) == ["r0", "r1"])
}

// MARK: - Model catalog parsing

@Test
func modelCatalogParsesGrokOutput() {
    let output = """
    You are logged in with grok.com.

    Default model: claude-opus-5

    Available models:
      - grok-4.6
      - grok-4.5
      * claude-opus-5 (default)
      - claude-sonnet-5
    """
    let models = AutomationModelCatalog.parse(output)
    #expect(models.map(\.id) == [
        "grok-4.6", "grok-4.5", "claude-opus-5", "claude-sonnet-5",
    ])
    #expect(models.first { $0.isDefault }?.id == "claude-opus-5")
}

@Test
func modelCatalogIgnoresNoise() {
    #expect(AutomationModelCatalog.parse("").isEmpty)
    #expect(AutomationModelCatalog.parse("no models here").isEmpty)
}
