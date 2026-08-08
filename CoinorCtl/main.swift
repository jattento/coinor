import Darwin
import Foundation

func writeLine(_ message: String, to handle: FileHandle) {
    handle.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    writeLine("coinorctl: \(message)", to: .standardError)
    exit(1)
}

struct ParsedOptions {
    private var values: [String: String] = [:]

    init(_ arguments: [String], allowed: Set<String>) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                fail("unexpected argument '\(argument)'")
            }
            let flag = String(argument.dropFirst(2))
            guard allowed.contains(flag) else {
                fail("unknown option --\(flag)")
            }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                fail("missing value for --\(flag)")
            }
            values[flag] = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        }
    }

    func required(_ flag: String) -> String {
        guard let value = values[flag] else {
            fail("missing required option --\(flag)")
        }
        return value
    }

    func optional(_ flag: String) -> String? {
        values[flag]
    }

    func requiredInt(_ flag: String) -> Int {
        let raw = required(flag)
        guard let value = Int(raw) else {
            fail("invalid integer for --\(flag): '\(raw)'")
        }
        return value
    }

    func optionalInt(_ flag: String) -> Int? {
        guard let raw = values[flag] else { return nil }
        guard let value = Int(raw) else {
            fail("invalid integer for --\(flag): '\(raw)'")
        }
        return value
    }
}

func buildRequest(
    command: String,
    arguments: [String]
) -> (method: String, fields: [String: Any]) {
    switch command {
    case "create":
        let options = ParsedOptions(
            arguments,
            allowed: ["request-id", "title", "cwd"]
        )
        return ("create", [
            "requestID": options.required("request-id"),
            "title": options.optional("title") ?? "Service",
            "cwd": options.optional("cwd")
                ?? FileManager.default.currentDirectoryPath,
        ])
    case "execute":
        let options = ParsedOptions(
            arguments,
            allowed: ["tab", "capability", "command"]
        )
        return ("execute", [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
            "command": options.required("command"),
        ])
    case "read":
        let options = ParsedOptions(
            arguments,
            allowed: [
                "tab", "capability", "cursor", "max-bytes",
            ]
        )
        var fields: [String: Any] = [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
        ]
        if let cursor = options.optional("cursor") {
            fields["cursor"] = cursor
        }
        if let maxBytes = options.optionalInt("max-bytes") {
            fields["maxBytes"] = maxBytes
        }
        return ("read", fields)
    case "write":
        let options = ParsedOptions(
            arguments,
            allowed: ["tab", "capability", "text"]
        )
        return ("write", [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
            "text": options.required("text"),
        ])
    case "key":
        let options = ParsedOptions(
            arguments,
            allowed: ["tab", "capability", "key"]
        )
        return ("key", [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
            "key": options.required("key"),
        ])
    case "interrupt", "status", "close", "shell-ready":
        let options = ParsedOptions(
            arguments,
            allowed: ["tab", "capability"]
        )
        return (command, [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
        ])
    case "fetch-command":
        let options = ParsedOptions(
            arguments,
            allowed: ["tab", "capability", "command-id"]
        )
        return ("fetch-command", [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
            "commandID": options.required("command-id"),
        ])
    case "command-finished":
        let options = ParsedOptions(
            arguments,
            allowed: [
                "tab", "capability", "command-id", "exit-code",
            ]
        )
        return ("command-finished", [
            "tabID": options.required("tab"),
            "capability": options.required("capability"),
            "commandID": options.required("command-id"),
            "exitCode": options.requiredInt("exit-code"),
        ])
    default:
        fail("unknown command '\(command)'")
    }
}

func finalizePayload(
    method: String,
    fields: [String: Any],
    token: String
) -> [String: Any] {
    var payload = fields
    payload["version"] = 1
    payload["method"] = method
    payload["token"] = token
    return payload
}

func sendRequest(socketPath: String, body: Data) -> Data {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        fail(
            "failed to create socket: "
                + String(cString: strerror(errno))
        )
    }
    defer { close(descriptor) }
    var noSignal = Int32(1)
    _ = withUnsafePointer(to: &noSignal) {
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            $0,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let pathBytes = Array(socketPath.utf8)
    let maximumPathLength =
        MemoryLayout.size(ofValue: address.sun_path) - 1
    guard pathBytes.count <= maximumPathLength else {
        fail("control socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
        let path = rawPath.bindMemory(to: Int8.self)
        for (offset, byte) in pathBytes.enumerated() {
            path[offset] = Int8(bitPattern: byte)
        }
        path[pathBytes.count] = 0
    }

    let addressLength = socklen_t(
        MemoryLayout<sockaddr_un>.size
    )
    let connectResult = withUnsafePointer(to: &address) {
        pointer -> Int32 in
        pointer.withMemoryRebound(
            to: sockaddr.self,
            capacity: 1
        ) {
            connect(descriptor, $0, addressLength)
        }
    }
    guard connectResult == 0 else {
        fail(
            "failed to connect to Coinor control socket: "
                + String(cString: strerror(errno))
        )
    }

    var written = 0
    body.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        while written < buffer.count {
            let result = write(
                descriptor,
                base.advanced(by: written),
                buffer.count - written
            )
            if result < 0 {
                if errno == EINTR { continue }
                fail(
                    "failed to write request: "
                        + String(cString: strerror(errno))
                )
            }
            written += result
        }
    }

    guard shutdown(descriptor, SHUT_WR) == 0 else {
        fail(
            "failed to shut down socket for writing: "
                + String(cString: strerror(errno))
        )
    }

    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let bytesRead = chunk.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress, $0.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            fail(
                "failed to read response: "
                    + String(cString: strerror(errno))
            )
        }
        if bytesRead == 0 { break }
        response.append(contentsOf: chunk.prefix(bytesRead))
    }
    return response
}

func parseObject(_ data: Data) -> [String: Any]? {
    guard let value = try? JSONSerialization.jsonObject(with: data)
    else {
        return nil
    }
    return value as? [String: Any]
}

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["CONAN_CODE_CONTROL_SOCKET"],
      !socketPath.isEmpty,
      let token = environment["CONAN_CODE_CONTROL_TOKEN"],
      !token.isEmpty else {
    fail("not running inside Conan Code")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("missing command")
}
let request = buildRequest(
    command: command,
    arguments: Array(arguments.dropFirst())
)
let payload = finalizePayload(
    method: request.method,
    fields: request.fields,
    token: token
)

let requestBody: Data
do {
    var json = try JSONSerialization.data(
        withJSONObject: payload
    )
    json.append(0x0A)
    requestBody = json
} catch {
    fail("failed to encode request: \(error.localizedDescription)")
}

let responseData = sendRequest(
    socketPath: socketPath,
    body: requestBody
)
let responseObject = parseObject(responseData)
let ok = responseObject?["ok"] as? Bool == true

if command == "fetch-command" {
    if ok,
       let result = responseObject?["result"] as? [String: Any],
       let commandText = result["command"] as? String {
        FileHandle.standardOutput.write(Data(commandText.utf8))
        exit(0)
    }
} else if ok {
    FileHandle.standardOutput.write(responseData)
    exit(0)
}

if responseData.isEmpty {
    writeLine(
        "coinorctl: no response from Coinor control socket",
        to: .standardError
    )
} else {
    FileHandle.standardError.write(responseData)
}
exit(1)
