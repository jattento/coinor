import Foundation

/// One global configuration file the settings window can edit — or the
/// changelog tab, which does not edit a file and is not backed by a terminal.
///
/// Every file tab edits its file with `fresh` in a Ghostty surface; Conan Code
/// never reads or rewrites the file itself. The changelog tab is rendered as a
/// native SwiftUI view instead.
struct SettingsFileTab: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// Absolute path with `~` already expanded. `nil` for the changelog tab.
    let path: String?

    var accessibilityIdentifier: String {
        AppShellIdentifier.settingsTab(id)
    }

    var terminalAccessibilityIdentifier: String {
        AppShellIdentifier.settingsTerminal(id)
    }

    /// Whether this tab needs a Ghostty terminal. The changelog is the only
    /// non-terminal tab.
    var isTerminal: Bool { path != nil }

    /// `true` for the changelog tab.
    var isChangelog: Bool { id == SettingsFileCatalog.changelogTabID }

    /// The directory `fresh` starts in. A missing parent directory would make
    /// the surface refuse to start, so home is the fallback. The changelog
    /// tab has no directory and also falls back to home.
    var workingDirectory: String {
        guard let path else { return NSHomeDirectory() }
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
        guard let path else { return "" }
        return "fresh " + ShellQuoting.quote(path)
    }

    var launch: TerminalLaunchRequest? {
        guard path != nil else { return nil }
        return TerminalLaunchRequest(
            commandID: "settings.\(id)",
            workingDirectory: workingDirectory,
            command: command
        )
    }
}

enum SettingsFileCatalog {
    /// Path relative to the home directory, so the catalog stays testable with
    /// an arbitrary home. The changelog tab has no file.
    private struct Entry {
        let id: String
        let label: String
        let relativePath: String?

        init(id: String, label: String, relativePath: String? = nil) {
            self.id = id
            self.label = label
            self.relativePath = relativePath
        }
    }

    static let changelogTabID = "changelog"

    private static let entries: [Entry] = [
        Entry(
            id: changelogTabID,
            label: "Changelog"
        ),
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
    ]

    static func tabs(
        homeDirectory: String = NSHomeDirectory()
    ) -> [SettingsFileTab] {
        entries.map { entry in
            SettingsFileTab(
                id: entry.id,
                label: entry.label,
                path: entry.relativePath.map {
                    (homeDirectory as NSString)
                        .appendingPathComponent($0)
                }
            )
        }
    }

    static let defaultTabID = "grokAgents"
}
