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
    case commandTimedOut(arguments: [String], directory: String, seconds: Double)
    case invalidRepository(path: String, detail: String)
    case malformedOutput(command: String, detail: String)
    case invalidWorktreeName(String)
}

extension GitServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executablePathNotAbsolute(path):
            return "The Git executable path must be absolute, but Conan Code was given \(path)."
        case let .executableNotFound(path):
            return "No Git executable exists at \(path)."
        case let .executableNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .commandLaunchFailed(arguments, detail):
            return "Conan Code could not start Git (\(arguments.joined(separator: " "))): \(detail)"
        case let .commandFailed(arguments, directory, status, detail):
            let suffix = detail.isEmpty ? "" : " Git reported: \(detail)"
            return "Git \(arguments.joined(separator: " ")) failed in \(directory) with status \(status).\(suffix)"
        case let .commandTimedOut(arguments, directory, seconds):
            return "Git \(arguments.joined(separator: " ")) did not finish in \(directory) within \(Int(seconds)) seconds."
        case let .invalidRepository(path, detail):
            return "Conan Code could not resolve the Git repository at \(path): \(detail)"
        case let .malformedOutput(command, detail):
            return "Conan Code could not read the output of \(command): \(detail)"
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
    /// Local Git can block on the network, a credential helper, or a lock.
    static let defaultDeadline: Duration = .seconds(60)

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
        try run(
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: Self.defaultDeadline
        )
    }

    func run(
        arguments: [String],
        workingDirectory: URL,
        deadline: Duration
    ) throws -> GitCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        do {
            let capture = try SubprocessOutputCapture(label: "git")
            let captured = try capture.run(process: process, deadline: deadline)
            return GitCommandResult(
                standardOutput: captured.standardOutput,
                standardError: captured.standardError,
                terminationStatus: captured.terminationStatus
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch SubprocessCaptureError.timedOut {
            throw GitServiceError.commandTimedOut(
                arguments: arguments,
                directory: workingDirectory.path,
                seconds: SubprocessOutputCapture.seconds(in: deadline)
            )
        } catch {
            throw GitServiceError.commandLaunchFailed(
                arguments: arguments,
                detail: error.localizedDescription
            )
        }
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
