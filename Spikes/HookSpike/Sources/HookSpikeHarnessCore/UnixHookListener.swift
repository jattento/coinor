import CoinorHookRelayCore
import Darwin
import Dispatch
import Foundation

public enum UnixHookListenerError: Error {
    case socketPathTooLong
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case readFailed(Int32)
    case invalidFrame
}

public final class UnixHookListener {
    public let socketPath: String

    private let socketDescriptor: Int32

    public init(socketPath: String) throws {
        guard var address = Self.unixSocketAddress(path: socketPath) else {
            throw UnixHookListenerError.socketPathTooLong
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixHookListenerError.socketCreationFailed(errno)
        }

        _ = Darwin.unlink(socketPath)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw UnixHookListenerError.bindFailed(error)
        }

        guard Darwin.listen(descriptor, 16) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            _ = Darwin.unlink(socketPath)
            throw UnixHookListenerError.listenFailed(error)
        }

        self.socketPath = socketPath
        self.socketDescriptor = descriptor
    }

    deinit {
        Darwin.close(socketDescriptor)
        _ = Darwin.unlink(socketPath)
    }

    public func receive(timeoutMilliseconds: Int) throws -> Data? {
        let timeout = min(max(timeoutMilliseconds, 1), 30_000)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout) * 1_000_000

        guard Self.wait(
            for: Int16(POLLIN),
            on: socketDescriptor,
            until: deadline
        ) else {
            return nil
        }

        let connection = Darwin.accept(socketDescriptor, nil, nil)
        guard connection >= 0 else {
            if errno == EINTR {
                return try receive(timeoutMilliseconds: timeoutMilliseconds)
            }
            throw UnixHookListenerError.acceptFailed(errno)
        }
        defer { Darwin.close(connection) }

        var decoder = FramedJSONDecoder()
        var storage = [UInt8](repeating: 0, count: 8 * 1024)

        while Self.wait(for: Int16(POLLIN), on: connection, until: deadline) {
            let bytesRead = storage.withUnsafeMutableBytes {
                Darwin.read(connection, $0.baseAddress, $0.count)
            }

            if bytesRead > 0 {
                let frames = try decoder.append(Data(storage.prefix(bytesRead)))
                if let frame = frames.first {
                    return frame
                }
                continue
            }

            if bytesRead == 0 {
                return nil
            }
            if errno != EINTR {
                throw UnixHookListenerError.readFailed(errno)
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
        on socketDescriptor: Int32,
        until deadline: UInt64
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return false
            }

            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = Int32(
                min(
                    (remainingNanoseconds + 999_999) / 1_000_000,
                    UInt64(Int32.max)
                )
            )
            var descriptor = pollfd(
                fd: socketDescriptor,
                events: events,
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, remainingMilliseconds)

            if result > 0 {
                return descriptor.revents & events != 0
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
