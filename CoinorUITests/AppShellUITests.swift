import XCTest

/// UI tests run in a separate process and cannot import the application module.
/// `AppFoundationTests.testAccessibilityIdentifiersMatchTheStringsUsedByUITests`
/// keeps these literals in step with `AppShellIdentifier`.
private enum Identifier {
    static let sidebar = "AppShellSidebar"
    static let conversationSearch = "AppShellConversationSearch"
    static let terminalRegion = "AppShellTerminalRegion"
    static let workflowsDestination = "AppShellWorkflowsDestination"
    static let workflowCenter = "WorkflowCenter"
    static let workflowRefresh = "WorkflowRefreshButton"
    static let workflowBack = "WorkflowBackButton"
    static let startupDiagnostics = "AppShellStartupDiagnostics"
}

@MainActor
final class AppShellUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let supportDirectory = ProcessInfo.processInfo.environment[
            "COINOR_APPLICATION_SUPPORT_DIRECTORY"
        ].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "CoinorUITests",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let supportLink = URL(
            fileURLWithPath: "/private/tmp/cnr-uitest",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: supportLink)
        try? FileManager.default.createSymbolicLink(
            at: supportLink,
            withDestinationURL: supportDirectory
        )
        let app = XCUIApplication()
        app.launchEnvironment[
            "COINOR_APPLICATION_SUPPORT_DIRECTORY"
        ] = supportLink.path
        app.launch()
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: supportLink)
        }
        return app
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(
        forValue value: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func wait(
        forPlaceholder placeholder: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "placeholderValue == %@",
                placeholder
            ),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func enableAgentSearch(
        in app: XCUIApplication,
        toggle: XCUIElement,
        timeout: TimeInterval = 30
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            toggle.click()
            wait(forValue: "On", of: toggle)
            if app.buttons["Find"].waitForExistence(timeout: 2) {
                return
            }
            toggle.click()
            wait(forValue: "Off", of: toggle)
        } while Date() < deadline
        XCTFail("Agent Search did not become available within \(timeout) seconds")
    }

    func testShellExposesItsPrimaryRegions() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(element(Identifier.terminalRegion, in: app).waitForExistence(timeout: 15))
    }

    func testWorkflowsDestinationOpensAndReturnsToTheConversation() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))

        let workflows = element(Identifier.workflowsDestination, in: app)
        XCTAssertTrue(workflows.waitForExistence(timeout: 5))
        workflows.click()

        XCTAssertTrue(
            element(Identifier.workflowCenter, in: app).waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["Refresh Workflows"].waitForExistence(timeout: 5)
        )

        let back = app.buttons["Back to Conversation"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.click()
        XCTAssertTrue(
            element(Identifier.terminalRegion, in: app).waitForExistence(timeout: 5)
        )
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

    func testAgentSearchToggleIsEphemeralAcrossCloseAndRelaunch() {
        let app = launchApp()
        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))

        let searchField = element(Identifier.conversationSearch, in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        wait(forPlaceholder: "Search conversations", of: searchField)

        let toggle = app.buttons["Search with Grok"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        wait(forValue: "Off", of: toggle)

        let carriedQuery = "find yesterday remote \(UUID().uuidString)"
        searchField.click()
        searchField.typeText(carriedQuery)
        wait(forValue: carriedQuery, of: searchField)

        enableAgentSearch(in: app, toggle: toggle)
        XCTAssertTrue(app.staticTexts["Agent Search"].waitForExistence(timeout: 5))
        wait(forPlaceholder: "Describe the conversation", of: searchField)
        wait(forValue: carriedQuery, of: searchField)
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5))

        toggle.click()
        wait(forValue: "Off", of: toggle)
        XCTAssertTrue(app.staticTexts["Agent Search"].waitForNonExistence(timeout: 5))
        wait(forPlaceholder: "Search conversations", of: searchField)

        enableAgentSearch(in: app, toggle: toggle)
        let firstQuery = "temporary finder query \(UUID().uuidString)"
        searchField.click()
        searchField.typeText(firstQuery)
        wait(forValue: firstQuery, of: searchField)

        toggle.click()

        wait(forValue: "Off", of: toggle)
        XCTAssertTrue(app.staticTexts["Agent Search"].waitForNonExistence(timeout: 5))
        wait(forPlaceholder: "Search conversations", of: searchField)
        XCTAssertNotEqual(searchField.value as? String, firstQuery)
        XCTAssertTrue(app.buttons["Find"].waitForNonExistence(timeout: 5))

        enableAgentSearch(in: app, toggle: toggle)
        XCTAssertTrue(app.staticTexts["Agent Search"].waitForExistence(timeout: 5))
        wait(forPlaceholder: "Describe the conversation", of: searchField)

        let relaunchQuery = "relaunch finder query \(UUID().uuidString)"
        searchField.click()
        searchField.typeText(relaunchQuery)
        wait(forValue: relaunchQuery, of: searchField)

        app.terminate()
        app.launch()

        XCTAssertTrue(element(Identifier.sidebar, in: app).waitForExistence(timeout: 15))
        let relaunchedToggle = app.buttons["Search with Grok"]
        XCTAssertTrue(relaunchedToggle.waitForExistence(timeout: 5))
        wait(forValue: "Off", of: relaunchedToggle)
        XCTAssertTrue(app.staticTexts["Agent Search"].waitForNonExistence(timeout: 5))
        let relaunchedSearchField = element(
            Identifier.conversationSearch,
            in: app
        )
        wait(
            forPlaceholder: "Search conversations",
            of: relaunchedSearchField
        )
        XCTAssertNotEqual(relaunchedSearchField.value as? String, relaunchQuery)
        XCTAssertTrue(app.buttons["Find"].waitForNonExistence(timeout: 5))
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
        // Adding a project is a menu now that a project can also come from a
        // registered remote computer.
        XCTAssertTrue(
            app.menuButtons["Add Project"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.menuButtons["Remote Computers"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Archived Items"].waitForExistence(timeout: 5))
    }
}
