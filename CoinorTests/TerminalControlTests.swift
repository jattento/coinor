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
    #expect(request.method == "execute")
    #expect(request.token == "secret")
    #expect(request.tabID == "tab")
    #expect(request.capability == "cap")
    #expect(request.command == "printf 'hello'")
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
        "CONAN_CODE_REQUEST_ID=12345678-1234-1234-1234-123456789abc "
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
        command: #"CONAN_CODE_REQUEST_ID="$REQUEST_ID" coinorctl create"#
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
                "CONAN_CODE_REQUEST_ID=12345678-1234-1234-1234-123456789abc ctl"
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
                "CONAN_CODE_REQUEST_ID=abcdefab-cdef-abcd-efab-cdefabcdefab ctl"
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
        "CONAN_CODE_CONTROL_CLIENT": fakeControlClient.path,
        "CONAN_CODE_TAB_CAPABILITY": "capability",
        "CONAN_CODE_TAB_ID": "tab",
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
