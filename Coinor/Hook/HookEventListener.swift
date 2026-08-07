import Darwin
import Dispatch
import Foundation

enum HookEventListenerError: LocalizedError {
    case socketPathTooLong
    case socketCreation(Int32)
    case bind(Int32)
    case listen(Int32)
    case accept(Int32)
    case read(Int32)
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            "The Coinor hook socket path is too long."
        case .socketCreation(let code):
            "Coinor could not create its hook socket (\(code))."
        case .bind(let code):
            "Coinor could not bind its hook socket (\(code))."
        case .listen(let code):
            "Coinor could not listen for Grok hook events (\(code))."
        case .accept(let code):
            "Coinor could not accept a Grok hook event (\(code))."
        case .read(let code):
            "Coinor could not read a Grok hook event (\(code))."
        case .invalidFrame:
            "Coinor received an invalid Grok hook frame."
        }
    }
}

final class HookEventListener: @unchecked Sendable {
    let socketPath: String

    private let stateLock = NSLock()
    private var socketDescriptor: Int32
    private var stopped = false

    init(socketPath: String) throws {
        guard var address = Self.unixSocketAddress(path: socketPath) else {
            throw HookEventListenerError.socketPathTooLong
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HookEventListenerError.socketCreation(errno)
        }
        _ = Darwin.unlink(socketPath)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw HookEventListenerError.bind(code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = Darwin.unlink(socketPath)
            throw HookEventListenerError.listen(code)
        }

        self.socketPath = socketPath
        self.socketDescriptor = descriptor
    }

    deinit {
        stop()
    }

    func events() -> AsyncThrowingStream<GrokHookEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    while !self.isStopped {
                        if let data = try self.receive(timeoutMilliseconds: 500),
                           let event = try? GrokHookEvent.decode(data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    if self.isStopped {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let descriptor = socketDescriptor
        socketDescriptor = -1
        stateLock.unlock()

        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        _ = Darwin.unlink(socketPath)
    }

    private var isStopped: Bool {
        stateLock.coinorWithLock { stopped }
    }

    private func receive(timeoutMilliseconds: Int) throws -> Data? {
        let descriptor = stateLock.coinorWithLock { socketDescriptor }
        guard descriptor >= 0 else { return nil }
        guard Self.wait(
            for: Int16(POLLIN),
            on: descriptor,
            timeoutMilliseconds: timeoutMilliseconds
        ) else {
            return nil
        }

        let connection = Darwin.accept(descriptor, nil, nil)
        guard connection >= 0 else {
            if isStopped || errno == EINTR {
                return nil
            }
            throw HookEventListenerError.accept(errno)
        }
        defer { Darwin.close(connection) }

        var bytes = Data()
        var expectedLength: Int?
        var storage = [UInt8](repeating: 0, count: 8 * 1024)

        while Self.wait(
            for: Int16(POLLIN),
            on: connection,
            timeoutMilliseconds: timeoutMilliseconds
        ) {
            let count = storage.withUnsafeMutableBytes {
                Darwin.read(connection, $0.baseAddress, $0.count)
            }
            if count > 0 {
                bytes.append(storage, count: count)
                if expectedLength == nil, bytes.count >= 4 {
                    expectedLength = bytes.prefix(4).reduce(0) {
                        ($0 << 8) | Int($1)
                    }
                    guard expectedLength! <= 16 * 1024 * 1024 else {
                        throw HookEventListenerError.invalidFrame
                    }
                }
                if let expectedLength,
                   bytes.count >= expectedLength + 4 {
                    return bytes.subdata(in: 4 ..< expectedLength + 4)
                }
                continue
            }
            if count == 0 {
                return nil
            }
            if errno != EINTR {
                throw HookEventListenerError.read(errno)
            }
        }
        return nil
    }

    private static func unixSocketAddress(path: String) -> sockaddr_un? {
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return address
    }

    private static func wait(
        for events: Int16,
        on descriptor: Int32,
        timeoutMilliseconds: Int
    ) -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                Int32(min(max(timeoutMilliseconds, 1), 30_000))
            )
            if result > 0 {
                return pollDescriptor.revents & events != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return false
            }
        }
    }
}

private extension NSLock {
    func coinorWithLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
