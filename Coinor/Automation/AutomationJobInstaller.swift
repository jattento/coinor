import Darwin
import Foundation

enum AutomationJobError: LocalizedError {
    case launchctlFailed(operation: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .launchctlFailed(operation, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl \(operation) failed with status \(status)"
                + (detail.isEmpty ? "." : ": \(detail)")
        }
    }
}

/// Installs, removes and triggers the launchd job behind each automation.
///
/// One job per automation, because a launchd job carries exactly one schedule.
/// That mapping also gives the user-facing controls their natural
/// implementation: pausing is `bootout`, resuming is `bootstrap`, and "run
/// now" is `kickstart`.
struct AutomationJobInstaller: Sendable {
    /// Where the plists live. Injectable so tests never touch the real
    /// `~/Library/LaunchAgents`.
    let launchAgentsDirectory: URL
    /// The Application Support directory the run log is written to.
    let supportDirectory: URL
    let grokExecutablePath: String
    /// Runs `launchctl`. Injectable so tests can assert the commands without
    /// registering anything with the real launchd.
    let runLaunchctl: @Sendable ([String]) throws -> Void

    init(
        launchAgentsDirectory: URL,
        supportDirectory: URL,
        grokExecutablePath: String,
        runLaunchctl: (@Sendable ([String]) throws -> Void)? = nil
    ) {
        self.launchAgentsDirectory = launchAgentsDirectory
        self.supportDirectory = supportDirectory
        self.grokExecutablePath = grokExecutablePath
        self.runLaunchctl = runLaunchctl ?? { arguments in
            try AutomationJobInstaller.launchctl(arguments)
        }
    }

    var runLogURL: URL {
        supportDirectory.appendingPathComponent(AutomationJob.runLogFileName)
    }

    private var jobLogURL: URL {
        supportDirectory.appendingPathComponent("automation-jobs.log")
    }

    func plistURL(for automationID: String) -> URL {
        launchAgentsDirectory.appendingPathComponent(
            AutomationJob.plistFileName(for: automationID)
        )
    }

    /// Writes the job and loads it, replacing any previous definition.
    ///
    /// A paused automation is written out and unloaded instead, so pausing
    /// keeps the configuration but stops every fire — including the catch-up
    /// launchd would otherwise perform on wake.
    func install(
        automation: Automation,
        systemPrompt: String,
        fileManager: FileManager = .default
    ) throws {
        guard !automation.workingDirectory.isEmpty, !automation.prompt.isEmpty else {
            // Nothing to schedule yet; make sure a stale job is not left over.
            try remove(automationID: automation.id, fileManager: fileManager)
            return
        }
        guard !automation.isPaused else {
            try unload(automationID: automation.id)
            return
        }

        try fileManager.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )

        let data = try AutomationJob.plistData(
            automation: automation,
            systemPrompt: systemPrompt,
            grokExecutablePath: grokExecutablePath,
            runLogPath: runLogURL.path,
            logPath: jobLogURL.path
        )
        let url = plistURL(for: automation.id)
        try data.write(to: url, options: .atomic)

        // Replace any previous definition: bootout is best-effort because the
        // job may not be loaded yet.
        try? unload(automationID: automation.id)
        try runLaunchctl(["bootstrap", domain, url.path])
    }

    /// Unloads and deletes the job.
    func remove(
        automationID: String,
        fileManager: FileManager = .default
    ) throws {
        try? unload(automationID: automationID)
        let url = plistURL(for: automationID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Stops the job from firing without deleting its definition.
    func unload(automationID: String) throws {
        try runLaunchctl([
            "bootout",
            "\(domain)/\(AutomationJob.label(for: automationID))",
        ])
    }

    /// Runs the automation immediately, independently of its schedule.
    func runNow(automationID: String) throws {
        try runLaunchctl([
            "kickstart",
            "-k",
            "\(domain)/\(AutomationJob.label(for: automationID))",
        ])
    }

    /// Reconciles every job with the current configuration, so the on-disk
    /// launchd state always matches what the user sees.
    func synchronize(
        automations: [Automation],
        systemPrompt: String,
        fileManager: FileManager = .default
    ) {
        let configured = Set(automations.map(\.id))
        for automation in automations {
            try? install(
                automation: automation,
                systemPrompt: systemPrompt,
                fileManager: fileManager
            )
        }
        // Drop jobs whose automation no longer exists.
        let contents = (try? fileManager.contentsOfDirectory(
            at: launchAgentsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(AutomationJob.labelPrefix),
                  name.hasSuffix(".plist") else { continue }
            let id = String(
                name.dropFirst(AutomationJob.labelPrefix.count)
                    .dropLast(".plist".count)
            )
            guard !configured.contains(id) else { continue }
            try? remove(automationID: id, fileManager: fileManager)
        }
    }

    private var domain: String {
        "gui/\(getuid())"
    }

    /// Invokes `launchctl`, surfacing its diagnostics on failure.
    ///
    /// `bootout` legitimately fails when the job is not loaded, so callers
    /// that treat it as best-effort ignore the error.
    static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AutomationJobError.launchctlFailed(
                operation: arguments.first ?? "",
                status: process.terminationStatus,
                message: String(decoding: data, as: UTF8.self)
            )
        }
    }
}
