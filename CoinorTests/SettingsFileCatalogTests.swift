import Foundation
import Testing

@testable import Coinor

private let home = "/Users/example user"

@Test
func settingsCatalogExposesTheRequiredGlobalConfigurationFiles() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    #expect(tabs.count >= 3)
    let paths = tabs.map(\.path)
    #expect(paths.contains("\(home)/.grok/AGENTS.md"))
    #expect(paths.contains("\(home)/.grok/subagent-router.toml"))
    // At least one further global configuration file beyond the two required.
    #expect(
        paths.contains { path in
            path != "\(home)/.grok/AGENTS.md"
                && path != "\(home)/.grok/subagent-router.toml"
        }
    )
    #expect(Set(tabs.map(\.id)).count == tabs.count)
    #expect(tabs.allSatisfy { !$0.label.isEmpty })
    #expect(tabs.contains { $0.id == SettingsFileCatalog.defaultTabID })
}

@Test
func settingsCatalogPathsAreAbsoluteWithTildeExpanded() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    for tab in tabs {
        #expect(tab.path.hasPrefix("/"))
        #expect(!tab.path.contains("~"))
        #expect(tab.path.hasPrefix(home + "/"))
    }
}

@Test
func settingsCatalogUsesTheRealHomeDirectoryByDefault() {
    let tabs = SettingsFileCatalog.tabs()

    #expect(!tabs.isEmpty)
    for tab in tabs {
        #expect(tab.path.hasPrefix(NSHomeDirectory() + "/"))
    }
}

@Test
func everySettingsTabEditsItsOwnFileWithFresh() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    for tab in tabs {
        let launch = tab.launch
        #expect(launch.mode == .command("fresh " + ShellQuoting.quote(tab.path)))
        #expect(launch.shellCommand == "fresh '\(tab.path)'")
        #expect(launch.shellCommand.hasPrefix("fresh '"))
        #expect(launch.shellCommand.hasSuffix("'"))
        // A single `fresh <file>` invocation: no directory-only fallback and no
        // second command chained onto it.
        #expect(!launch.shellCommand.contains("fresh ."))
        #expect(!launch.shellCommand.contains("&&"))
        #expect(!launch.shellCommand.contains(";"))
        #expect(launch.remote == nil)
        #expect(launch.explicitCommand == launch.shellCommand)
        #expect(launch.sessionID == "settings.\(tab.id)")
    }
}

@Test
func settingsTabWorkingDirectoryIsAnExistingDirectory() {
    for tab in SettingsFileCatalog.tabs() {
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: tab.workingDirectory,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
        #expect(tab.launch.surfaceStartupFailure() == nil)
    }
}

@Test
func settingsTabAccessibilityIdentifiersAreUniquePerTab() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    #expect(Set(tabs.map(\.accessibilityIdentifier)).count == tabs.count)
    #expect(Set(tabs.map(\.terminalAccessibilityIdentifier)).count == tabs.count)
    for tab in tabs {
        #expect(tab.accessibilityIdentifier == "AppShellSettingsTab.\(tab.id)")
        #expect(
            tab.terminalAccessibilityIdentifier
                == "AppShellSettingsTerminal.\(tab.id)"
        )
    }
}

@Test
func settingsTabQuotingSurvivesAHomeDirectoryWithASingleQuote() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: "/Users/o'brien")

    for tab in tabs {
        #expect(tab.path.hasPrefix("/Users/o'brien/"))
        #expect(tab.launch.shellCommand.contains("'\\''"))
        #expect(tab.launch.shellCommand.hasPrefix("fresh '"))
    }
}
