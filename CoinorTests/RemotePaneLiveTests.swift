import Darwin
import Foundation
import Testing

@testable import Coinor

/// Runs the pane commands Conan Code composes on a real pseudo-terminal
/// against a real remote computer.
///
/// A Ghostty surface cannot be scripted, but it does exactly what happens
/// here: allocate a PTY and run `TerminalLaunchRequest.shellCommand`. This is
/// the closest evidence available that a remote conversation, shell tab, and
/// IDE tab really start.
@Suite(.enabled(if: LiveRemoteEnvironment.isConfigured), .serialized)
struct RemotePaneLiveTests {
    private func remote() throws -> RemoteExecution {
        let command = SSHCommand(
            alias: try #require(LiveRemoteEnvironment.alias),
            controlPath: LiveRemoteEnvironment.controlPath
        )
        try command.prepareControlDirectory()
        return RemoteExecution(ssh: command)
    }

    private func remoteHome() throws -> String {
        try RemoteProjectDiscovery(
            runner: SSHCommandRunner(ssh: try remote().ssh),
            alias: try #require(LiveRemoteEnvironment.alias)
        ).homeDirectory()
    }

    @Test
    func aRemoteShellTabStartsTheRemoteLoginShell() throws {
        let launch = TerminalLaunchRequest(
            shellTabID: UUID().uuidString,
            workingDirectory: try remoteHome(),
            remote: try remote()
        )
        let session = try PTYSession(command: #require(launch.explicitCommand))
        defer { session.terminate() }

        // A real login shell paints a prompt and may ask its own startup
        // questions, so input is paced the way a person types it.
        let output = session.drive(
            payloads: [
                "\n",
                "\n",
                "printf 'CWD=%s\\n' \"$PWD\"\n",
                "printf 'HOST=%s\\n' \"$(hostname -s)\"\n",
            ],
            until: "HOST=",
            timeout: 60
        )

        #expect(output.contains("CWD=" + (try remoteHome())))
        #expect(output.contains("HOST="))
        // The shell must be the remote computer's, not this one's.
        #expect(!output.contains("HOST=" + Host.current().localizedName!
            .replacingOccurrences(of: " ", with: "-")))
    }

    @Test
    func theRemoteIDECommandsStart() throws {
        for command in ["fresh .", "lazygit"] {
            let launch = TerminalLaunchRequest(
                commandID: UUID().uuidString,
                workingDirectory: try remoteHome(),
                command: command,
                remote: try remote()
            )
            let session = try PTYSession(command: #require(launch.explicitCommand))
            defer { session.terminate() }

            // A TUI that started paints the alternate screen or draws with
            // escape sequences; "command not found" does neither.
            let output = session.read(until: "\u{1b}[", timeout: 45)
            #expect(output.contains("\u{1b}["), "\(command) produced: \(output)")
            #expect(!output.contains("command not found"), "\(command)")
        }
    }

    @Test
    func aRemoteGrokConversationStartsAndIsVisibleInTheRemoteCatalog() async throws {
        let alias = try #require(LiveRemoteEnvironment.alias)
        let runtime = try await RemoteHostRuntime.connect(
            alias: alias,
            supportDirectory: LiveRemoteEnvironment.supportDirectory,
            localVersion: try LiveRemoteEnvironment.localVersion()
        )
        let execution = await runtime.execution
        let sessionID = UUID().uuidString.lowercased()
        let launch = TerminalLaunchRequest(
            sessionID: sessionID,
            workingDirectory: try remoteHome(),
            grokExecutable: execution.grokExecutable,
            leaderSocket: execution.leaderSocket,
            mode: .newSession,
            remote: execution.remote
        )

        let session = try PTYSession(command: launch.shellCommand)
        defer { session.terminate() }
        // The Grok TUI paints its interface; a failed launch exits instead.
        let painted = session.read(until: "\u{1b}[", timeout: 60)
        #expect(painted.contains("\u{1b}["), "grok produced: \(painted.suffix(400))")

        // The conversation Conan Code just started must appear on the remote
        // computer's own live roster, under the ID Conan Code chose.
        var found = false
        for _ in 0..<20 where !found {
            let roster = try await runtime.control.listRoster()
            found = roster.contains { $0.id.rawValue == sessionID }
            if !found { try await Task.sleep(for: .seconds(1)) }
        }
        #expect(found)

        session.terminate()
        try await runtime.stopRemoteRuntime()
    }
}

/// A minimal pseudo-terminal, which is what a terminal surface provides.
private final class PTYSession {
    private var primary: Int32 = -1
    private var pid: pid_t = -1

    init(command: String) throws {
        var primaryDescriptor: Int32 = 0
        var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let child = forkpty(&primaryDescriptor, nil, nil, &window)
        if child == 0 {
            let arguments = ["/bin/sh", "-c", command]
            var raw = arguments.map { strdup($0) }
            raw.append(nil)
            execv("/bin/sh", &raw)
            _exit(127)
        }
        guard child > 0 else {
            throw GrokControlError.launchFailed("forkpty failed")
        }
        primary = primaryDescriptor
        pid = child
    }

    func write(_ text: String) {
        _ = text.withCString { pointer in
            Darwin.write(primary, pointer, strlen(pointer))
        }
    }

    /// Sends each payload once the child has been quiet for a moment, which
    /// is how a person waits for a prompt before typing the next line.
    func drive(
        payloads: [String],
        until marker: String,
        timeout: TimeInterval
    ) -> String {
        var collected = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sent = 0
        var lastActivity = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptors = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
            if poll(&descriptors, 1, 800) > 0 {
                let count = Darwin.read(primary, &buffer, buffer.count)
                if count <= 0 { break }
                collected += String(decoding: buffer[0..<count], as: UTF8.self)
                lastActivity = Date()
            }
            if collected.contains(marker) { break }
            if Date().timeIntervalSince(lastActivity) > 2, sent < payloads.count {
                write(payloads[sent])
                sent += 1
                lastActivity = Date()
            }
        }
        return collected
    }

    func read(until marker: String, timeout: TimeInterval) -> String {
        var collected = ""
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptors = pollfd(fd: primary, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptors, 1, 500) > 0 else { continue }
            let count = Darwin.read(primary, &buffer, buffer.count)
            guard count > 0 else { break }
            collected += String(decoding: buffer[0..<count], as: UTF8.self)
            if collected.contains(marker) { break }
        }
        return collected
    }

    func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        close(primary)
        pid = -1
    }
}
