import Foundation
import Testing

@testable import Coinor

@Suite
struct RemoteHostAliasTests {
    @Test(arguments: [
        "",
        "   ",
        "host name",
        "host;name",
        "host$name",
        "host'name",
        "host\"name",
        "host`name",
        "host\nname",
    ])
    func rejectsUnsafeAliases(_ rawValue: String) {
        #expect(RemoteHostAlias(rawValue: rawValue) == nil)
    }

    @Test(arguments: [
        "studio-mac",
        "dev.example.com",
        "host_01",
        "HOST",
    ])
    func acceptsOrdinaryAliases(_ rawValue: String) throws {
        let alias = try #require(RemoteHostAlias(rawValue: rawValue))

        #expect(alias.rawValue == rawValue)
    }

    @Test
    func codableRoundTripPreservesTheAlias() throws {
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))

        let encoded = try JSONEncoder().encode(alias)
        let decoded = try JSONDecoder().decode(
            RemoteHostAlias.self,
            from: encoded
        )

        #expect(decoded == alias)
    }

    @Test
    func decodingAnInvalidAliasThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RemoteHostAlias.self,
                from: Data("\"not a host\"".utf8)
            )
        }
    }
}

@Suite
struct ShellQuotingTests {
    @Test(arguments: [
        ("plain", "'plain'"),
        ("two words", "'two words'"),
        ("$HOME", "'$HOME'"),
        ("line one\nline two", "'line one\nline two'"),
        ("it's", "'it'\\''s'"),
    ])
    func quoteProducesPOSIXSingleQuotedValues(
        value: String,
        expected: String
    ) {
        #expect(ShellQuoting.quote(value) == expected)
    }

    @Test
    func commandQuotesAndJoinsEveryArgument() {
        #expect(
            ShellQuoting.command(["/bin/echo", "two words", "$HOME"])
                == "'/bin/echo' 'two words' '$HOME'"
        )
    }
}

@Suite
struct SSHCommandTests {
    @Test(arguments: [
        (true, true, "-tt", true),
        (true, false, "-tt", false),
        (false, true, "-T", true),
        (false, false, "-T", false),
    ])
    func argumentsContainConnectionAndChannelOptions(
        allocateTTY: Bool,
        batch: Bool,
        ttyArgument: String,
        expectsBatchMode: Bool
    ) throws {
        let alias = try #require(RemoteHostAlias(rawValue: "studio-mac"))
        let command = SSHCommand(
            alias: alias,
            controlPath: "/tmp/coinor ssh/control.sock"
        )

        let arguments = command.arguments(
            remoteCommand: "exec true",
            allocateTTY: allocateTTY,
            batch: batch
        )

        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPath=/tmp/coinor ssh/control.sock"))
        #expect(arguments.contains("ControlPersist=300"))
        #expect(arguments.contains("ServerAliveInterval=15"))
        #expect(arguments.contains("ServerAliveCountMax=3"))
        #expect(arguments.contains(ttyArgument))
        #expect(arguments.contains("BatchMode=yes") == expectsBatchMode)
        #expect(arguments.suffix(2) == ["studio-mac", "exec true"])
    }

    @Test
    func remoteCommandQuotesValuesAndSortsEnvironment() {
        let command = SSHCommand.remoteCommand(
            executable: "/opt/Grok Build/bin/grok",
            arguments: ["--resume", "session $1"],
            workingDirectory: "/srv/Project With Space",
            environment: [
                "Z_VALUE": "last value",
                "A_VALUE": "first$value",
            ]
        )

        #expect(
            command
                == "cd '/srv/Project With Space' && exec env "
                    + "'A_VALUE=first$value' 'Z_VALUE=last value' "
                    + "'/opt/Grok Build/bin/grok' '--resume' 'session $1'"
        )
    }

    @Test
    func remoteCommandOmitsDirectoryWhenNoneIsProvided() {
        #expect(
            SSHCommand.remoteCommand(
                executable: "/bin/echo",
                arguments: ["hello world"],
                workingDirectory: nil
            ) == "exec '/bin/echo' 'hello world'"
        )
    }

    @Test
    func remoteLoginAndCommandShellsUseTheRemoteLoginShell() {
        #expect(
            SSHCommand.remoteLoginShellCommand(
                workingDirectory: "/srv/Project With Space"
            )
                == #"cd '/srv/Project With Space' && exec "${SHELL:-/bin/zsh}" -il"#
        )
        #expect(
            SSHCommand.remoteShellCommand(
                command: "fresh . && echo $HOME",
                workingDirectory: "/srv/Project With Space"
            )
                == #"cd '/srv/Project With Space' && exec "${SHELL:-/bin/zsh}" -ilc 'fresh . && echo $HOME'"#
        )
    }

    @Test
    func injectionTextCannotBreakOutOfQuotedValues() {
        let injection = "'; rm -rf ~; echo '"

        let command = SSHCommand.remoteCommand(
            executable: "/bin/echo",
            arguments: [injection],
            workingDirectory: injection
        )

        #expect(
            command
                == #"cd ''\''; rm -rf ~; echo '\''' && exec '/bin/echo' ''\''; rm -rf ~; echo '\'''"#
        )
    }
}

@Suite
struct SSHConfigHostsTests {
    @Test
    func parsesLiteralAliasesAndIgnoresCommentsAndPatterns() {
        let contents = """
        # Host hidden
        Host alpha beta alpha
        Host=equals
        Host\tTabbed\tspaced
        Host *.example.com wildcard-safe
        Host !blocked negation-safe
        Host gamma # trailing comment words
        HostName ignored.example.com
        """

        #expect(
            SSHConfigHosts.aliases(in: contents).map(\.rawValue)
                == [
                    "alpha",
                    "beta",
                    "equals",
                    "Tabbed",
                    "spaced",
                    "wildcard-safe",
                    "negation-safe",
                    "gamma",
                ]
        )
    }
}

@Suite
struct RemoteHostProbeTests {
    @Test
    func fieldsIgnoreNoiseAndPreserveEqualsInsideValues() {
        let fields = RemoteHostProbe.fields(
            in: """
            Welcome to the host
            coinor.home=/Users/remote
            login shell emitted this line
            coinor.version=grok=1.2.3-overlay.4
            coinor.socket=/tmp/path=with=equals
            """
        )

        #expect(fields["home"] == "/Users/remote")
        #expect(fields["version"] == "grok=1.2.3-overlay.4")
        #expect(fields["socket"] == "/tmp/path=with=equals")
        #expect(fields.count == 3)
    }

    @Test
    func scriptQuotesTheRelativeGrokPathAndReportsEveryProbeField() {
        let script = RemoteHostProbe.script(
            grokRelativePath: "bin/grok'; echo unsafe"
        )

        #expect(script.contains(#"grok="$HOME"/'bin/grok'\''; echo unsafe'"#))
        #expect(script.contains("coinor.home=%s"))
        #expect(script.contains("coinor.grok=%s"))
        #expect(script.contains("coinor.grok_executable=%s"))
        #expect(script.contains("coinor.version=%s"))
        #expect(script.contains("coinor.socket=%s/%s"))
        #expect(script.contains("coinor.max_sessions=%s"))
    }

    @Test
    func describeIncludesOnlyNonzeroOverlayVersions() throws {
        let base = try #require(GrokForkVersion(text: "grok 1.2.3"))
        let overlay = try #require(
            GrokForkVersion(text: "grok 1.2.3-overlay.4")
        )

        #expect(RemoteHostProbe.describe(base) == "1.2.3")
        #expect(RemoteHostProbe.describe(overlay) == "1.2.3-overlay.4")
    }
}

/// A fake host that answers the probe script with a canned field block.
private struct StubProbeRunner: RemoteCommandRunning {
    let version: String

    func run(
        remoteCommand: String,
        timeout: Duration
    ) throws -> RemoteCommandResult {
        RemoteCommandResult(
            standardOutput: """
            coinor.home=/Users/remote
            coinor.grok=/Users/remote/bin/grok
            coinor.grok_executable=yes
            coinor.version=grok \(version)
            coinor.socket=/Users/remote/Library/Coinor/leader.sock
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

@Suite
struct RemoteHostVersionPolicyTests {
    private func probe(remote version: String) -> RemoteHostProbe {
        RemoteHostProbe(
            runner: StubProbeRunner(version: version),
            alias: RemoteHostAlias(rawValue: "studio")!
        )
    }

    private var localVersion: GrokForkVersion {
        GrokForkVersion(text: "0.2.117")!
    }

    @Test
    func identicalVersionsConnectWithoutWarning() throws {
        let host = try probe(remote: "0.2.117").probe(
            localVersion: localVersion
        )

        #expect(host.grokVersion == "0.2.117")
        #expect(host.versionWarning == nil)
    }

    @Test
    func differingOverlayConnectsAndWarns() throws {
        let host = try probe(remote: "0.2.117-overlay.3").probe(
            localVersion: localVersion
        )

        #expect(host.grokVersion == "0.2.117-overlay.3")
        #expect(host.versionWarning?.contains("0.2.117-overlay.3") == true)
        #expect(host.versionWarning?.contains("studio") == true)
    }

    @Test
    func differingBaseVersionIsRefused() {
        #expect(throws: RemoteHostError.self) {
            try probe(remote: "0.2.118").probe(localVersion: localVersion)
        }
    }
}
