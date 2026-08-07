import Foundation

struct HookInstallationValidator: Sendable {
    static let schemaVersion = 1
    static let ownershipPurpose = "Coinor lifecycle relay"
    static let handlerTimeoutSeconds = 2
    static let relayTimeoutMilliseconds = "150"
    static let events = [
        "SessionStart",
        "SubagentStart",
        "SubagentStop",
        "SessionEnd",
    ]

    let paths: StartupPaths
    let probe: StartupFileProbe

    func startupCheck() -> StartupCheck {
        let hooksDirectory = paths.display(
            paths.hookRegistration.deletingLastPathComponent()
        )
        let registrationExists = probe.exists(paths.hookRegistration)
        let relayExists = probe.exists(paths.hookRelay)

        switch (registrationExists, relayExists) {
        case (false, false):
            return result(.failed, "Not registered in \(hooksDirectory)")
        case (true, false):
            return result(.warning, "Relay missing in \(hooksDirectory)")
        case (false, true):
            return result(.warning, "Handler missing in \(hooksDirectory)")
        case (true, true):
            break
        }

        guard probe.exists(paths.bundledHookRelay) else {
            return result(.failed, "Bundled relay missing from Coinor.app")
        }
        guard probe.isExecutable(paths.bundledHookRelay) else {
            return result(.failed, "Bundled relay in Coinor.app is not executable")
        }
        guard probe.isExecutable(paths.hookRelay) else {
            return result(
                .warning,
                "Installed relay is not executable at \(paths.display(paths.hookRelay))"
            )
        }
        guard let bundledRelay = probe.readData(paths.bundledHookRelay),
              let installedRelay = probe.readData(paths.hookRelay)
        else {
            return result(.warning, "Coinor could not read the hook relay binaries")
        }
        guard bundledRelay == installedRelay else {
            return result(.warning, "Installed relay does not match this Coinor build")
        }
        guard let registrationData = probe.readData(paths.hookRegistration) else {
            return result(
                .warning,
                "Coinor could not read \(paths.display(paths.hookRegistration))"
            )
        }

        do {
            try validateRegistration(registrationData)
        } catch let issue as RegistrationIssue {
            return result(.warning, issue.detail)
        } catch {
            return result(.warning, "Hook registration is invalid")
        }

        return result(.passed, hooksDirectory)
    }

    private func validateRegistration(_ data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RegistrationIssue("Hook registration is not valid JSON")
        }

        guard let document = value as? [String: Any] else {
            throw RegistrationIssue("Hook registration must be a JSON object")
        }
        guard let owner = document["_coinor"] as? [String: Any] else {
            throw RegistrationIssue("Coinor ownership marker is missing")
        }
        guard owner["schemaVersion"] as? Int == Self.schemaVersion else {
            throw RegistrationIssue("Coinor hook schema version must be 1")
        }
        guard owner["purpose"] as? String == Self.ownershipPurpose else {
            throw RegistrationIssue("Coinor hook ownership purpose is invalid")
        }
        guard let hooks = document["hooks"] as? [String: Any],
              Set(hooks.keys) == Set(Self.events)
        else {
            throw RegistrationIssue("Coinor hook events do not match this build")
        }

        for event in Self.events {
            guard let groups = hooks[event] as? [[String: Any]],
                  groups.count == 1,
                  let handlers = groups[0]["hooks"] as? [[String: Any]],
                  handlers.count == 1
            else {
                throw RegistrationIssue("\(event) must contain exactly one hook handler")
            }

            let handler = handlers[0]
            guard handler["type"] as? String == "command" else {
                throw RegistrationIssue("\(event) hook type must be command")
            }
            guard handler["command"] as? String == paths.hookRelay.path else {
                throw RegistrationIssue("\(event) has an unexpected relay command")
            }
            guard handler["timeout"] as? Int == Self.handlerTimeoutSeconds else {
                throw RegistrationIssue("\(event) hook timeout must be 2 seconds")
            }
            guard let environment = handler["env"] as? [String: Any],
                  Set(environment.keys) == [
                      "COINOR_HOOK_SOCKET",
                      "COINOR_HOOK_TIMEOUT_MS",
                  ]
            else {
                throw RegistrationIssue("\(event) hook environment is invalid")
            }
            guard environment["COINOR_HOOK_SOCKET"] as? String
                    == paths.hookSocket.path
            else {
                throw RegistrationIssue("\(event) has an unexpected Coinor hook socket")
            }
            guard environment["COINOR_HOOK_TIMEOUT_MS"] as? String
                    == Self.relayTimeoutMilliseconds
            else {
                throw RegistrationIssue("\(event) relay timeout must be 150 milliseconds")
            }
        }
    }

    private func result(
        _ status: StartupCheck.Status,
        _ detail: String
    ) -> StartupCheck {
        StartupCheck(kind: .hookRegistration, status: status, detail: detail)
    }
}

private struct RegistrationIssue: Error {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }
}

private extension StartupPaths {
    var hookSocket: URL {
        leaderSocket
            .deletingLastPathComponent()
            .appendingPathComponent("hook.sock")
    }
}
