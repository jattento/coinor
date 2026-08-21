import Foundation
import Testing

@testable import Coinor

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "EgoBrowserLocator-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(
        to: url,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
    )
}

@Test
func resolvesTheDefaultLocalBinInstallLocationFirst() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let defaultPath = home.appendingPathComponent(
        EgoBrowserLocator.defaultRelativePath
    )
    try writeExecutable(at: defaultPath)

    let locator = EgoBrowserLocator(
        environment: [:],
        homeDirectory: home
    )

    #expect(locator.resolve() == defaultPath.path)
}

@Test
func fallsBackToSearchingPathWhenTheDefaultLocationIsMissing() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let pathDirectory = home.appendingPathComponent(
        "custom-bin",
        isDirectory: true
    )
    let executable = pathDirectory.appendingPathComponent("ego-browser")
    try writeExecutable(at: executable)

    let locator = EgoBrowserLocator(
        environment: ["PATH": "/usr/bin:\(pathDirectory.path)"],
        homeDirectory: home
    )

    #expect(locator.resolve() == executable.path)
}

@Test
func returnsNilWhenNotFoundAnywhere() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }

    let locator = EgoBrowserLocator(
        environment: ["PATH": "/usr/bin:/bin"],
        homeDirectory: home
    )

    #expect(locator.resolve() == nil)
}

@Test
func aNonExecutableFileAtTheDefaultLocationIsNotResolved() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let defaultPath = home.appendingPathComponent(
        EgoBrowserLocator.defaultRelativePath
    )
    try FileManager.default.createDirectory(
        at: defaultPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "not executable".write(
        to: defaultPath,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: defaultPath.path
    )

    let locator = EgoBrowserLocator(
        environment: ["PATH": "/usr/bin:/bin"],
        homeDirectory: home
    )

    #expect(locator.resolve() == nil)
}
