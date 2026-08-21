import Foundation
import Testing

@testable import Coinor

private func toolCallParams(
    sessionID: String,
    command: String
) -> GrokJSONValue {
    [
        "sessionId": .string(sessionID),
        "update": [
            "sessionUpdate": "tool_call",
            "title": "run_terminal_command",
            "rawInput": [
                "command": .string(command),
            ],
        ],
    ]
}

@Test
func nonBrowserCommandsAreIgnored() {
    let params = toolCallParams(
        sessionID: "session",
        command: "echo hello"
    )
    #expect(
        GrokBrowserToolInvocation.parseNotification(
            method: "session/update",
            params: params
        ) == nil
    )
}

@Test
func nonToolCallNotificationsAreIgnored() {
    let params = toolCallParams(
        sessionID: "session",
        command: "ego-browser nodejs <<'EOF'\nEOF"
    )
    #expect(
        GrokBrowserToolInvocation.parseNotification(
            method: "x.ai/sessions/changed",
            params: params
        ) == nil
    )
}

/// The exact heredoc recorded live during the Phase 0 spike
/// (`ego-browser nodejs <<'EOF' ... EOF` verifying the fresh install), kept
/// verbatim so this test proves the shipped parser against real captured
/// text, not a hand-simplified stand-in for it.
@Test
func recordedInstallationVerificationHeredocOpensAndClosesTheSameSpace() {
    let command = """
        export PATH="$HOME/.local/bin:$PATH"
        pgrep -fl "ego lite" | head -5
        echo "---"
        ego-browser nodejs <<'EOF'
        const task = await useOrCreateTaskSpace('verificacion de instalacion coinor')
        await openOrReuseTab('https://example.com', { wait: true, timeout: 20 })
        const info = await pageInfo()
        cliLog(JSON.stringify(info))
        await completeTaskSpace(task.name, { keep: false })
        EOF
        """
    let params = toolCallParams(sessionID: "root-session", command: command)

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(invocation?.sessionID == "root-session")
    #expect(
        invocation?.signals == [
            GrokBrowserSpaceSignal(
                name: "verificacion de instalacion coinor",
                kind: .opened
            ),
            GrokBrowserSpaceSignal(
                name: "verificacion de instalacion coinor",
                kind: .closed(keepFrame: false)
            ),
        ]
    )
}

@Test
func openOnlyCommandProducesASingleOpenedSignal() {
    let command = """
        ego-browser nodejs <<'EOF'
        const task = await useOrCreateTaskSpace('research the topic')
        await openOrReuseTab('https://example.com', { wait: true })
        cliLog(await snapshotText())
        EOF
        """
    let params = toolCallParams(sessionID: "child-session", command: command)

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(invocation?.sessionID == "child-session")
    #expect(
        invocation?.signals == [
            GrokBrowserSpaceSignal(name: "research the topic", kind: .opened),
        ]
    )
}

@Test
func sameCommandOpenAndCloseWithLiteralKeepTrueIsDetected() {
    let command = """
        ego-browser nodejs <<'EOF'
        const task = await useOrCreateTaskSpace('leave page open for review')
        await openOrReuseTab('https://example.com', { wait: true })
        await completeTaskSpace('leave page open for review', { keep: true })
        EOF
        """
    let params = toolCallParams(sessionID: "session", command: command)

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(
        invocation?.signals == [
            GrokBrowserSpaceSignal(
                name: "leave page open for review",
                kind: .opened
            ),
            GrokBrowserSpaceSignal(
                name: "leave page open for review",
                kind: .closed(keepFrame: true)
            ),
        ]
    )
}

/// A close call in a *separate*, later command has no shared command text to
/// fall back to, so it only resolves when it names the Space literally.
@Test
func laterSeparateCommandClosesByLiteralNameOnly() {
    let params = toolCallParams(
        sessionID: "session",
        command: """
            ego-browser nodejs <<'EOF'
            await completeTaskSpace('spike coinor mirror latency', { keep: false })
            cliLog('closed')
            EOF
            """
    )

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(
        invocation?.signals == [
            GrokBrowserSpaceSignal(
                name: "spike coinor mirror latency",
                kind: .closed(keepFrame: false)
            ),
        ]
    )
}

/// `takeOverTaskSpace` resumes a space by name the same way
/// `useOrCreateTaskSpace` does, and must be recognized as an "opened" signal
/// too.
@Test
func takeOverTaskSpaceIsTreatedAsOpened() {
    let params = toolCallParams(
        sessionID: "session",
        command: """
            ego-browser nodejs <<'EOF'
            const task = await takeOverTaskSpace('resumed research')
            cliLog(await snapshotText())
            EOF
            """
    )

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    #expect(
        invocation?.signals == [
            GrokBrowserSpaceSignal(name: "resumed research", kind: .opened),
        ]
    )
}

@Test
func closeWithoutAnyOpenInTheSameCommandAndNoLiteralNameIsSkipped() {
    let params = toolCallParams(
        sessionID: "session",
        command: """
            ego-browser nodejs <<'EOF'
            await completeTaskSpace(task.name, { keep: false })
            EOF
            """
    )

    let invocation = GrokBrowserToolInvocation.parseNotification(
        method: "session/update",
        params: params
    )

    // No literal name and nothing opened earlier in this command to fall
    // back to: nothing can be attributed, so parsing must yield no
    // invocation at all rather than a signal with a bogus name.
    #expect(invocation == nil)
}

@Test
func rawSessionNotificationSpellingIsAlsoRecognized() {
    let params = toolCallParams(
        sessionID: "session",
        command: "ego-browser nodejs <<'EOF'\nawait useOrCreateTaskSpace('x')\nEOF"
    )

    #expect(
        GrokBrowserToolInvocation.parseNotification(
            method: "x.ai/session_notification",
            params: params
        ) != nil
    )
    #expect(
        GrokBrowserToolInvocation.parseNotification(
            method: "session/notification",
            params: params
        ) != nil
    )
}
