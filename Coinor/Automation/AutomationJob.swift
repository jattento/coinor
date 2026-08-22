import Foundation

/// Builds the launchd job that runs one automation.
///
/// There is no Conan Code helper process in this path. launchd fires the job
/// at the scheduled time — and, unlike `cron`, runs a job that was missed
/// while the machine was asleep or off, folding several missed occurrences
/// into a single run, which is exactly Conan Code's catch-up contract. The job
/// then runs `grok` directly in headless mode. `grok` persists the session
/// itself, so the resulting conversation appears in Conan Code's sidebar
/// through the ordinary session catalog.
///
/// The job appends a line to the run log before and after the run, which is
/// what gives the Automations tab its run history and what lets the sidebar
/// mark a conversation as an automation run.
enum AutomationJob {
    static let labelPrefix = "dev.coinor.Coinor.automation."

    /// The run log every job appends to, alongside the metadata document.
    static let runLogFileName = "automation-runs.ndjson"

    static func label(for automationID: String) -> String {
        labelPrefix + automationID
    }

    static func plistFileName(for automationID: String) -> String {
        label(for: automationID) + ".plist"
    }

    /// One piece of the `grok` command line.
    ///
    /// Flags and values are distinguished structurally rather than by
    /// inspecting the text, so a prompt that happens to start with `-` is
    /// still quoted as a value and can never be read as a flag.
    enum Token: Equatable, Sendable {
        /// A literal flag Conan Code controls.
        case flag(String)
        /// User- or configuration-supplied text; always quoted.
        case value(String)
        /// The session UUID minted by the job at run time.
        case sessionID
    }

    /// The `grok` invocation for one automation.
    ///
    /// `--rules` *appends* the shared automation instruction to Grok's own
    /// system prompt instead of replacing it, so the agent keeps its tools and
    /// behaviour. `--always-approve` is what keeps an unattended run from
    /// blocking on a permission prompt. `-p` is headless mode: one user turn,
    /// after which the agent runs its full loop — tools, subagents and all —
    /// until it finishes, then exits.
    static func grokTokens(
        automation: Automation,
        systemPrompt: String
    ) -> [Token] {
        var tokens: [Token] = [
            .flag("--cwd"), .value(automation.workingDirectory),
            .flag("--session-id"), .sessionID,
            .flag("--rules"), .value(combinedRules(systemPrompt: systemPrompt)),
        ]
        if let model = automation.model, !model.isEmpty {
            tokens += [.flag("--model"), .value(model)]
        }
        if let effort = automation.reasoningEffort {
            tokens += [.flag("--reasoning-effort"), .value(effort.rawValue)]
        }
        tokens += [.flag("--always-approve"), .flag("-p"), .value(automation.prompt)]
        return tokens
    }

    /// The rendered shell command. Flags stay literal for readability, every
    /// value is single-quoted, and the session ID is the shell variable the
    /// job mints per run.
    static func grokCommand(
        automation: Automation,
        systemPrompt: String,
        grokExecutablePath: String
    ) -> String {
        let rendered = grokTokens(
            automation: automation,
            systemPrompt: systemPrompt
        ).map { token -> String in
            switch token {
            case let .flag(flag): flag
            case let .value(value): shellQuoted(value)
            case .sessionID: "\"$session_id\""
            }
        }
        return ([shellQuoted(grokExecutablePath)] + rendered).joined(separator: " ")
    }

    /// The shell program launchd runs.
    ///
    /// It mints a session UUID so the run can be tied back to its
    /// conversation, records the run's start and outcome in the log, and
    /// raises a native notification when it finishes.
    static func script(
        automation: Automation,
        systemPrompt: String,
        grokExecutablePath: String,
        runLogPath: String,
        pgrepPath: String = "/usr/bin/pgrep",
        openPath: String = "/usr/bin/open"
    ) -> String {
        let command = grokCommand(
            automation: automation,
            systemPrompt: systemPrompt,
            grokExecutablePath: grokExecutablePath
        )

        // Only Conan Code-owned identifiers are interpolated into the JSON;
        // they are UUIDs, so they cannot carry a quote or a backslash.
        let automationID = automation.id
        // "Run Now" drops a marker before kickstarting the job, because
        // launchd starts a scheduled run and a forced run through the exact
        // same command. Consuming the marker is what tells them apart.
        let marker = forcedMarkerPath(
            runLogPath: runLogPath,
            automationID: automationID
        )
        return """
        #!/bin/sh
        set -u
        log=\(shellQuoted(runLogPath))
        /bin/mkdir -p "$(/usr/bin/dirname "$log")"
        marker=\(shellQuoted(marker))
        if [ -f "$marker" ]; then
          trigger=forced
          /bin/rm -f "$marker"
        else
          trigger=scheduled
        fi
        session_id=$(/usr/bin/uuidgen | /usr/bin/tr 'A-Z' 'a-z')
        run_id=$(/usr/bin/uuidgen)
        started=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"runID":"%s","automationID":"%s","sessionID":"%s","startedAt":"%s","status":"running","trigger":"%s"}\\n' \\
          "$run_id" \(shellQuoted(automationID)) "$session_id" "$started" "$trigger" >> "$log"
        if \(shellQuoted(pgrepPath)) -f \(shellQuoted(liveGUIProcessPattern)) >/dev/null 2>&1; then
          \(shellQuoted(openPath)) \(shellQuoted(liveHandoffURLPrefix(automationID: automationID)))"&runID=$run_id&sessionID=$session_id&trigger=$trigger" >/dev/null 2>&1
          exit 0
        fi
        \(command)
        status=$?
        finished=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
        if [ "$status" -eq 0 ]; then
          state=succeeded
          title='Automation finished'
        else
          state=failed
          title='Automation failed'
        fi
        printf '{"runID":"%s","automationID":"%s","sessionID":"%s","finishedAt":"%s","status":"%s","exitCode":%s,"trigger":"%s"}\\n' \\
          "$run_id" \(shellQuoted(automationID)) "$session_id" "$finished" "$state" "$status" "$trigger" >> "$log"
        /usr/bin/osascript -e "display notification \\"$(printf '%s' \(shellQuoted(appleScriptSafe(automation.name))))\\" with title \\"$title\\"" >/dev/null 2>&1 || true
        exit $status
        """
    }

    /// Matches the compiled app's process regardless of where it is
    /// installed (`/Applications`, a dev build under `DerivedData`, etc.),
    /// so the job can tell whether to hand the run off to a live GUI
    /// instance instead of running `grok` itself.
    static let liveGUIProcessPattern = "/Coinor.app/Contents/MacOS/Coinor"

    /// The static part of the `coinor://run-automation` URL the script hands
    /// a run off to, ending right before `&runID=...`. `runID`, `sessionID`
    /// and `trigger` are only known at run time (see `script`), so the
    /// script appends them itself as shell variables instead of this
    /// function taking them as parameters.
    static func liveHandoffURLPrefix(automationID: String) -> String {
        var components = URLComponents()
        components.scheme = AutomationRunRequest.scheme
        components.host = AutomationRunRequest.host
        components.queryItems = [
            URLQueryItem(name: "automationID", value: automationID),
        ]
        // A fixed scheme/host plus one percent-encoded query item always
        // produces a URL.
        return components.url!.absoluteString
    }

    /// The instruction appended to Grok's system prompt. Falls back to the
    /// shipped default when the user cleared the shared prompt.
    static func combinedRules(systemPrompt: String) -> String {
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AutomationSettings.default.systemPrompt : trimmed
    }

    /// The full launchd job definition for one automation.
    static func definition(
        automation: Automation,
        systemPrompt: String,
        grokExecutablePath: String,
        runLogPath: String,
        logPath: String,
        pgrepPath: String = "/usr/bin/pgrep",
        openPath: String = "/usr/bin/open"
    ) throws -> [String: Any] {
        let schedule = try CronSchedule.parse(automation.schedule)
        let intervals = try CronLaunchdCompiler.intervals(for: schedule)
        let program = script(
            automation: automation,
            systemPrompt: systemPrompt,
            grokExecutablePath: grokExecutablePath,
            runLogPath: runLogPath,
            pgrepPath: pgrepPath,
            openPath: openPath
        )
        return [
            "Label": label(for: automation.id),
            "ProgramArguments": ["/bin/sh", "-c", program],
            // No RunAtLoad: installing or editing an automation must not fire
            // it immediately. launchd still runs a *missed* calendar interval
            // once the machine wakes, which is the catch-up behaviour.
            "RunAtLoad": false,
            "StartCalendarInterval": intervals.map(\.plistValue),
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    static func plistData(
        automation: Automation,
        systemPrompt: String,
        grokExecutablePath: String,
        runLogPath: String,
        logPath: String,
        pgrepPath: String = "/usr/bin/pgrep",
        openPath: String = "/usr/bin/open"
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: definition(
                automation: automation,
                systemPrompt: systemPrompt,
                grokExecutablePath: grokExecutablePath,
                runLogPath: runLogPath,
                logPath: logPath,
                pgrepPath: pgrepPath,
                openPath: openPath
            ),
            format: .xml,
            options: 0
        )
    }

    /// Where "Run Now" leaves its marker for a given automation. It sits
    /// beside the run log so both live in the same Conan Code directory.
    static func forcedMarkerPath(
        runLogPath: String,
        automationID: String
    ) -> String {
        let directory = (runLogPath as NSString).deletingLastPathComponent
        return (directory as NSString)
            .appendingPathComponent("automation-forced-\(automationID)")
    }

    /// Single-quotes a value for `/bin/sh`, so a prompt containing quotes,
    /// `$`, or backticks cannot break out of its argument.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strips the characters that would terminate an AppleScript string.
    private static func appleScriptSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
}
