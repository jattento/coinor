import Foundation
import Testing

@testable import Coinor

private struct TemporaryVersionExecutable {
    let directory: URL
    let launch: GrokControlLaunch

    init(script: String) throws {
        let fileManager = FileManager.default
        directory = URL(
            fileURLWithPath: "/tmp/cv-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let executableURL = directory.appendingPathComponent("grok")
        try Data(script.utf8).write(to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        launch = GrokControlLaunch(
            executable: try GrokExecutable.resolve(
                configuredPath: executableURL.path
            ),
            leaderSocket: try GrokLeaderSocket(
                path: directory.appendingPathComponent("leader.sock").path
            ),
            workingDirectory: directory,
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test
func executableVersionProbeRunsTheAbsoluteBinaryAndRecordsItsOutput() async throws {
    let fixture = try TemporaryVersionExecutable(
        script: """
        #!/bin/sh
        test "$1" = "--version" || exit 9
        printf 'grok 0.2.117-local\n'
        """
    )
    defer { fixture.remove() }

    let version = try await GrokExecutableVersionProbe().run(
        launch: fixture.launch,
        timeout: .seconds(5)
    )

    #expect(version == "grok 0.2.117-local")
}

@Test
func executableVersionProbeSurfacesACommandFailure() async throws {
    let fixture = try TemporaryVersionExecutable(
        script: """
        #!/bin/sh
        printf 'unsupported local build\n' >&2
        exit 7
        """
    )
    defer { fixture.remove() }

    await #expect(
        throws: GrokControlError.executableVersionFailed(
            path: fixture.launch.executable.path,
            status: 7,
            diagnostics: "unsupported local build"
        )
    ) {
        _ = try await GrokExecutableVersionProbe().run(
            launch: fixture.launch,
            timeout: .seconds(5)
        )
    }
}

@Test
func executableVersionProbeRejectsEmptyVersionOutput() async throws {
    let fixture = try TemporaryVersionExecutable(
        script: """
        #!/bin/sh
        exit 0
        """
    )
    defer { fixture.remove() }

    await #expect(
        throws: GrokControlError.executableVersionEmpty(
            fixture.launch.executable.path
        )
    ) {
        _ = try await GrokExecutableVersionProbe().run(
            launch: fixture.launch,
            timeout: .seconds(5)
        )
    }
}

@Test
func executableVersionProbeKillsACommandThatWouldOtherwiseHang() async throws {
    let fixture = try TemporaryVersionExecutable(
        script: """
        #!/bin/sh
        exec /bin/sleep 5
        """
    )
    defer { fixture.remove() }
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
        _ = try await GrokExecutableVersionProbe().run(
            launch: fixture.launch,
            timeout: .milliseconds(50)
        )
        Issue.record("expected the version probe to time out")
    } catch let error as GrokControlError {
        guard case let .executableVersionTimedOut(path, seconds) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
        #expect(path == fixture.launch.executable.path)
        #expect(seconds >= 0.05 && seconds < 0.051)
    }

    // The probe now waits for SIGTERM/SIGKILL to land instead of only
    // scheduling them. Under a full suite that still has to beat the
    // 5 second sleep, not a 1 second fire-and-forget budget.
    #expect(clock.now - startedAt < .seconds(2))
}
