import Darwin
import Dispatch
import Foundation

struct TerminalControlSocket: Equatable, Sendable {
    static let maximumPathLength = 103

    let path: String

    init(path: String) throws {
        guard path.hasPrefix("/") else {
            throw TerminalControlError.internalFailure(
                "the socket path is not absolute"
            )
        }
        guard path.utf8.count <= Self.maximumPathLength else {
            throw TerminalControlError.internalFailure(
                "the socket path exceeds \(Self.maximumPathLength) bytes"
            )
        }
        self.path = path
    }

    static func coinorDefault(
        supportDirectory: URL
    ) throws -> TerminalControlSocket {
        try TerminalControlSocket(
            path: supportDirectory
                .appendingPathComponent(
                    "terminal-control.sock",
                    isDirectory: false
                )
                .path
        )
    }
}

enum TerminalControlServerError: LocalizedError {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)

    var errorDescription: String? {
        switch self {
        case .socket(let code):
            "Conan Code could not create its terminal-control socket (\(code))."
        case .bind(let code):
            "Conan Code could not bind its terminal-control socket (\(code))."
        case .listen(let code):
            "Conan Code could not listen on its terminal-control socket (\(code))."
        }
    }
}

final class TerminalControlServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (
        TerminalControlRequest
    ) async -> TerminalControlResponse

    private static let maximumRequestBytes = 1024 * 1024
    private let socket: TerminalControlSocket
    private let handler: Handler
    private let queue = DispatchQueue(
        label: "dev.coinor.terminal-control.accept"
    )
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(
        socket: TerminalControlSocket,
        handler: @escaping Handler
    ) {
        self.socket = socket
        self.handler = handler
    }

    func start() throws {
        guard var address = Self.unixSocketAddress(
            path: socket.path
        ) else {
            throw TerminalControlServerError.bind(ENAMETOOLONG)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TerminalControlServerError.socket(errno)
        }

        _ = Darwin.unlink(socket.path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw TerminalControlServerError.bind(code)
        }
        guard Darwin.chmod(socket.path, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = Darwin.unlink(socket.path)
            throw TerminalControlServerError.bind(code)
        }
        guard Darwin.listen(descriptor, 32) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = Darwin.unlink(socket.path)
            throw TerminalControlServerError.listen(code)
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        lock.lock()
        self.descriptor = descriptor
        self.source = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        descriptor = -1
        lock.unlock()
        guard let source else { return }
        _ = Darwin.unlink(socket.path)
        source.cancel()
    }

    deinit {
        stop()
    }

    private func acceptAvailableConnections() {
        while true {
            lock.lock()
            let listener = descriptor
            lock.unlock()
            guard listener >= 0 else { return }

            let connection = Darwin.accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }
            var noSignal = Int32(1)
            _ = withUnsafePointer(to: &noSignal) {
                Darwin.setsockopt(
                    connection,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            let handler = self.handler
            Task.detached(priority: .utility) {
                await Self.serve(
                    connection: connection,
                    handler: handler
                )
            }
        }
    }

    private static func serve(
        connection: Int32,
        handler: Handler
    ) async {
        defer { Darwin.close(connection) }
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(connection, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            write(
                TerminalControlResponse.failure(.unauthorized)
                    .encodedLine(),
                to: connection
            )
            return
        }

        do {
            let data = try readRequest(from: connection)
            let request = try TerminalControlRequest(data: data)
            let response = await handler(request)
            write(response.encodedLine(), to: connection)
        } catch let error as TerminalControlError {
            write(
                TerminalControlResponse.failure(error).encodedLine(),
                to: connection
            )
        } catch {
            write(
                TerminalControlResponse.failure(
                    .invalidRequest(error.localizedDescription)
                ).encodedLine(),
                to: connection
            )
        }
    }

    private static func readRequest(
        from descriptor: Int32
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + 5_000_000_000

        while result.count <= maximumRequestBytes {
            guard waitForInput(
                on: descriptor,
                deadline: deadline
            ) else {
                throw TerminalControlError.invalidRequest(
                    "the request timed out"
                )
            }
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                if let newline = result.firstIndex(of: 0x0A) {
                    guard newline <= maximumRequestBytes else {
                        throw TerminalControlError.invalidRequest(
                            "the request exceeds \(maximumRequestBytes) bytes"
                        )
                    }
                    return Data(result.prefix(upTo: newline))
                }
                continue
            }
            if count == 0 {
                guard !result.isEmpty else {
                    throw TerminalControlError.invalidRequest(
                        "the request was empty"
                    )
                }
                return result
            }
            if errno != EINTR {
                throw TerminalControlError.invalidRequest(
                    "the request could not be read"
                )
            }
        }
        throw TerminalControlError.invalidRequest(
            "the request exceeds \(maximumRequestBytes) bytes"
        )
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(
                    descriptor,
                    pointer,
                    remaining
                )
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func waitForInput(
        on descriptor: Int32,
        deadline: UInt64
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let milliseconds = Int32(
                min(
                    (deadline - now + 999_999) / 1_000_000,
                    UInt64(Int32.max)
                )
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                milliseconds
            )
            if result > 0 {
                return pollDescriptor.revents & Int16(POLLIN) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return false
            }
        }
    }

    private static func unixSocketAddress(
        path: String
    ) -> sockaddr_un? {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count
                <= MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(
                as: UInt8.self,
                repeating: 0
            )
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }
}
