import Foundation

/// Every failure the Grok control plane can report, in the vocabulary the rest
/// of Coinor reasons about. Startup problems, protocol incompatibility, and
/// per-request failures stay distinguishable so the UI can show one actionable
/// English diagnostic instead of a partially working interface.
enum GrokControlError: Error, Equatable, Sendable {
    case executablePathNotAbsolute(String)
    case executableNotFound(String)
    case executableNotExecutable(String)
    case workingDirectoryNotFound(String)
    case leaderSocketPathNotAbsolute(String)
    case leaderSocketPathTooLong(path: String, limit: Int)

    case alreadyConnected
    case notConnected
    case launchFailed(String)
    case transportEnded(status: Int32, diagnostics: String)
    case executableVersionTimedOut(path: String, seconds: Double)
    case executableVersionFailed(path: String, status: Int32, diagnostics: String)
    case executableVersionEmpty(String)

    case requestTimedOut(method: String, seconds: Double)
    case requestFailed(method: String, code: Int, message: String, data: String?)
    case unsupportedMethod(String)
    case extensionFailed(method: String, message: String)
    case malformedPayload(method: String, detail: String)
    case incompatibleAgent(String)
    case paginationStalled(cursor: String)

    case malformedFrame(String)
    case frameTooLarge(Int)
}

extension GrokControlError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executablePathNotAbsolute(path):
            return "The Grok executable path must be absolute, but Conan Code was given \(path)."
        case let .executableNotFound(path):
            return "No Grok executable exists at \(path)."
        case let .executableNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .workingDirectoryNotFound(path):
            return "The working directory \(path) does not exist."
        case let .leaderSocketPathNotAbsolute(path):
            return "The Grok leader socket path must be absolute, but Conan Code was given \(path)."
        case let .leaderSocketPathTooLong(path, limit):
            return "The Grok leader socket path is \(path.utf8.count) bytes and cannot exceed \(limit): \(path)."
        case .alreadyConnected:
            return "The Grok control client is already connected."
        case .notConnected:
            return "The Grok control client is not connected."
        case let .launchFailed(detail):
            return "Conan Code could not start Grok: \(detail)"
        case let .transportEnded(status, diagnostics):
            let tail = diagnostics.isEmpty ? "" : " Grok reported: \(diagnostics)"
            return "The Grok control process exited with status \(status).\(tail)"
        case let .executableVersionTimedOut(path, seconds):
            return "Conan Code could not verify \(path): `grok --version` did not finish within \(Int(seconds)) seconds."
        case let .executableVersionFailed(path, status, diagnostics):
            let tail = diagnostics.isEmpty ? "" : " Grok reported: \(diagnostics)"
            return "Conan Code could not verify \(path): `grok --version` exited with status \(status).\(tail)"
        case let .executableVersionEmpty(path):
            return "Conan Code could not verify \(path): `grok --version` returned no version text."
        case let .requestTimedOut(method, seconds):
            return "Grok did not answer \(method) within \(Int(seconds)) seconds."
        case let .requestFailed(method, code, message, data):
            let detail = data.map { " (\($0))" } ?? ""
            return "Grok rejected \(method) with error \(code): \(message)\(detail)"
        case let .unsupportedMethod(method):
            return "This Grok build does not support \(method), which Conan Code requires."
        case let .extensionFailed(method, message):
            return "Grok could not complete \(method): \(message)"
        case let .malformedPayload(method, detail):
            return "Conan Code could not read Grok's response to \(method): \(detail)"
        case let .incompatibleAgent(detail):
            return "This Grok build is not compatible with Conan Code: \(detail)"
        case let .paginationStalled(cursor):
            return "Grok returned the same session-list cursor twice (\(cursor))."
        case let .malformedFrame(detail):
            return "Conan Code received a malformed message from Grok: \(detail)"
        case let .frameTooLarge(size):
            return "Conan Code received an oversized \(size) byte message from Grok."
        }
    }
}
