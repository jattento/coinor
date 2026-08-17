import Foundation
import Testing

@testable import Coinor

/// Runs the real `ssh` binary with the arguments Conan Code composes.
///
/// Text assertions cannot prove that OpenSSH accepts an option set or that a
/// failed connection is really reported as 255, which is the premise the pane
/// reconnect policy is built on. These tests never reach the network: a
/// `ProxyCommand` that immediately fails stands in for an unreachable host.
@Suite
struct SSHInvocationExecutionTests {
    private let alias = RemoteHostAlias(rawValue: "coinor-offline-test")!

    private func ssh() throws -> SSHCommand {
        // The real control socket lives under `Application Support`, so the
        // path used here contains a space on purpose: OpenSSH's configuration
        // lexer rejects an unquoted value that has one.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("coinor ssh \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // The control path lives directly in the temporary directory because
        // `sockaddr_un` limits how long it may be.
        return SSHCommand(
            alias: alias,
            controlPath: directory.appendingPathComponent("c.sock").path
        )
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: SSHCommand.executablePath,
            isDirectory: false
        )
        // `ProxyCommand=false` fails the connection immediately and offline.
        process.arguments = ["-o", "ProxyCommand=false"] + arguments
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    @Test
    func theDefaultControlPathIsQuotedBecauseApplicationSupportHasASpace() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("Coinor", isDirectory: true)
        let command = SSHCommand(alias: alias, supportDirectory: support)
        let arguments = command.arguments(
            remoteCommand: "true",
            allocateTTY: false,
            batch: true
        )
        let controlOption = try #require(
            arguments.first { $0.hasPrefix("ControlPath=") }
        )

        #expect(controlOption.contains("\""))
        let result = try run(arguments)
        #expect(!result.error.contains("extra arguments at end of line"))
        #expect(!result.error.contains("Bad configuration option"))
    }

    @Test
    func opensshAcceptsEveryOptionConanCodeSends() throws {
        let command = try ssh()
        let result = try run(
            command.arguments(
                remoteCommand: "true",
                allocateTTY: false,
                batch: true
            )
        )

        #expect(!result.error.contains("Bad configuration option"))
        #expect(!result.error.contains("unknown option"))
        #expect(!result.error.contains("command-line: line 0"))
    }

    @Test
    func theOptionEndMarkerIsAcceptedBeforeTheDestination() throws {
        let command = try ssh()
        let arguments = command.arguments(
            remoteCommand: "true",
            allocateTTY: false,
            batch: true
        )
        let separatorIndex = try #require(arguments.firstIndex(of: "--"))

        #expect(separatorIndex == arguments.count - 3)
        let result = try run(arguments)

        // Parsed cleanly and reached the connection attempt, which
        // ProxyCommand=false fails. An option parse error would exit 1 with
        // a usage message instead of 255.
        #expect(result.status == Int32(RemoteReconnectPolicy.sshFailureExitCode))
    }

    @Test
    func opensshAcceptsTheInteractivePaneInvocation() throws {
        let command = try ssh()
        let result = try run(
            command.arguments(
                remoteCommand: SSHCommand.remoteCommand(
                    executable: "/usr/bin/true",
                    arguments: ["--leader-socket", "/tmp/a b.sock"],
                    workingDirectory: "/tmp/with space",
                    environment: ["LC_ALL": "C"]
                ),
                allocateTTY: true,
                batch: false
            )
        )

        #expect(!result.error.contains("Bad configuration option"))
        #expect(!result.error.contains("unknown option"))
    }

    @Test
    func anUnreachableHostExitsWithTheStatusTheReconnectPolicyWaitsFor() throws {
        let command = try ssh()
        let result = try run(
            command.arguments(
                remoteCommand: "true",
                allocateTTY: false,
                batch: true
            )
        )

        #expect(result.status == Int32(RemoteReconnectPolicy.sshFailureExitCode))
        #expect(
            RemoteReconnectPolicy().shouldReconnect(
                exitCode: UInt32(result.status),
                completedAttempts: 0
            )
        )
    }

    @Test
    func aPaneCommandForARemoteConversationStartsWithSSH() throws {
        let command = try ssh()
        let launch = TerminalLaunchRequest(
            sessionID: "11111111-2222-3333-4444-555555555555",
            workingDirectory: "/Users/remote/projects/repo",
            grokExecutable: "/Users/remote/bin/grok",
            leaderSocket: "/Users/remote/Library/Coinor/leader.sock",
            mode: .resume,
            remote: RemoteExecution(ssh: command)
        )

        // The composed pane command is a single shell string, so it is proved
        // by running it: `env` echoes back exactly what a shell parsed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
        process.arguments = [
            "-c",
            "printf '%s\\n' " + launch.shellCommand.dropFirst(0),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let words = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(words.first == SSHCommand.executablePath)
        #expect(words.contains(alias.rawValue))
        // The whole remote program must survive as one argument.
        let remoteProgram = try #require(words.last)
        #expect(remoteProgram.contains("cd '/Users/remote/projects/repo'"))
        #expect(remoteProgram.contains("'--resume' "
            + "'11111111-2222-3333-4444-555555555555'"))
    }
}
