import Foundation
import Testing

@testable import Coinor

/// Pins the unversioned couplings between Coinor and the installed `grok`
/// binary so a Grok change fails loudly instead of silently.
///
/// `--help` and `--version` probes never start a session, so they run
/// whenever the binary is present. Disk-layout checks report rather than
/// fail when the real `~/.grok` tree is absent. The suite skips only when
/// no Grok executable is installed.
struct GrokIntegrationContractTests {
    @Test
    func installedGrokHelpStillAdvertisesLeaderSocket() throws {
        let help = try grokHelp()
        #expect(
            help.contains("--leader-socket <PATH>"),
            Comment(rawValue: """
            installed Grok --help no longer advertises --leader-socket <PATH>, \
            which Coinor passes from GrokLaunch.swift. Check the Grok release \
            for a renamed flag.
            """)
        )
        #expect(
            help.contains("agent"),
            Comment(rawValue: """
            installed Grok --help no longer lists the agent subcommand Coinor \
            drives via grok --leader-socket <socket> agent --leader stdio.
            """)
        )
    }

    @Test
    func installedGrokAgentHelpStillAdvertisesTheLeaderStdioContract() throws {
        let agentHelp = try grokAgentHelp()
        #expect(
            agentHelp.contains("stdio"),
            Comment(rawValue: """
            installed Grok agent --help no longer offers the stdio subcommand \
            that GrokControlLaunch.arguments appends after agent.
            """)
        )
        #expect(
            agentHelp.contains("--leader"),
            Comment(rawValue: """
            installed Grok agent --help no longer offers the --leader flag \
            that GrokControlLaunch.arguments passes to the stdio agent.
            """)
        )
        #expect(
            agentHelp.contains("agent leader") || agentHelp.contains("--leader"),
            Comment(rawValue: """
            installed Grok agent --help no longer contains the agent leader \
            wording RemoteHostLiveTests matches in the leader process line.
            """)
        )
    }

    @Test
    func installedGrokVersionStillMatchesTheVersionRegexIncludingOverlaySuffix()
        throws
    {
        let version = try installedGrokVersion()
        let parsed = GrokForkVersion(text: version)
        #expect(
            parsed != nil,
            Comment(rawValue: """
            installed Grok --version output \(version) no longer matches \
            GrokForkVersion. A miss silently disables the update check.
            """)
        )
        let fork = try #require(parsed)
        let suffix = fork.overlay > 0 ? "-overlay.\(fork.overlay)" : ""
        let expectedPrefix = "\(fork.major).\(fork.minor).\(fork.patch)\(suffix)"
        #expect(
            version.contains(expectedPrefix),
            Comment(rawValue: """
            installed Grok --version output \(version) does not contain the \
            parsed version \(expectedPrefix).
            """)
        )
    }

    @Test
    func installedGrokHonorsTheVersionFlagSpelling() throws {
        let version = try installedGrokVersion()
        #expect(
            !version.isEmpty,
            Comment(rawValue: """
            installed Grok returned empty output for --version.
            """)
        )
    }

    @Test
    func installedGrokSessionLayoutMatchesTheTranscriptPathConvention() throws {
        let root = GrokSessionTranscriptLocator.defaultRoot()
        let fileName = GrokSessionTranscriptLocator.transcriptFileName
        #expect(
            root.lastPathComponent
                == GrokSessionTranscriptLocator.sessionsDirectoryName,
            Comment(rawValue: """
            GrokSessionTranscriptLocator.defaultRoot() last component is \
            \(root.lastPathComponent), expected \
            \(GrokSessionTranscriptLocator.sessionsDirectoryName).
            """)
        )

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            Issue.record(
                Comment(rawValue: """
                no sessions tree present to pin against disk; convention \
                constants still asserted. Expected \(root.path).
                """)
            )
            return
        }

        var matchingTranscript: URL?
        let cwdDirectories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for cwdDirectory in cwdDirectories {
            let sessionDirectories = (try? fileManager.contentsOfDirectory(
                at: cwdDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for sessionDirectory in sessionDirectories {
                let transcript = sessionDirectory.appendingPathComponent(
                    fileName,
                    isDirectory: false
                )
                if fileManager.isReadableFile(atPath: transcript.path) {
                    matchingTranscript = transcript
                    break
                }
            }
            if matchingTranscript != nil { break }
        }

        guard let matchingTranscript else {
            Issue.record(
                Comment(rawValue: """
                the sessions tree at \(root.path) has no \
                <cwd>/<session-id>/\(fileName) file. Conversation search \
                would silently find nothing.
                """)
            )
            return
        }

        #expect(matchingTranscript.lastPathComponent == fileName)
        let sessionDirectory = matchingTranscript.deletingLastPathComponent()
        let cwdDirectory = sessionDirectory.deletingLastPathComponent()
        #expect(!sessionDirectory.lastPathComponent.isEmpty)
        #expect(
            cwdDirectory.standardizedFileURL.path
                != root.standardizedFileURL.path,
            Comment(rawValue: """
            transcript \(matchingTranscript.path) is not nested two levels \
            under the sessions root.
            """)
        )
    }

    @Test
    func installedGrokSkillsLayoutMatchesTheInstallerConvention() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let skillsRoot = home
            .appendingPathComponent(
                GrokSkillInstaller.grokHomeDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                GrokSkillInstaller.skillsDirectoryName,
                isDirectory: true
            )
        #expect(
            skillsRoot.lastPathComponent
                == GrokSkillInstaller.skillsDirectoryName
        )

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: skillsRoot.path) else {
            Issue.record(
                Comment(rawValue: """
                no skills tree present to pin against disk; convention \
                constants still asserted. Expected \(skillsRoot.path).
                """)
            )
            return
        }

        let installedDirectories = (try? fileManager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let installedNames = Set(installedDirectories.map(\.lastPathComponent))
        for skill in GrokSkillDescriptor.all {
            #expect(
                installedNames.contains(skill.directoryName),
                Comment(rawValue: """
                skills tree at \(skillsRoot.path) has no \
                \(skill.directoryName) directory.
                """)
            )
        }
    }

    private func grokHelp() throws -> String {
        try runGrok(arguments: ["--help"])
    }

    private func grokAgentHelp() throws -> String {
        try runGrok(arguments: ["agent", "--help"])
    }

    private func installedGrokVersion() throws -> String {
        let text = try runGrok(arguments: ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n").first.map(String.init)
        return firstLine
            ?? text
    }

    private func runGrok(arguments: [String]) throws -> String {
        let executable = try #require(
            try? GrokExecutable.resolve(),
            Comment(rawValue: """
            Grok executable is required at \
            \(GrokExecutable.defaultConfiguredPath) to pin the integration \
            contract; install a jattento/grok-build release there.
            """)
        )
        let process = Process()
        process.executableURL = executable.url
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: """
            \(executable.path) \(arguments.joined(separator: " ")) exited \
            \(process.terminationStatus).
            """)
        )
        return text
    }
}
