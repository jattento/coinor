import Foundation

/// One global configuration file the settings window can edit.
///
/// Every tab edits its file with `fresh` in a Ghostty surface; Conan Code never
/// reads or rewrites the file itself.
struct SettingsFileTab: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// Absolute path with `~` already expanded.
    let path: String

    var accessibilityIdentifier: String {
        AppShellIdentifier.settingsTab(id)
    }

    var terminalAccessibilityIdentifier: String {
        AppShellIdentifier.settingsTerminal(id)
    }

    /// The directory `fresh` starts in. A missing parent directory would make
    /// the surface refuse to start, so home is the fallback.
    var workingDirectory: String {
        let parent = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return NSHomeDirectory()
        }
        return parent
    }

    /// `fresh <quoted absolute path>` — the only editor a settings tab uses.
    var command: String {
        "fresh " + ShellQuoting.quote(path)
    }

    var launch: TerminalLaunchRequest {
        TerminalLaunchRequest(
            commandID: "settings.\(id)",
            workingDirectory: workingDirectory,
            command: command
        )
    }
}

enum SettingsFileCatalog {
    /// Path relative to the home directory, so the catalog stays testable with
    /// an arbitrary home.
    private struct Entry {
        let id: String
        let label: String
        let relativePath: String
    }

    private static let entries: [Entry] = [
        Entry(
            id: "grokAgents",
            label: "Grok Agents",
            relativePath: ".grok/AGENTS.md"
        ),
        Entry(
            id: "subagentRouter",
            label: "Subagent Router",
            relativePath: ".grok/subagent-router.toml"
        ),
        Entry(
            id: "grokConfig",
            label: "Grok Config",
            relativePath: ".grok/config.toml"
        ),
        Entry(
            id: "grokMemory",
            label: "Grok Memory",
            relativePath: ".grok/memory/MEMORY.md"
        ),
        Entry(
            id: "coinorTelegram",
            label: "Coinor Telegram",
            relativePath: ".coinor/telegram.toml"
        ),
    ]

    static func tabs(
        homeDirectory: String = NSHomeDirectory()
    ) -> [SettingsFileTab] {
        entries.map { entry in
            SettingsFileTab(
                id: entry.id,
                label: entry.label,
                path: (homeDirectory as NSString)
                    .appendingPathComponent(entry.relativePath)
            )
        }
    }

    static let defaultTabID = "grokAgents"
}
