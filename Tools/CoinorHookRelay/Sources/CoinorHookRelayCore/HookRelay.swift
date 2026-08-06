import CoinorHookRelayPOSIX
import Darwin
import Dispatch
import Foundation

public struct HookRelayConfiguration: Equatable {
    public static let socketPathEnvironmentKey = "COINOR_HOOK_SOCKET"
    public static let timeoutEnvironmentKey = "COINOR_HOOK_TIMEOUT_MS"
    public static let defaultTimeoutMilliseconds = 150

    public let socketPath: String
    public let timeoutMilliseconds: Int

    public init(socketPath: String, timeoutMilliseconds: Int = defaultTimeoutMilliseconds) {
        self.socketPath = socketPath
        self.timeoutMilliseconds = min(max(timeoutMilliseconds, 1), 2_000)
    }

    public static func from(environment: [String: String]) -> HookRelayConfiguration? {
        guard let socketPath = environment[socketPathEnvironmentKey],
              !socketPath.isEmpty
        else {
            return nil
        }

        let requestedTimeout = environment[timeoutEnvironmentKey].flatMap(Int.init)
        return HookRelayConfiguration(
            socketPath: socketPath,
            timeoutMilliseconds: requestedTimeout ?? defaultTimeoutMilliseconds
        )
    }
}

public enum HookRelayProcess {
    /// Reads one complete hook payload before forking. Every failure is fail-open
    /// because Grok must never fail a turn when Coinor is unavailable.
    public static func run(
        inputFileDescriptor: Int32 = STDIN_FILENO,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        guard let configuration = HookRelayConfiguration.from(environment: environment),
              let payload = readAll(from: inputFileDescriptor),
              !payload.isEmpty,
              (try? JSONSerialization.jsonObject(with: payload)) != nil,
              let frame = try? FramedJSONCodec.frame(payload)
        else {
            return 0
        }

        let childPID = coinor_fork()
        guard childPID >= 0 else {
            return 0
        }

        if childPID > 0 {
            return 0
        }

        _ = Darwin.setsid()
        Darwin.close(STDIN_FILENO)
        Darwin.close(STDOUT_FILENO)
        Darwin.close(STDERR_FILENO)

        _ = NonblockingUnixSocketSender.send(
            frame: frame,
            to: configuration.socketPath,
            timeoutMilliseconds: configuration.timeoutMilliseconds
        )
        Darwin._exit(0)
    }

    private static func readAll(from fileDescriptor: Int32) -> Data? {
        var result = Data()
        var storage = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            let bytesRead = storage.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }

            if bytesRead > 0 {
                result.append(storage, count: bytesRead)
                continue
            }

            if bytesRead == 0 {
                return result
            }

            if errno == EINTR {
                continue
            }

            return nil
        }
    }
}

public enum NonblockingUnixSocketSender {
    public static func send(
        payload: Data,
        to socketPath: String,
        timeoutMilliseconds: Int
    ) -> Bool {
        guard let frame = try? FramedJSONCodec.frame(payload) else {
            return false
        }
        return send(
            frame: frame,
            to: socketPath,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public static func send(
        frame: Data,
        to socketPath: String,
        timeoutMilliseconds: Int
    ) -> Bool {
        guard var address = unixSocketAddress(path: socketPath) else {
            return false
        }
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return false
        }
        defer { Darwin.close(socketDescriptor) }

        var noSignal: Int32 = 1
        _ = Darwin.setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let currentFlags = Darwin.fcntl(socketDescriptor, F_GETFL)
        guard currentFlags >= 0,
              Darwin.fcntl(socketDescriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
        else {
            return false
        }

        let timeout = min(max(timeoutMilliseconds, 1), 2_000)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout) * 1_000_000

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  wait(
                      for: Int16(POLLOUT),
                      on: socketDescriptor,
                      until: deadline
                  ),
                  socketError(on: socketDescriptor) == 0
            else {
                return false
            }
        }

        return frame.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return true
            }

            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(
                    socketDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset,
                    0
                )

                if written > 0 {
                    offset += written
                    continue
                }

                if written < 0, errno == EINTR {
                    continue
                }

                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard wait(
                        for: Int16(POLLOUT),
                        on: socketDescriptor,
                        until: deadline
                    ) else {
                        return false
                    }
                    continue
                }

                return false
            }

            return true
        }
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

    private static func socketError(on socketDescriptor: Int32) -> Int32 {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = Darwin.getsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_ERROR,
            &error,
            &length
        )
        return result == 0 ? error : errno
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
