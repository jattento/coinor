import Foundation
import Testing

@testable import Coinor

private func temporaryStub(_ script: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ego-lite-activator-stub-\(UUID().uuidString)",
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
func scriptEncodesTheTaskSpaceNameAndActivatesItsTarget() {
    let script = EgoLiteActivator.script(
        taskSpaceName: "a \"quoted\" space's name"
    )

    #expect(
        script.contains(
            #"useOrCreateTaskSpace("a \"quoted\" space's name")"#
        )
    )
    #expect(script.contains("Target.activateTarget"))
    #expect(script.contains("currentTab()"))
}

/// Drives the real, shipped `activateTaskSpace` against a real stubbed
/// `ego-browser` subprocess (the same `EgoBrowserCLIRunner` the live poller
/// uses), asserting it reports success on a clean exit.
@Test
func activateTaskSpaceSucceedsAgainstAStubbedCLI() async throws {
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        printf '{"ok":true}\\n'
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let result = await EgoLiteActivator.activateTaskSpace(
        taskSpaceName: "spike",
        executablePath: stub.path
    )

    guard case .success = result else {
        Issue.record("expected success, got \(result)")
        return
    }
}

@Test
func activateTaskSpaceReportsNonZeroExit() async throws {
    let stub = try temporaryStub(
        """
        #!/bin/sh
        cat > /dev/null
        echo "boom" 1>&2
        exit 1
        """
    )
    defer { try? FileManager.default.removeItem(at: stub) }

    let result = await EgoLiteActivator.activateTaskSpace(
        taskSpaceName: "spike",
        executablePath: stub.path
    )

    guard case .failure(let error) = result else {
        Issue.record("expected failure, got \(result)")
        return
    }
    #expect(error == .nonZeroExit(code: 1, message: "boom"))
}
