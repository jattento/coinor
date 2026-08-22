import Darwin
import Foundation

/// Reads the append-only run log the launchd jobs write.
///
/// Each job appends one line when it starts and one when it finishes, so the
/// file is a simple NDJSON event stream. Folding it gives the Automations tab
/// its run history and gives the sidebar the session-to-automation mapping
/// that the clock badge needs.
///
/// Append-only is deliberate: several automations can run at once, and a short
/// `O_APPEND` write from each is safe without any locking, which is what lets
/// the jobs stay plain shell with no Conan Code process involved.
enum AutomationRunLog {
    /// One raw event line.
    struct Event: Codable, Equatable, Sendable {
        var runID: String
        var automationID: String
        var sessionID: String
        var startedAt: Date?
        var finishedAt: Date?
        var status: String
        var exitCode: Int?
        /// Absent in logs written before runs recorded why they started.
        var trigger: String?
    }

    /// Parses the log into runs, newest first, folding each run's start and
    /// finish events together.
    static func runs(from contents: String) -> [AutomationRun] {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "bad date \(text)")
                )
            }
            return date
        }

        var byRunID: [String: AutomationRun] = [:]
        var order: [String] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(Event.self, from: data) else {
                // A partially written trailing line is expected while a job is
                // appending; skip it rather than discarding the whole log.
                continue
            }
            var run = byRunID[event.runID] ?? {
                order.append(event.runID)
                return AutomationRun(
                    id: event.runID,
                    automationID: event.automationID,
                    sessionID: event.sessionID,
                    trigger: .scheduled,
                    status: .running
                )
            }()
            run.sessionID = event.sessionID
            if let trigger = event.trigger.flatMap(AutomationTrigger.init(rawValue:)) {
                run.trigger = trigger
            }
            if let startedAt = event.startedAt { run.startedAt = startedAt }
            if let finishedAt = event.finishedAt { run.finishedAt = finishedAt }
            run.status = status(from: event.status)
            if let exitCode = event.exitCode, exitCode != 0 {
                run.errorMessage = "grok exited with status \(exitCode)"
            }
            byRunID[event.runID] = run
        }

        return order
            .compactMap { byRunID[$0] }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    private static func status(from raw: String) -> AutomationRunStatus {
        AutomationRunStatus(rawValue: raw) ?? .running
    }

    /// Reads and folds the log at `url`. A missing file simply means no run
    /// has happened yet.
    static func runs(at url: URL) -> [AutomationRun] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return runs(from: contents)
    }

    /// Appends one event line, matching the exact NDJSON shape the launchd
    /// jobs' shell script writes with `printf ... >> "$log"`.
    ///
    /// Used only by Coinor's in-process automation runner (see
    /// `AutomationLiveRunner`): when the GUI is already running, the shell
    /// script hands the run off instead of executing `grok` itself, so
    /// Coinor is the one that must record the outcome. Opens with `O_APPEND`
    /// so this is safe to call concurrently with the shell script's own
    /// `>>` writes and with other automations' runs, matching the log's
    /// existing no-locking contract.
    static func append(_ event: Event, to url: URL) throws {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        let wrote = line.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard wrote == line.count else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
