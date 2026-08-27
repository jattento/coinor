import Foundation
import Testing

@testable import Coinor

@Test
func terminalControlRequestDecodesAllCommandFields() throws {
    let request = try TerminalControlRequest(
        data: Data(
            #"""
            {
              "version": 1,
              "method": "execute",
              "token": "secret",
              "tabID": "tab",
              "capability": "cap",
              "command": "printf 'hello'"
            }
            """#.utf8
        )
    )

    #expect(request.version == 1)
    #expect(
        request.method == TerminalControlContract.Method.execute
    )
    #expect(request.token == "secret")
    #expect(request.tabID == "tab")
    #expect(request.capability == "cap")
    #expect(request.command == "printf 'hello'")
}

@Test
func terminalControlRequestDecodesPointToCodeFields() throws {
    let request = try TerminalControlRequest(
        data: Data(
            #"""
            {
              "version": 1,
              "method": "point-to-code",
              "token": "secret",
              "sessionID": "session-1",
              "filePath": "src/main.swift",
              "lineStart": 10,
              "lineEnd": 20,
              "comment": "Entry point"
            }
            """#.utf8
        )
    )

    #expect(
        request.method == TerminalControlContract.Method.pointToCode
    )
    #expect(request.sessionID == "session-1")
    #expect(request.filePath == "src/main.swift")
    #expect(request.lineStart == 10)
    #expect(request.lineEnd == 20)
    #expect(request.comment == "Entry point")
}

@Test
func terminalControlRequestDecodesTourWaitWithOnlyASessionID() throws {
    let request = try TerminalControlRequest(
        data: Data(
            #"""
            {
              "version": 1,
              "method": "tour-wait",
              "token": "secret",
              "sessionID": "session-1"
            }
            """#.utf8
        )
    )

    #expect(request.method == TerminalControlContract.Method.tourWait)
    #expect(request.sessionID == "session-1")
    #expect(request.filePath == nil)
}

@Test
func terminalControlResponseUsesStableSuccessAndErrorShapes() throws {
    let success = try GrokJSONValue.decode(
        Data(
            TerminalControlResponse.success(
                ["tabID": "tab"]
            ).encodedLine().dropLast()
        )
    )
    #expect(success["ok"]?.boolValue == true)
    #expect(success["result"]?["tabID"]?.stringValue == "tab")

    let failure = try GrokJSONValue.decode(
        Data(
            TerminalControlResponse.failure(.tabGone)
                .encodedLine().dropLast()
        )
    )
    #expect(failure["ok"]?.boolValue == false)
    #expect(failure["error"]?["code"]?.stringValue == "tab_gone")
}

@Test
func grokToolInvocationExtractsOnlyLiteralControlNonces() {
    let command =
        TerminalControlContract.EnvironmentVariable.requestID
        + "=12345678-1234-1234-1234-123456789abc "
        + "sh ~/.grok/skills/conan-code-long-running/terminal.sh create "
        + "--request-id 12345678-1234-1234-1234-123456789abc"
    let params: GrokJSONValue = [
        "sessionId": "child-session",
        "update": [
            "sessionUpdate": "tool_call",
            "title": "run_terminal_command",
            "rawInput": [
                "command": .string(command),
            ],
        ],
    ]
    let invocation = GrokTerminalToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(invocation?.sessionID == "child-session")
    #expect(
        invocation?.terminalControlRequestID
            == "12345678-1234-1234-1234-123456789abc"
    )

    let hiddenBehindShellExpansion = GrokTerminalToolInvocation(
        sessionID: "session",
        command:
            #"\#(TerminalControlContract.EnvironmentVariable.requestID)="$REQUEST_ID" coinorctl create"#
    )
    #expect(
        hiddenBehindShellExpansion.terminalControlRequestID == nil
    )
}

@Test
@MainActor
func terminalControlNonceCanBeConsumedOnlyOnce() async {
    let authorizer = TerminalControlInvocationAuthorizer(
        lifetime: .seconds(1)
    )
    authorizer.observe(
        GrokTerminalToolInvocation(
            sessionID: "session",
            command:
                TerminalControlContract.EnvironmentVariable.requestID
                + "=12345678-1234-1234-1234-123456789abc ctl"
        )
    )

    #expect(
        await authorizer.consume(
            requestID: "12345678-1234-1234-1234-123456789abc",
            wait: .zero
        ) == "session"
    )
    #expect(
        await authorizer.consume(
            requestID: "12345678-1234-1234-1234-123456789abc",
            wait: .zero
        ) == nil
    )

    authorizer.observe(
        GrokTerminalToolInvocation(
            sessionID: "session",
            command:
                TerminalControlContract.EnvironmentVariable.requestID
                + "=abcdefab-cdef-abcd-efab-cdefabcdefab ctl"
        )
    )
    authorizer.reset()
    #expect(
        await authorizer.consume(
            requestID: "abcdefab-cdef-abcd-efab-cdefabcdefab",
            wait: .zero
        ) == nil
    )
}

@Test
func managedTerminalOutputReturnsAppendsAndResets() {
    var cache = ManagedTerminalOutputCache()
    let first = cache.read(
        snapshot: "one\n",
        generation: 2,
        cursor: nil,
        maximumBytes: nil
    )
    #expect(first.text == "one\n")
    #expect(first.reset == false)

    let appended = cache.read(
        snapshot: "one\ntwo\n",
        generation: 2,
        cursor: first.cursor,
        maximumBytes: nil
    )
    #expect(appended.text == "two\n")
    #expect(appended.reset == false)

    let rewritten = cache.read(
        snapshot: "replacement\n",
        generation: 2,
        cursor: appended.cursor,
        maximumBytes: nil
    )
    #expect(rewritten.text == "replacement\n")
    #expect(rewritten.reset)
}

@Test
func managedTerminalOutputTruncatesOnAValidUTF8Boundary() {
    var cache = ManagedTerminalOutputCache()
    let result = cache.read(
        snapshot: "prefix-\u{1F600}\u{1F600}",
        generation: 1,
        cursor: nil,
        maximumBytes: 5
    )

    #expect(result.text == "\u{1F600}")
    #expect(result.truncated)
}

@Test
func managedTerminalBootstrapReportsCommandCompletionInZsh() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let completionLog = temporaryDirectory.appendingPathComponent(
        "completion.log"
    )
    let fakeControlClient = temporaryDirectory.appendingPathComponent(
        "coinorctl"
    )
    let fakeClientSource = #"""
    #!/bin/sh
    case "$1" in
      shell-ready)
        exit 0
        ;;
      fetch-command)
        printf '%s\n' "printf 'managed-output\n'"
        ;;
      command-finished)
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--exit-code" ]; then
            printf '%s\n' "$2" > "$COMPLETION_LOG"
            exit 0
          fi
          shift
        done
        exit 2
        ;;
      *)
        exit 3
        ;;
    esac
    """#
    try Data(fakeClientSource.utf8).write(to: fakeControlClient)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fakeControlClient.path
    )

    let bootstrapURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Coinor/Resources/managed-terminal-bootstrap.zsh"
        )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [
        "-fc",
        "source \(bootstrapURL.path.quotedForShell); "
            + "__conan_code_run command-id",
    ]
    process.environment = [
        "COMPLETION_LOG": completionLog.path,
        TerminalControlContract.EnvironmentVariable.controlClient:
            fakeControlClient.path,
        TerminalControlContract.EnvironmentVariable.tabCapability:
            "capability",
        TerminalControlContract.EnvironmentVariable.tabID:
            "tab",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    let text = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(process.terminationStatus == 0, Comment(rawValue: text))
    #expect(text == "managed-output\n")
    #expect(try String(contentsOf: completionLog) == "0\n")
}

private extension String {
    var quotedForShell: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Shell script and release script pinning

/// The shipped shell scripts and the release script cannot import Swift
/// constants, so each one is pinned against `TerminalControlContract` by
/// reading the file back and requiring the shared literals verbatim. A
/// typo in a script, or a rename of a contract constant without updating
/// the script, fails CI instead of silently breaking the control channel.

@Test
func conanCodeTerminalScriptPinsContractLiterals() throws {
    let url =
        TerminalControlScriptFile.coinorResourcesDirectory
        .appendingPathComponent("conan-code-terminal.sh")
    let text = try String(contentsOf: url, encoding: .utf8)

    for literal in TerminalControlScriptText.conanCodeTerminalScriptAdverts
    {
        #expect(text.contains(literal))
    }
}

@Test
func sidechatScriptPinsContractLiterals() throws {
    let url =
        TerminalControlScriptFile.coinorResourcesDirectory
        .appendingPathComponent("sidechat.sh")
    let text = try String(contentsOf: url, encoding: .utf8)

    for literal in TerminalControlScriptText.sidechatScriptAdverts {
        #expect(text.contains(literal))
    }
}

@Test
func managedTerminalBootstrapPinsContractLiterals() throws {
    let url =
        TerminalControlScriptFile.coinorResourcesDirectory
        .appendingPathComponent("managed-terminal-bootstrap.zsh")
    let text = try String(contentsOf: url, encoding: .utf8)

    for literal in
        TerminalControlScriptText.managedTerminalBootstrapAdverts
    {
        #expect(text.contains(literal))
    }
}

@Test
func verifyAppScriptPinsContractLiterals() throws {
    let url =
        TerminalControlScriptFile.releaseScriptsDirectory
        .appendingPathComponent("verify-app.sh")
    let text = try String(contentsOf: url, encoding: .utf8)

    for literal in TerminalControlScriptText.verifyAppScriptAdverts {
        #expect(text.contains(literal))
    }
}
