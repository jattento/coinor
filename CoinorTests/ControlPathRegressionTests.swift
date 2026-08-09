import Foundation
import Testing

@testable import Coinor

/// The remote host flow used to fail on its very first step because Conan
/// Code's control socket lives under `Application Support`, whose space broke
/// OpenSSH's option parser. This runs the real `ssh` binary with the real
/// default path so the failure cannot come back.
@Suite
struct ControlPathRegressionTests {
    @Test
    func theRealDefaultControlPathIsAcceptedByOpenSSH() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("Coinor", isDirectory: true)
        let alias = try #require(RemoteHostAlias(rawValue: "coinor-offline-test"))
        let command = SSHCommand(alias: alias, supportDirectory: support)

        // The path really does contain a space on a stock macOS account.
        #expect(command.controlPath.contains(" "))
        try command.prepareControlDirectory()

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: SSHCommand.executablePath,
            isDirectory: false
        )
        process.arguments = ["-o", "ProxyCommand=false"]
            + command.arguments(
                remoteCommand: "true",
                allocateTTY: false,
                batch: true
            )
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)

        #expect(!message.contains("extra arguments at end of line"))
        #expect(!message.contains("keyword controlpath"))
        #expect(process.terminationStatus
            == Int32(RemoteReconnectPolicy.sshFailureExitCode))
    }
}
