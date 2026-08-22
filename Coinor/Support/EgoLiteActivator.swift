import AppKit
import Foundation

/// Brings the real `ego lite` app window to the front, showing the exact
/// Task Space a Browser Mirror tab is previewing — the "Open in ego lite"
/// affordance. Coinor's own tab stays a read-only glance; this is the
/// one-click path to the full native browser (tabs, address bar, "Take
/// over"/"Stop") that Coinor deliberately does not try to reproduce.
enum EgoLiteActivator {
    static let bundleIdentifier = "com.citrolabs.ego.lite"

    @MainActor
    static func open(
        taskSpaceName: String,
        locator: EgoBrowserLocator = EgoBrowserLocator()
    ) async {
        if let executablePath = locator.resolve() {
            _ = await activateTaskSpace(
                taskSpaceName: taskSpaceName,
                executablePath: executablePath
            )
        }
        activateApp()
    }

    private static func activateApp() {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Switches ego lite's own internal "which Space is visible" state to
    /// the named Task Space via `Target.activateTarget`. This does not
    /// steal OS-level focus by itself (confirmed live: ego lite deliberately
    /// never does), so it always pairs with `activateApp()` above.
    static func activateTaskSpace(
        taskSpaceName: String,
        executablePath: String
    ) async -> Result<Void, EgoBrowserPollError> {
        let script = script(taskSpaceName: taskSpaceName)
        switch await EgoBrowserCLIRunner.run(
            executablePath: executablePath,
            stdin: script,
            timeout: .seconds(10)
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let outcome):
            guard outcome.status == 0 else {
                let message = String(
                    decoding: outcome.stderr,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(
                    .nonZeroExit(code: outcome.status, message: message)
                )
            }
            return .success(())
        }
    }

    static func script(taskSpaceName: String) -> String {
        let literal = (try? JSONEncoder().encode(taskSpaceName))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\(taskSpaceName.replacingOccurrences(of: "\"", with: "\\\""))\""
        return """
            const task = await useOrCreateTaskSpace(\(literal))
            const tab = await currentTab()
            if (tab?.targetId) {
                await cdp('Target.activateTarget', { targetId: tab.targetId })
            }
            cliLog(JSON.stringify({ ok: true }))
            """
    }
}
