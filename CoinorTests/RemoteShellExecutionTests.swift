import Foundation
import Testing

@testable import Coinor

/// Executes the exact remote command strings Conan Code composes, in a real
/// POSIX shell on this computer, instead of asserting on their text.
///
/// A remote command is a shell program built by string composition, so its
/// quoting and syntax can only be trusted once a shell has actually run it.
/// The SSH hop is the one thing skipped here: everything sent through it is
/// executed verbatim.
private struct LocalShellRunner: RemoteCommandRunning {
    func run(
        remoteCommand: String,
        timeout: Duration
    ) throws -> RemoteCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh", isDirectory: false)
        process.arguments = ["-c", remoteCommand]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteCommandResult(
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            terminationStatus: process.terminationStatus
        )
    }
}

@Suite
struct RemoteShellExecutionTests {
    private let alias = RemoteHostAlias(rawValue: "loopback")!

    // MARK: - Probe

    @Test
    func probeScriptRunsInARealShellAndReportsEveryField() throws {
        let result = try LocalShellRunner().run(
            remoteCommand: RemoteHostProbe.script(grokRelativePath: "bin/grok"),
            timeout: .seconds(30)
        )

        #expect(result.terminationStatus == 0)
        let fields = RemoteHostProbe.fields(in: result.standardOutput)
        #expect(fields["home"] == NSHomeDirectory())
        #expect(fields["grok"] == NSHomeDirectory() + "/bin/grok")
        #expect(fields["socket"]?.hasSuffix(
            "/Library/Application Support/Coinor/grok-leader-remote.sock"
        ) == true)
        #expect(fields["grok_executable"] == "yes" || fields["grok_executable"] == "no")
    }

    @Test
    func probeReportsAnExecutableGrokAndItsVersion() throws {
        // The probe advertises a Grok executable only when it can really run,
        // which is what the host health check refuses to register without.
        let runner = LocalShellRunner()
        let result = try runner.run(
            remoteCommand: RemoteHostProbe.script(grokRelativePath: "bin/grok"),
            timeout: .seconds(30)
        )
        let fields = RemoteHostProbe.fields(in: result.standardOutput)
        try #require(fields["grok_executable"] == "yes")

        let version = try #require(fields["version"])
        #expect(GrokForkVersion(text: version) != nil)
    }

    @Test
    func probeSurvivesAGrokPathContainingShellMetacharacters() throws {
        let result = try LocalShellRunner().run(
            remoteCommand: RemoteHostProbe.script(
                grokRelativePath: "bin/'; touch /tmp/coinor-probe-escape; echo '"
            ),
            timeout: .seconds(30)
        )
        let fields = RemoteHostProbe.fields(in: result.standardOutput)

        #expect(fields["grok_executable"] == "no")
        #expect(
            FileManager.default.fileExists(atPath: "/tmp/coinor-probe-escape")
                == false
        )
    }

    // MARK: - Project discovery

    @Test
    func directoryListingRunsAndMarksRepositories() throws {
        let root = try TemporaryTree.make(
            directories: ["plain", "repo/.git", "another repo/.git"]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let entries = try RemoteProjectDiscovery(
            runner: LocalShellRunner(),
            alias: alias
        ).directoryEntries(at: root.path)

        let byName = Dictionary(
            entries.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byName["plain"]?.isRepository == false)
        #expect(byName["repo"]?.isRepository == true)
        // A directory whose name contains a space must survive quoting.
        #expect(byName["another repo"]?.isRepository == true)
        #expect(byName["repo"]?.path == root.path + "/repo")
    }

    @Test
    func candidateScanFindsRepositoriesBeneathASearchRoot() throws {
        let root = try TemporaryTree.make(
            directories: [
                "workspace/alpha/.git",
                "workspace/nested/beta/.git",
                "workspace/plain",
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let candidates = try RemoteProjectDiscovery(
            runner: LocalShellRunner(),
            alias: alias
        ).candidates(
            knownGitRoots: [],
            searchRoots: [root.appendingPathComponent("workspace").path]
        )

        let paths = Set(candidates.map(\.path))
        #expect(paths.contains(root.path + "/workspace/alpha"))
        #expect(paths.contains(root.path + "/workspace/nested/beta"))
        #expect(!paths.contains(root.path + "/workspace/plain"))
    }

    @Test
    func candidateScanTolersatesAMissingSearchRoot() throws {
        let candidates = try RemoteProjectDiscovery(
            runner: LocalShellRunner(),
            alias: alias
        ).candidates(
            knownGitRoots: ["/known/repo"],
            searchRoots: ["/nonexistent/coinor/search/root"]
        )

        #expect(candidates.map(\.path) == ["/known/repo"])
    }

    // MARK: - Git

    @Test
    func remoteGitResolvesARealRepositoryThroughTheComposedCommand() throws {
        let repository = try TemporaryTree.makeGitRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        let resolution = try GitProjectResolver(
            remote: alias,
            runner: LocalShellRunner()
        ).resolve(checkout: repository)

        #expect(resolution.identity.target == .remote(alias))
        #expect(resolution.identity.rawValue.hasPrefix("loopback:/"))
        #expect(resolution.commonDirectory.lastPathComponent == ".git")
        #expect(resolution.mainCheckout.lastPathComponent
            == repository.lastPathComponent)
    }

    @Test
    func remoteGitRunsInsideADirectoryContainingSpaces() throws {
        let repository = try TemporaryTree.makeGitRepository(
            named: "repo with spaces"
        )
        defer { try? FileManager.default.removeItem(at: repository) }

        let result = try SSHGitCommandRunner(
            runner: LocalShellRunner(),
            alias: alias
        ).run(
            arguments: ["rev-parse", "--is-inside-work-tree"],
            workingDirectory: repository
        )

        #expect(result.succeeded)
        #expect(result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "true")
    }

    // MARK: - Stopping the remote runtime

    @Test
    func stopCommandIgnoresAPIDThatIsNotGrok() throws {
        let directory = try TemporaryTree.make(directories: [])
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent("leader.lock")
        // This process is alive and is definitely not Grok, so the stop
        // command must refuse to signal it.
        try String(ProcessInfo.processInfo.processIdentifier)
            .write(to: lock, atomically: true, encoding: .utf8)

        let result = try LocalShellRunner().run(
            remoteCommand: RemoteRuntimeStopCommand.command(lockPath: lock.path),
            timeout: .seconds(20)
        )

        #expect(result.terminationStatus == 0)
    }

    @Test
    func stopCommandLeavesAProcessRunningFromAGrokDirectoryAlone() async throws {
        let directory = try TemporaryTree.make(directories: [".grok/bin"])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Only the directory carries the name, so matching the whole argument
        // vector would signal a process that is not the leader at all.
        //
        // The decoy is compiled instead of copied from /bin/sleep: macOS
        // SIGKILLs a copied platform binary the moment it spawns, which made
        // the decoy die before the stop command ever looked at it.
        let decoy = directory
            .appendingPathComponent(".grok/bin/sleeper", isDirectory: false)
        let source = directory.appendingPathComponent("sleeper.c", isDirectory: false)
        try """
        #include <unistd.h>
        int main(void) { sleep(30); return 0; }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-o", decoy.path, source.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        try #require(
            compiler.terminationStatus == 0,
            "cc could not build the sleeper decoy"
        )

        let process = Process()
        process.executableURL = decoy
        process.arguments = []
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let lock = directory.appendingPathComponent("leader.lock")
        try String(process.processIdentifier)
            .write(to: lock, atomically: true, encoding: .utf8)

        let result = try LocalShellRunner().run(
            remoteCommand: RemoteRuntimeStopCommand.command(lockPath: lock.path),
            timeout: .seconds(20)
        )
        try await Task.sleep(for: .milliseconds(300))

        #expect(result.terminationStatus == 0)
        #expect(process.isRunning)
    }

    @Test
    func stopCommandSucceedsWhenNoLockExists() throws {
        let result = try LocalShellRunner().run(
            remoteCommand: RemoteRuntimeStopCommand.command(
                lockPath: "/nonexistent/coinor/leader.lock"
            ),
            timeout: .seconds(20)
        )

        #expect(result.terminationStatus == 0)
    }
}

/// Builds throwaway directory trees for the shell-execution tests.
private enum TemporaryTree {
    static func make(directories: [String]) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "coinor-shell-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in directories {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root.resolvingSymlinksInPath()
    }

    static func makeGitRepository(named name: String = "repo") throws -> URL {
        let root = try make(directories: [name])
        let repository = root.appendingPathComponent(name, isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)
        process.arguments = ["init", "--quiet", repository.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return repository
    }
}
