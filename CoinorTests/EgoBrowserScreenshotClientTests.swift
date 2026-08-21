import Foundation
import Testing

@testable import Coinor

private func temporaryStub(_ script: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ego-browser-stub-\(UUID().uuidString)",
            isDirectory: false
        )
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
    )
    return url
}

@Test
func scriptEncodesTheTaskSpaceNameAsASafeJSONStringLiteral() {
    let script = EgoBrowserScreenshotClient.script(
        taskSpaceName: "a \"quoted\" space's name",
        quality: 42
    )

    #expect(
        script.contains(
            #"useOrCreateTaskSpace("a \"quoted\" space's name")"#
        )
    )
    #expect(script.contains("quality: 42"))
    #expect(script.contains("Page.captureScreenshot"))
}

@Test
func parseDecodesTheLoggedJSONLineIntoAFrame() {
    let payload = #"{"ok":true,"jpeg":"dGVzdA==","url":"https://example.com","title":"Example"}"#
    let result = EgoBrowserScreenshotClient.parse(
        stdout: Data(payload.utf8)
    )

    switch result {
    case .success(let frame):
        #expect(frame.jpegData == Data("test".utf8))
        #expect(frame.url == "https://example.com")
        #expect(frame.title == "Example")
    case .failure(let error):
        Issue.record("expected success, got \(error)")
    }
}

/// ego-browser can append an out-of-band "update available" trailer line
/// after the script's own output; parsing must find the real payload
/// regardless of where that trailer lands.
@Test
func parseFindsTheFrameLineEvenWithATrailingUnrelatedLine() {
    let payload = """
        {"ok":true,"jpeg":"dGVzdA==","url":null,"title":null}
        ego lite 0.5.0 is available
        """
    let result = EgoBrowserScreenshotClient.parse(
        stdout: Data(payload.utf8)
    )

    guard case .success(let frame) = result else {
        Issue.record("expected success")
        return
    }
    #expect(frame.jpegData == Data("test".utf8))
}

@Test
func parseReportsMissingFrameWhenJpegFieldIsAbsent() {
    let result = EgoBrowserScreenshotClient.parse(
        stdout: Data(#"{"ok":true,"jpeg":null}"#.utf8)
    )

    #expect(result == .failure(.missingFrame))
}

@Test
func parseReportsMalformedOutputWhenNothingDecodes() {
    let result = EgoBrowserScreenshotClient.parse(
        stdout: Data("not json at all".utf8)
    )

    #expect(result == .failure(.malformedOutput))
}

@Test
func captureScreenshotDrivesARealStubbedProcessAndParsesItsOutput() async throws {
    let invocations = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        printf '%s\\n' "$1" >> "\(invocations.path)"
        printf '{"ok":true,"jpeg":"dGVzdA==","url":"https://example.com","title":"Example"}\\n'
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let client = EgoBrowserScreenshotClient(executablePath: stub.path)
    let result = await client.captureScreenshot(taskSpaceName: "spike")

    guard case .success(let frame) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(frame.jpegData == Data("test".utf8))
    #expect(frame.url == "https://example.com")

    let calls = try String(contentsOf: invocations, encoding: .utf8)
    #expect(calls.trimmingCharacters(in: .newlines) == "nodejs")
}

/// ego-browser's own choice of output stream is not a contract Coinor
/// controls; a live diagnostic against the real installed CLI proved it can
/// write its JSON result to stderr rather than stdout on a clean exit
/// depending on how the process was launched. The client must not depend on
/// which stream it picked.
@Test
func captureScreenshotSucceedsWhenTheCLIPrintsItsResultToStderrInstead() async throws {
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        printf '{"ok":true,"jpeg":"dGVzdA==","url":"https://example.com","title":"Example"}\\n' 1>&2
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let client = EgoBrowserScreenshotClient(executablePath: stub.path)
    let result = await client.captureScreenshot(taskSpaceName: "spike")

    guard case .success(let frame) = result else {
        Issue.record("expected success, got \(result)")
        return
    }
    #expect(frame.jpegData == Data("test".utf8))
}

@Test
func captureScreenshotReportsNonZeroExitWithStderr() async throws {
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        echo "boom" 1>&2
        exit 3
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let client = EgoBrowserScreenshotClient(executablePath: stub.path)
    let result = await client.captureScreenshot(taskSpaceName: "spike")

    #expect(result == .failure(.nonZeroExit(code: 3, message: "boom")))
}

@Test
func captureScreenshotTimesOutOnAHangingProcess() async throws {
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        sleep 5
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let client = EgoBrowserScreenshotClient(
        executablePath: stub.path,
        timeout: .milliseconds(200)
    )
    let result = await client.captureScreenshot(taskSpaceName: "spike")

    #expect(result == .failure(.timedOut))
}

@Test
func captureScreenshotReportsLaunchFailureForAMissingExecutable() async {
    let client = EgoBrowserScreenshotClient(
        executablePath: "/nonexistent/ego-browser-\(UUID().uuidString)"
    )
    let result = await client.captureScreenshot(taskSpaceName: "spike")

    guard case .failure(.launchFailed) = result else {
        Issue.record("expected .launchFailed, got \(result)")
        return
    }
}
