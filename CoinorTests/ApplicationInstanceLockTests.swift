import Foundation
import XCTest

@testable import Coinor

final class ApplicationInstanceLockTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ApplicationInstanceLockTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testFirstAcquisitionSucceeds() throws {
        let lock = try ApplicationInstanceLock(directoryURL: temporaryDirectory)

        XCTAssertEqual(lock.fileURL.lastPathComponent, ApplicationInstanceLock.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.fileURL.path))
    }

    func testSecondAcquisitionIsRefused() throws {
        let firstLock = try ApplicationInstanceLock(directoryURL: temporaryDirectory)
        try withExtendedLifetime(firstLock) {
            XCTAssertThrowsError(
                try ApplicationInstanceLock(directoryURL: temporaryDirectory)
            ) { error in
                guard case ApplicationInstanceLockError.alreadyRunning = error else {
                    return XCTFail("Expected alreadyRunning, received \(error).")
                }
            }
        }
    }

    func testLockCanBeReacquiredAfterOwnerIsReleased() throws {
        var firstLock: ApplicationInstanceLock? = try ApplicationInstanceLock(
            directoryURL: temporaryDirectory
        )
        XCTAssertNotNil(firstLock)

        firstLock = nil

        XCTAssertNoThrow(
            try ApplicationInstanceLock(directoryURL: temporaryDirectory)
        )
    }

    func testAlreadyRunningErrorHasStableEnglishCopy() {
        let error = ApplicationInstanceLockError.alreadyRunning

        XCTAssertEqual(error.errorDescription, "Conan Code is already running.")
        XCTAssertEqual(
            (error as LocalizedError).errorDescription,
            "Conan Code is already running."
        )
    }
}
