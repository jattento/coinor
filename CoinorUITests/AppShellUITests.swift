import XCTest

/// UI tests run in a separate process and cannot import the application module.
/// `AppFoundationTests.testAccessibilityIdentifiersMatchTheStringsUsedByUITests`
/// keeps these literals in step with `AppShellIdentifier`.
private enum Identifier {
    static let sidebar = "AppShellSidebar"
    static let conversationSearch = "AppShellConversationSearch"
    static let terminalRegion = "AppShellTerminalRegion"
    static let startupDiagnostics = "AppShellStartupDiagnostics"
}

@MainActor
final class AppShellUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let supportDirectory = URL(
            fileURLWithPath: "/tmp",
            isDirectory: true
        )
            .appendingPathComponent(
                "CoinorUITests-\(UUID().uuidString)",
                isDirectory: true
            )
        let app = XCUIApplication()
        app.launchEnvironment[
            "COINOR_APPLICATION_SUPPORT_DIRECTORY"
        ] = supportDirectory.path
        app.launch()
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        return app
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testShellExposesItsPrimaryRegions() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element(Identifier.terminalRegion, in: app).waitForExistence(timeout: 15))
    }

    func testHealthyStartupClearsDiagnosticsAfterLeaderConnects() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.terminalRegion, in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(
            element(
                Identifier.startupDiagnostics,
                in: app
            ).waitForNonExistence(timeout: 30)
        )
    }

    func testSidebarExposesProjectAndArchiveActions() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(
            element(
                Identifier.conversationSearch,
                in: app
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Add Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Archived Items"].waitForExistence(timeout: 5))
    }
}
