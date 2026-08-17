import Darwin
import Foundation
import Testing

@testable import Coinor

private struct TemporaryCommand {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coinor-cmd-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        executable = directory.appendingPathComponent("command")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite
struct SubprocessOutputCaptureTests {
    @Test
    func aCommandThatExceedsItsDeadlineTimesOutAndIsNotLeftRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let capture = try SubprocessOutputCapture(label: "deadline")
        let directory = capture.directory
        let started = ContinuousClock.now

        #expect(throws: SubprocessCaptureError.timedOut) {
            try capture.run(process: process, deadline: .milliseconds(80))
        }

        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func outputBeyondTheBudgetIsTruncatedAndTheProcessExits() throws {
        let extra = 100
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coinor-bound-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let payload = Data(
            repeating: UInt8(ascii: "A"),
            count: SubprocessOutputCapture.byteBudget + extra
        )
        let file = scratch.appendingPathComponent("blob")
        try payload.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [file.path]
        let capture = try SubprocessOutputCapture(label: "bound")
        let result = try capture.run(process: process, deadline: .seconds(5))

        #expect(result.terminationStatus == 0)
        #expect(!process.isRunning)
        #expect(
            result.standardOutput.contains(
                SubprocessOutputCapture.truncationMarker(omittedByteCount: extra)
            )
        )
        #expect(result.standardOutput.hasPrefix(String(repeating: "A", count: 32)))
        #expect(result.standardOutput.hasSuffix(String(repeating: "A", count: 32)))
        #expect(
            !result.standardOutput.contains(
                String(repeating: "A", count: SubprocessOutputCapture.byteBudget)
            )
        )
    }

    @Test
    func workspaceIsRemovedOnSuccess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let capture = try SubprocessOutputCapture(label: "ok")
        let directory = capture.directory
        #expect(FileManager.default.fileExists(atPath: directory.path))

        let result = try capture.run(process: process, deadline: .seconds(5))

        #expect(result.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func workspaceIsRemovedOnLaunchFailure() throws {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/this/executable/does/not/exist"
        )
        let capture = try SubprocessOutputCapture(label: "launch-fail")
        let directory = capture.directory
        #expect(FileManager.default.fileExists(atPath: directory.path))

        #expect(throws: SubprocessCaptureError.self) {
            try capture.run(process: process, deadline: .seconds(5))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func workspaceIsRemovedAndTheProcessDiesOnCancellation() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let capture = try SubprocessOutputCapture(label: "cancel")
        let directory = capture.directory
        #expect(FileManager.default.fileExists(atPath: directory.path))

        let task = Task {
            try capture.run(process: process, deadline: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(!process.isRunning)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func timeoutKillsSpawnedDescendantsInTheProcessGroup() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coinor-pg-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let childPIDFile = scratch.appendingPathComponent("child.pid")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            """
            setpgrp(0, 0);
            my $child = fork();
            if ($child == 0) { sleep 60; exit 0; }
            open my $fh, ">", $ARGV[0] or die $!;
            print $fh $child;
            close $fh;
            sleep 60;
            """,
            "--",
            childPIDFile.path,
        ]
        let capture = try SubprocessOutputCapture(label: "pg")

        #expect(throws: SubprocessCaptureError.timedOut) {
            try capture.run(process: process, deadline: .seconds(1))
        }

        #expect(!process.isRunning)
        let childPID = Int32(
            (try? String(contentsOf: childPIDFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) ?? 0
        #expect(childPID > 1)
        var descendantAlive = true
        for _ in 0 ..< 25 {
            if Darwin.kill(childPID, 0) == -1, errno != EPERM {
                descendantAlive = false
                break
            }
            usleep(20_000)
        }
        #expect(!descendantAlive)
    }
}

@Suite
struct GitProcessRunnerDeadlineTests {
    @Test
    func successfulGitVersionStillReturnsOutput() throws {
        let runner = try GitProcessRunner()
        let result = try runner.run(
            arguments: ["--version"],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        #expect(result.succeeded)
        #expect(result.standardOutput.contains("git version"))
    }

    @Test
    func aHangingExecutableFailsWithCommandTimedOut() throws {
        let fixture = try TemporaryCommand(
            script: """
            #!/bin/sh
            echo $$ > "$(dirname "$0")/pid"
            exec /bin/sleep 30
            """
        )
        defer { fixture.remove() }
        let runner = try GitProcessRunner(executable: fixture.executable)
        let started = ContinuousClock.now

        do {
            _ = try runner.run(
                arguments: ["--hang"],
                workingDirectory: fixture.directory,
                deadline: .milliseconds(80)
            )
            Issue.record("expected the git runner to time out")
        } catch let error as GitServiceError {
            guard case let .commandTimedOut(arguments, directory, seconds) = error
            else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(arguments == ["--hang"])
            #expect(directory == fixture.directory.path)
            #expect(seconds >= 0.07 && seconds < 0.1)
            #expect(error.localizedDescription.contains("did not finish"))
        }

        #expect(ContinuousClock.now - started < .seconds(2))
        let pid = Int32(
            (try? String(
                contentsOf: fixture.directory.appendingPathComponent("pid"),
                encoding: .utf8
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) ?? 0
        if pid > 1 {
            #expect(Darwin.kill(pid, 0) == -1)
        }
    }

    @Test
    func oversizedOutputIsTruncatedThroughTheGitRunner() throws {
        let extra = 64
        let fixture = try TemporaryCommand(
            script: """
            #!/bin/sh
            exec /bin/cat "$1"
            """
        )
        defer { fixture.remove() }
        let blob = fixture.directory.appendingPathComponent("blob")
        try Data(
            repeating: UInt8(ascii: "B"),
            count: SubprocessOutputCapture.byteBudget + extra
        ).write(to: blob)

        let runner = try GitProcessRunner(executable: fixture.executable)
        let result = try runner.run(
            arguments: [blob.path],
            workingDirectory: fixture.directory,
            deadline: .seconds(5)
        )

        #expect(result.succeeded)
        #expect(
            result.standardOutput.contains(
                SubprocessOutputCapture.truncationMarker(omittedByteCount: extra)
            )
        )
    }
}

@Suite
struct GrokSubprocessTransportShutdownTests {
    @Test
    func shutdownWaitsUntilTheChildProcessHasExited() async throws {
        let fixture = try TemporaryCommand(
            script: """
            #!/bin/sh
            exec /bin/sleep 30
            """
        )
        defer { fixture.remove() }

        let launch = GrokControlLaunch(
            executable: try GrokExecutable.resolve(
                configuredPath: fixture.executable.path
            ),
            leaderSocket: try GrokLeaderSocket(
                path: "/tmp/cn-\(UUID().uuidString.prefix(8)).sock"
            ),
            workingDirectory: fixture.directory,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let transport = GrokSubprocessTransport(
            launch: launch,
            terminationGrace: .milliseconds(50)
        )
        _ = try transport.start()
        let started = ContinuousClock.now

        await transport.shutdown()

        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(throws: GrokControlError.notConnected) {
            try transport.send(Data([0x0A]))
        }
    }
}
