import Foundation
import XCTest

@testable import Coinor

final class HookInstallationValidatorTests: XCTestCase {
    func testValidTemporaryInstallationPasses() throws {
        let fixture = try HookInstallationFixture()

        let check = fixture.validate()

        XCTAssertEqual(check.status, .passed)
        XCTAssertEqual(check.detail, "~/.grok/hooks")
    }

    func testInstalledRelayMustBeExecutableAndMatchBundle() throws {
        let fixture = try HookInstallationFixture()
        try fixture.setInstalledRelayExecutable(false)

        var check = fixture.validate()
        XCTAssertEqual(check.status, .warning)
        XCTAssertEqual(
            check.detail,
            "Installed relay is not executable at ~/.grok/hooks/coinor-hook-relay"
        )

        try fixture.setInstalledRelayExecutable(true)
        try Data("different relay".utf8).write(to: fixture.paths.hookRelay)

        check = fixture.validate()
        XCTAssertEqual(check.status, .warning)
        XCTAssertEqual(check.detail, "Installed relay does not match this Coinor build")
    }

    func testRegistrationContractRejectsEveryMalformedField() throws {
        let fixture = try HookInstallationFixture()
        let cases: [(String, (inout [String: Any]) -> Void, String)] = [
            (
                "ownership marker",
                { $0.removeValue(forKey: "_coinor") },
                "Coinor ownership marker is missing"
            ),
            (
                "schema",
                { document in
                    document["_coinor"] = [
                        "schemaVersion": 2,
                        "purpose": "Coinor lifecycle relay",
                    ]
                },
                "Coinor hook schema version must be 1"
            ),
            (
                "events",
                { document in
                    var hooks = document["hooks"] as! [String: Any]
                    hooks.removeValue(forKey: "SessionEnd")
                    document["hooks"] = hooks
                },
                "Coinor hook events do not match this build"
            ),
            (
                "command",
                {
                    Self.mutateFirstHandler(in: &$0) {
                        $0["command"] = "/tmp/wrong-relay"
                    }
                },
                "SessionStart has an unexpected relay command"
            ),
            (
                "socket",
                {
                    Self.mutateFirstHandler(in: &$0) { handler in
                        var environment = handler["env"] as! [String: Any]
                        environment["COINOR_HOOK_SOCKET"] = "/tmp/wrong.sock"
                        handler["env"] = environment
                    }
                },
                "SessionStart has an unexpected Coinor hook socket"
            ),
            (
                "handler timeout",
                {
                    Self.mutateFirstHandler(in: &$0) {
                        $0["timeout"] = 3
                    }
                },
                "SessionStart hook timeout must be 2 seconds"
            ),
            (
                "relay timeout",
                {
                    Self.mutateFirstHandler(in: &$0) { handler in
                        var environment = handler["env"] as! [String: Any]
                        environment["COINOR_HOOK_TIMEOUT_MS"] = "250"
                        handler["env"] = environment
                    }
                },
                "SessionStart relay timeout must be 150 milliseconds"
            ),
        ]

        for (name, mutation, expectedDetail) in cases {
            var registration = fixture.validRegistration()
            mutation(&registration)
            try fixture.writeRegistration(registration)

            let check = fixture.validate()

            XCTAssertEqual(check.status, .warning, name)
            XCTAssertEqual(check.detail, expectedDetail, name)
        }
    }

    private static func mutateFirstHandler(
        in document: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) {
        var hooks = document["hooks"] as! [String: Any]
        var groups = hooks["SessionStart"] as! [[String: Any]]
        var handlers = groups[0]["hooks"] as! [[String: Any]]
        mutation(&handlers[0])
        groups[0]["hooks"] = handlers
        hooks["SessionStart"] = groups
        document["hooks"] = hooks
    }
}

private final class HookInstallationFixture {
    let root: URL
    let paths: StartupPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoinorHookValidation-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let resources = root
            .appendingPathComponent("Coinor.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        paths = StartupPaths.live(
            homeDirectory: home,
            bundleResources: resources
        )

        try FileManager.default.createDirectory(
            at: paths.hookRegistration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )

        let relay = Data("bundled relay".utf8)
        try relay.write(to: paths.bundledHookRelay)
        try relay.write(to: paths.hookRelay)
        try setExecutable(paths.bundledHookRelay, true)
        try setExecutable(paths.hookRelay, true)
        try writeRegistration(validRegistration())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func validate() -> StartupCheck {
        HookInstallationValidator(paths: paths, probe: .live).startupCheck()
    }

    func setInstalledRelayExecutable(_ executable: Bool) throws {
        try setExecutable(paths.hookRelay, executable)
    }

    func validRegistration() -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": paths.hookRelay.path,
            "timeout": 2,
            "env": [
                "COINOR_HOOK_SOCKET": paths.leaderSocket
                    .deletingLastPathComponent()
                    .appendingPathComponent("hook.sock")
                    .path,
                "COINOR_HOOK_TIMEOUT_MS": "150",
            ],
        ]
        return [
            "_coinor": [
                "schemaVersion": 1,
                "purpose": "Coinor lifecycle relay",
            ],
            "hooks": Dictionary(
                uniqueKeysWithValues: HookInstallationValidator.events.map {
                    ($0, [["hooks": [handler]]])
                }
            ),
        ]
    }

    func writeRegistration(_ registration: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: registration,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: paths.hookRegistration)
    }

    private func setExecutable(_ url: URL, _ executable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
    }
}
