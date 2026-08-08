import Darwin
import Foundation

enum ApplicationInstanceLockError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Conan Code is already running."
        case let .openFailed(path, errorNumber):
            "Conan Code could not open its instance lock at \(path) (errno \(errorNumber))."
        case let .lockFailed(path, errorNumber):
            "Conan Code could not acquire its instance lock at \(path) (errno \(errorNumber))."
        }
    }
}

final class ApplicationInstanceLock: Sendable {
    static let fileName = "Coinor.lock"

    let fileURL: URL
    private let fileDescriptor: Int32

    init(fileURL: URL) throws {
        self.fileURL = fileURL.standardizedFileURL
        let path = self.fileURL.path

        let descriptor = self.fileURL.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(
                fileSystemPath,
                O_RDWR | O_CREAT | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }

        guard descriptor >= 0 else {
            throw ApplicationInstanceLockError.openFailed(path: path, errno: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)

            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                throw ApplicationInstanceLockError.alreadyRunning
            }
            throw ApplicationInstanceLockError.lockFailed(path: path, errno: errorNumber)
        }

        fileDescriptor = descriptor
    }

    convenience init(directoryURL: URL, fileName: String = fileName) throws {
        try self.init(fileURL: directoryURL.appendingPathComponent(fileName, isDirectory: false))
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
