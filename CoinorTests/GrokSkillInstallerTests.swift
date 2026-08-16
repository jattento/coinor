import Foundation
import Testing

@testable import Coinor

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CoinorSkillInstaller-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: home,
        withIntermediateDirectories: true
    )
    return home
}

@Test
func skillInstallerShipsEveryConanCodeSkill() {
    let directories = GrokSkillDescriptor.all.map(\.directoryName)

    #expect(directories.contains("conan-code-long-running"))
    #expect(directories.contains("sidechat"))
    #expect(directories.contains("provider-health"))
}

/// The script is shipped, not compiled, so nothing else would catch a syntax
/// error in it before the user runs a provider check for real.
@Test
func installedProviderHealthScriptParsesAndReportsWithoutAnyProviderTooling()
    throws
{
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try GrokSkillInstaller(skills: [.providerHealth]).install(homeDirectory: home)
    let script = home
        .appendingPathComponent(".grok/skills/provider-health/provider-health.sh")
        .path

    let syntax = try runShell(arguments: ["-n", script], environment: [:])
    #expect(syntax.status == 0, Comment(rawValue: syntax.output))

    // A machine with neither cliproxyapi nor codexbar must still get a report
    // naming what is missing, rather than a crash or an empty run. `PATH` is
    // stripped to the system binaries so no real provider tooling is found.
    let bare = try runShell(
        arguments: [script, "check"],
        environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "GROK_HOME": home.appendingPathComponent(".grok").path,
            "PROVIDER_HEALTH_CLIPROXY_BIN": "",
            "PROVIDER_HEALTH_CLIPROXY_CONF": "",
        ]
    )
    #expect(bare.status == 2, Comment(rawValue: bare.output))
    #expect(bare.output.contains("cliproxyapi"))
    #expect(bare.output.contains("not installed"))
}

/// The skill drives a real OAuth flow against a real account, so pin the three
/// invariants that keep that safe: no secret is ever printed, no password is
/// ever typed because the browser already holds the session, and the account is
/// chosen by exact email — several Google accounts are signed in and picking
/// the wrong one silently binds the wrong identity.
@Test
func providerHealthSkillDocumentsItsSecretHandling() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try GrokSkillInstaller(skills: [.providerHealth]).install(homeDirectory: home)
    let skill = try String(
        contentsOf: home.appendingPathComponent(
            ".grok/skills/provider-health/SKILL.md"
        ),
        encoding: .utf8
    )

    #expect(skill.contains("never prints, copies, or transmits a secret value"))
    #expect(skill.contains("no password is ever typed"))
    #expect(skill.contains("jose.attento@gmail.com"))
    #expect(skill.contains("match the email exactly"))
}

@Test
func skillInstallerWritesEveryBundledSkillIntoTheGrokSkillsDirectory() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try GrokSkillInstaller().install(homeDirectory: home)

    for skill in GrokSkillDescriptor.all {
        let directory = home
            .appendingPathComponent(".grok/skills", isDirectory: true)
            .appendingPathComponent(skill.directoryName, isDirectory: true)
        for file in skill.files {
            let installed = directory.appendingPathComponent(
                file.installedName,
                isDirectory: false
            )
            let contents = try Data(contentsOf: installed)
            #expect(!contents.isEmpty)

            let attributes = try FileManager.default
                .attributesOfItem(atPath: installed.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == file.permissions)
        }
    }
}

@Test
func installedSidechatSkillTargetsConanCodeAndNotHerdr() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try GrokSkillInstaller(skills: [.sidechat]).install(homeDirectory: home)

    let directory = home
        .appendingPathComponent(".grok/skills/sidechat", isDirectory: true)
    let scriptURL = directory.appendingPathComponent("sidechat.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)
    let skill = try String(
        contentsOf: directory.appendingPathComponent("SKILL.md"),
        encoding: .utf8
    )

    for text in [script, skill] {
        #expect(!text.lowercased().contains("herdr"))
    }
    #expect(script.contains("CONAN_CODE_CONTROL_CLIENT"))
    #expect(script.contains("CONAN_CODE_REQUEST_ID"))
    #expect(script.contains("--fork-session"))
    #expect(script.contains("--session-id"))
    #expect(skill.contains("CONAN_CODE_REQUEST_ID"))
    #expect(skill.contains("Conan Code"))
}

/// The script is shipped, not compiled, so nothing else would catch a syntax
/// error in it before the user runs `sidechat` for real.
@Test
func installedSidechatScriptParsesAndRefusesToRunOutsideConanCode() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }

    try GrokSkillInstaller(skills: [.sidechat]).install(homeDirectory: home)
    let script = home
        .appendingPathComponent(".grok/skills/sidechat/sidechat.sh")
        .path

    let syntax = try runShell(arguments: ["-n", script], environment: [:])
    #expect(syntax.status == 0, Comment(rawValue: syntax.output))

    let outsideConanCode = try runShell(
        arguments: [script, "a side chat"],
        environment: ["PATH": "/usr/bin:/bin", "HOME": home.path]
    )
    #expect(outsideConanCode.status == 1)
    #expect(
        outsideConanCode.output.contains("not running inside Conan Code"),
        Comment(rawValue: outsideConanCode.output)
    )

    let missingRequestID = try runShell(
        arguments: [script],
        environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "CONAN_CODE_CONTROL_CLIENT": "/bin/echo",
        ]
    )
    #expect(missingRequestID.status == 1)
    #expect(
        missingRequestID.output.contains("CONAN_CODE_REQUEST_ID is required"),
        Comment(rawValue: missingRequestID.output)
    )
}

/// Drives the shipped script against a stub control client that answers exactly
/// what `TerminalControlServer` answers, so the create/status/execute sequence
/// and the composed fork command are exercised for real.
@Test
func sidechatForksTheLiveSessionIntoANewConanCodeTab() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let fileManager = FileManager.default

    try GrokSkillInstaller(skills: [.sidechat]).install(homeDirectory: home)
    let script = home
        .appendingPathComponent(".grok/skills/sidechat/sidechat.sh")
        .path

    let sessionID = "019ffd00-0000-7000-8000-00000000beef"
    let workingDirectory = home
        .appendingPathComponent("project", isDirectory: true)
    try fileManager.createDirectory(
        at: workingDirectory,
        withIntermediateDirectories: true
    )
    // The roster records the same path the shell reports in `$PWD`, which under
    // `/var/folders` is the `/private`-prefixed real path Foundation leaves
    // alone. The entry also has to name a process that is actually alive,
    // because the script skips dead sessions.
    let resolvedPath = try #require(realpath(workingDirectory.path, nil))
    let resolvedWorkingDirectory = String(cString: resolvedPath)
    free(resolvedPath)
    let roster = """
        [{"session_id":"\(sessionID)","pid":\(ProcessInfo.processInfo.processIdentifier),\
        "cwd":"\(resolvedWorkingDirectory)",\
        "opened_at":"2026-08-13T00:00:00Z"}]
        """
    try roster.write(
        to: home.appendingPathComponent(".grok/active_sessions.json"),
        atomically: true,
        encoding: .utf8
    )
    let transcript = home
        .appendingPathComponent(".grok/sessions/project", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
    try fileManager.createDirectory(
        at: transcript,
        withIntermediateDirectories: true
    )
    try "{}\n".write(
        to: transcript.appendingPathComponent("updates.jsonl"),
        atomically: true,
        encoding: .utf8
    )

    let invocations = home.appendingPathComponent("invocations.log")
    let stubClient = home.appendingPathComponent("coinorctl-stub")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> "\(invocations.path)"
    case "$1" in
    create) echo '{"ok":true,"result":{"tabID":"tab-1","capability":"cap-1","state":"starting"}}' ;;
    status) echo '{"ok":true,"result":{"tabID":"tab-1","state":"idle"}}' ;;
    execute) echo '{"ok":true,"result":{"tabID":"tab-1","commandID":"cmd-1"}}' ;;
    *) echo '{"ok":false}'; exit 1 ;;
    esac
    """.write(to: stubClient, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: stubClient.path
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script, "a", "side", "chat"]
    process.currentDirectoryURL = workingDirectory
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "HOME": home.path,
        "CONAN_CODE_CONTROL_CLIENT": stubClient.path,
        "CONAN_CODE_REQUEST_ID": "11111111-2222-3333-4444-555555555555",
        "COINOR_GROK_EXECUTABLE": "/bin/echo",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    #expect(process.terminationStatus == 0, Comment(rawValue: output))

    let calls = try String(contentsOf: invocations, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    let create = try #require(calls.first { $0.hasPrefix("create ") })
    #expect(create.contains("--request-id 11111111-2222-3333-4444-555555555555"))
    #expect(create.contains("--title a side chat"))
    #expect(calls.contains { $0.hasPrefix("status ") })

    let execute = try #require(calls.first { $0.hasPrefix("execute ") })
    #expect(execute.contains("--tab tab-1"))
    #expect(execute.contains("--capability cap-1"))
    #expect(execute.contains("'/bin/echo' --resume \(sessionID) --fork-session --session-id "))

    #expect(output.contains("a side chat"))
    #expect(output.contains("tab     tab-1"))
    #expect(output.contains("parent  \(sessionID)"))

    // The fork must be a brand new session ID, never the parent's.
    let forkLine = try #require(
        output.split(separator: "\n").first { $0.contains("fork    ") }
    )
    let fork = forkLine.replacingOccurrences(of: "  fork    ", with: "")
        .trimmingCharacters(in: .whitespaces)
    #expect(fork != sessionID)
    #expect(fork.count == 36)
    #expect(fork == fork.lowercased())
    #expect(execute.contains("--session-id \(fork)"))
}

private func runShell(
    arguments: [String],
    environment: [String: String]
) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(decoding: data, as: UTF8.self)
    )
}
