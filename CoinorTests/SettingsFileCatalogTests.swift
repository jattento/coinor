import Foundation
import Testing

@testable import Coinor

private let home = "/Users/example user"

@Test
func settingsCatalogExposesTheRequiredGlobalConfigurationFiles() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    #expect(tabs.count >= 4)
    let paths = tabs.compactMap(\.path)
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
        if let path = tab.path {
            #expect(path.hasPrefix("/"))
            #expect(!path.contains("~"))
            #expect(path.hasPrefix(home + "/"))
        }
    }
}

@Test
func settingsCatalogUsesTheRealHomeDirectoryByDefault() {
    let tabs = SettingsFileCatalog.tabs()

    #expect(!tabs.isEmpty)
    for tab in tabs {
        #expect(tab.path == nil || tab.path!.hasPrefix(NSHomeDirectory() + "/"))
    }
}

@Test
func everySettingsTabEditsItsOwnFileWithFresh() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    for tab in tabs where tab.isTerminal {
        let launch = tab.launch
        #expect(launch?.mode == .command("fresh " + ShellQuoting.quote(tab.path!)))
        #expect(launch?.shellCommand == "fresh '\(tab.path!)'")
        #expect(launch?.shellCommand.hasPrefix("fresh '") ?? false)
        #expect(launch?.shellCommand.hasSuffix("'") ?? false)
        // A single `fresh <file>` invocation: no directory-only fallback and no
        // second command chained onto it.
        #expect(!(launch?.shellCommand.contains("fresh .") ?? true))
        #expect(!(launch?.shellCommand.contains("&&") ?? true))
        #expect(!(launch?.shellCommand.contains(";") ?? true))
        #expect(launch?.remote == nil)
        #expect(launch?.explicitCommand == launch?.shellCommand)
        #expect(launch?.sessionID == "settings.\(tab.id)")
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
        #expect(tab.launch?.surfaceStartupFailure() == nil)
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
        #expect(tab.path?.hasPrefix("/Users/o'brien/") ?? true)
        #expect(tab.launch?.shellCommand.contains("'\\''") ?? true)
        #expect(tab.launch?.shellCommand.hasPrefix("fresh '") ?? true)
    }
}

@Test
func changelogTabIsFirstNonTerminalTabWithoutAFile() {
    let tabs = SettingsFileCatalog.tabs(homeDirectory: home)

    let changelog = tabs.first { $0.id == SettingsFileCatalog.changelogTabID }
    #expect(changelog != nil)
    #expect(changelog?.path == nil)
    #expect(changelog?.launch == nil)
    #expect(changelog?.isChangelog == true)

    // Every other tab is a real terminal file tab.
    for tab in tabs where tab.id != SettingsFileCatalog.changelogTabID {
        #expect(tab.path?.hasPrefix(home + "/") == true)
        #expect(tab.launch != nil)
        #expect(tab.isTerminal == true)
    }
}
