import Foundation

struct TerminalControlRequest: Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let method: String
    let token: String
    let requestID: String?
    let title: String?
    let cwd: String?
    let tabID: String?
    let capability: String?
    let command: String?
    let commandID: String?
    let text: String?
    let key: String?
    let cursor: String?
    let maxBytes: Int?
    let exitCode: Int?

    init(data: Data) throws {
        let value = try GrokJSONValue.decode(data)
        guard let object = value.objectValue else {
            throw TerminalControlError.invalidRequest(
                "the request must be a JSON object"
            )
        }
        guard let version = object["version"]?.intValue else {
            throw TerminalControlError.invalidRequest(
                "version is required"
            )
        }
        guard version == Self.currentVersion else {
            throw TerminalControlError.unsupportedVersion(version)
        }
        guard let method = object["method"]?.stringValue,
              !method.isEmpty else {
            throw TerminalControlError.invalidRequest(
                "method is required"
            )
        }
        guard let token = object["token"]?.stringValue,
              !token.isEmpty else {
            throw TerminalControlError.unauthorized
        }

        self.version = version
        self.method = method
        self.token = token
        requestID = object["requestID"]?.stringValue
        title = object["title"]?.stringValue
        cwd = object["cwd"]?.stringValue
        tabID = object["tabID"]?.stringValue
        capability = object["capability"]?.stringValue
        command = object["command"]?.stringValue
        commandID = object["commandID"]?.stringValue
        text = object["text"]?.stringValue
        key = object["key"]?.stringValue
        cursor = object["cursor"]?.stringValue
        maxBytes = object["maxBytes"]?.intValue
        exitCode = object["exitCode"]?.intValue
    }
}

enum TerminalControlError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unsupportedVersion(Int)
    case unauthorized
    case invocationNotObserved
    case sessionUnavailable
    case invalidDirectory(String)
    case tabGone
    case forbidden
    case shellStarting
    case shellExited
    case commandRunning
    case commandUnavailable
    case unsupportedMethod(String)
    case internalFailure(String)

    var code: String {
        switch self {
        case .invalidRequest:
            "invalid_request"
        case .unsupportedVersion:
            "unsupported_version"
        case .unauthorized:
            "unauthorized"
        case .invocationNotObserved:
            "outside_conan_code"
        case .sessionUnavailable:
            "session_unavailable"
        case .invalidDirectory:
            "invalid_directory"
        case .tabGone:
            "tab_gone"
        case .forbidden:
            "forbidden"
        case .shellStarting:
            "shell_starting"
        case .shellExited:
            "shell_exited"
        case .commandRunning:
            "command_running"
        case .commandUnavailable:
            "command_unavailable"
        case .unsupportedMethod:
            "unsupported_method"
        case .internalFailure:
            "internal_failure"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail):
            "Invalid terminal-control request: \(detail)."
        case .unsupportedVersion(let version):
            "Terminal-control protocol version \(version) is not supported."
        case .unauthorized:
            "The terminal-control credential is invalid."
        case .invocationNotObserved:
            "This command is not running inside Conan Code."
        case .sessionUnavailable:
            "The calling Grok session is not active in Conan Code."
        case .invalidDirectory(let path):
            "The requested terminal directory is unavailable: \(path)"
        case .tabGone:
            "The managed terminal tab no longer exists."
        case .forbidden:
            "The managed terminal capability is invalid."
        case .shellStarting:
            "The managed terminal shell is still starting."
        case .shellExited:
            "The managed terminal shell has exited."
        case .commandRunning:
            "The managed terminal already has a command running."
        case .commandUnavailable:
            "The managed command is no longer available."
        case .unsupportedMethod(let method):
            "Terminal-control method \(method) is not supported."
        case .internalFailure(let detail):
            "Terminal control failed: \(detail)"
        }
    }
}

struct TerminalControlResponse: Equatable, Sendable {
    let value: GrokJSONValue

    static func success(
        _ result: GrokJSONValue = .object([:])
    ) -> TerminalControlResponse {
        TerminalControlResponse(
            value: .object([
                "ok": .bool(true),
                "result": result,
            ])
        )
    }

    static func failure(
        _ error: TerminalControlError
    ) -> TerminalControlResponse {
        TerminalControlResponse(
            value: .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string(error.code),
                    "message": .string(
                        error.localizedDescription
                    ),
                ]),
            ])
        )
    }

    func encodedLine() -> Data {
        var data = (try? value.encoded()) ?? Data(
            #"{"error":{"code":"internal_failure","message":"Could not encode the response."},"ok":false}"#
                .utf8
        )
        data.append(0x0A)
        return data
    }
}
