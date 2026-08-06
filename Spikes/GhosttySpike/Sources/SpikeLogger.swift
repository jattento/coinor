import Foundation

final class SpikeLogger: @unchecked Sendable {
    private let path: String?
    private let lock = NSLock()

    init(path: String?) {
        self.path = path
        if let path {
            FileManager.default.createFile(atPath: path, contents: Data())
            if let handle = FileHandle(forWritingAtPath: path) {
                try? handle.truncate(atOffset: 0)
                try? handle.close()
            }
        }
    }

    func record(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        if let path,
           let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                FileHandle.standardError.write(Data("log error: \(error)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
