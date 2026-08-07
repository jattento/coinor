import Foundation

struct GitCommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32

    var succeeded: Bool { terminationStatus == 0 }
}

enum GitServiceError: Error, Equatable, Sendable {
    case executablePathNotAbsolute(String)
    case executableNotFound(String)
    case executableNotExecutable(String)
    case commandLaunchFailed(arguments: [String], detail: String)
    case commandFailed(arguments: [String], directory: String, status: Int32, detail: String)
    case invalidRepository(path: String, detail: String)
    case malformedOutput(command: String, detail: String)
    case invalidWorktreeName(String)
}

extension GitServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executablePathNotAbsolute(path):
            return "The Git executable path must be absolute, but Coinor was given \(path)."
        case let .executableNotFound(path):
            return "No Git executable exists at \(path)."
        case let .executableNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .commandLaunchFailed(arguments, detail):
            return "Coinor could not start Git (\(arguments.joined(separator: " "))): \(detail)"
        case let .commandFailed(arguments, directory, status, detail):
            let suffix = detail.isEmpty ? "" : " Git reported: \(detail)"
            return "Git \(arguments.joined(separator: " ")) failed in \(directory) with status \(status).\(suffix)"
        case let .invalidRepository(path, detail):
            return "Coinor could not resolve the Git repository at \(path): \(detail)"
        case let .malformedOutput(command, detail):
            return "Coinor could not read the output of \(command): \(detail)"
        case let .invalidWorktreeName(name):
            return "The worktree name \"\(name)\" must be 1-64 characters, start with a letter or number, use only letters, numbers, dots, underscores, or hyphens, and be valid as a Git branch name."
        }
    }
}

protocol GitCommandRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL) throws -> GitCommandResult
}

struct GitProcessRunner: GitCommandRunning, Sendable {
    static let systemExecutable = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false)

    let executable: URL

    init(
        executable: URL = systemExecutable,
        fileManager: FileManager = .default
    ) throws {
        let standardized = executable.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw GitServiceError.executablePathNotAbsolute(executable.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw GitServiceError.executableNotFound(standardized.path)
        }
        guard fileManager.isExecutableFile(atPath: standardized.path) else {
            throw GitServiceError.executableNotExecutable(standardized.path)
        }
        self.executable = standardized
    }

    func run(arguments: [String], workingDirectory: URL) throws -> GitCommandResult {
        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("coinor-git-\(UUID().uuidString)", isDirectory: true)
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")

        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: captureDirectory) }

        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw GitServiceError.commandLaunchFailed(
                arguments: arguments,
                detail: "could not create temporary output files"
            )
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw GitServiceError.commandLaunchFailed(
                arguments: arguments,
                detail: error.localizedDescription
            )
        }
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()

        return GitCommandResult(
            standardOutput: Self.readUTF8(outputURL),
            standardError: Self.readUTF8(errorURL),
            terminationStatus: process.terminationStatus
        )
    }

    private static func readUTF8(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension GitCommandRunning {
    func runChecked(arguments: [String], workingDirectory: URL) throws -> GitCommandResult {
        let result = try run(arguments: arguments, workingDirectory: workingDirectory)
        guard result.succeeded else {
            throw GitServiceError.commandFailed(
                arguments: arguments,
                directory: workingDirectory.path,
                status: result.terminationStatus,
                detail: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}
