import XCTest

/// Drives the remote-host interface the way a person does: opens the sidebar
/// menu, registers a real computer, checks that it reports itself connected,
/// and removes it again.
///
/// Runs only when `COINOR_LIVE_REMOTE_HOST` names an alias from
/// `~/.ssh/config`, because it performs a real SSH connection. It always
/// removes the host it registered so the application is left as it was found.
@MainActor
final class RemoteHostUITests: XCTestCase {
    private var alias: String? {
        ProcessInfo.processInfo.environment["COINOR_LIVE_REMOTE_HOST"]
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(alias == nil, "COINOR_LIVE_REMOTE_HOST is not set")
    }

    /// Runs against an isolated support directory, exactly like the other UI
    /// tests, so the user's own projects, pins, and registered computers are
    /// never touched.
    private func launchApp() -> XCUIApplication {
        // The real support directory is `~/Library/Application Support/…`,
        // whose space once broke the SSH control path. The isolated directory
        // used here keeps a space so that can never pass unnoticed again.
        let supportDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "Coinor UI Tests \(UUID().uuidString.prefix(8))",
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

    func testRegisteringAndRemovingARemoteComputerThroughTheInterface() throws {
        let alias = try XCTUnwrap(self.alias)
        let app = launchApp()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "AppShellSidebar")
                .firstMatch
                .waitForExistence(timeout: 30)
        )

        let remoteMenu = app.menuButtons["Remote Computers"]
        XCTAssertTrue(remoteMenu.waitForExistence(timeout: 15))
        remoteMenu.click()

        let addItem = app.menuItems["Add Remote Computer…"]
        XCTAssertTrue(addItem.waitForExistence(timeout: 10))
        addItem.click()

        XCTAssertTrue(
            app.staticTexts["Add Remote Computer"].waitForExistence(timeout: 10)
        )

        // The alias comes from the user's own SSH configuration; the sheet
        // must offer it without any typing.
        let row = app.staticTexts[alias]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(alias) was not offered")
        row.click()

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        // Registering runs a real SSH health check, so it is given room.
        let sheetClosed = app.staticTexts["Add Remote Computer"]
            .waitForNonExistence(timeout: 120)
        XCTAssertTrue(sheetClosed, "the add sheet stayed open, so registering failed")

        remoteMenu.click()
        let manageItem = app.menuItems["Manage Remote Computers…"]
        XCTAssertTrue(manageItem.waitForExistence(timeout: 10))
        manageItem.click()

        XCTAssertTrue(
            app.staticTexts["Remote Computers"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts[alias].waitForExistence(timeout: 10),
            "the registered computer is missing from the management view"
        )
        XCTAssertTrue(
            app.staticTexts["Connected"].waitForExistence(timeout: 60),
            "the registered computer never reported itself connected"
        )

        // Close the management sheet before using the project picker.
        app.typeKey(.escape, modifierFlags: [])

        let projectBadge = try addARemoteProject(app: app, alias: alias)
        try openAConversationInTheRemoteProject(app: app, row: projectBadge)

        // Leave the application exactly as it was found.
        let remoteMenuAgain = app.menuButtons["Remote Computers"]
        remoteMenuAgain.click()
        app.menuItems["Manage Remote Computers…"].click()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        remove.click()
        XCTAssertTrue(
            app.staticTexts["No Remote Computers"].waitForExistence(timeout: 20)
        )
    }

    /// The whole point of a remote project: starting a conversation in it must
    /// open a terminal, not an error about a directory that only exists on the
    /// other computer.
    private func openAConversationInTheRemoteProject(
        app: XCUIApplication,
        row: XCUIElement
    ) throws {
        // The control only appears while its project row is hovered.
        row.hover()
        let newConversation = app.menuButtons["New Conversation"].firstMatch
        XCTAssertTrue(newConversation.waitForExistence(timeout: 20))
        newConversation.click()

        let inMainCheckout = app.menuItems["In Main Checkout"]
        XCTAssertTrue(inMainCheckout.waitForExistence(timeout: 10))
        inMainCheckout.click()

        let unavailable = app.staticTexts.containing(
            NSPredicate(
                format: "value CONTAINS[c] %@",
                "working directory is unavailable"
            )
        ).firstMatch
        XCTAssertFalse(
            unavailable.waitForExistence(timeout: 12),
            "the remote conversation reported its working directory as unavailable"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "AppShellTerminalRegion")
                .firstMatch
                .waitForExistence(timeout: 20)
        )
    }

    /// The picker must let the user choose a repository on the other computer
    /// without ever typing a path.
    @discardableResult
    private func addARemoteProject(
        app: XCUIApplication,
        alias: String
    ) throws -> XCUIElement {
        let addProject = app.menuButtons["Add Project"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 15))
        addProject.click()

        let remoteItem = app.menuItems["From Remote Computer"]
        XCTAssertTrue(remoteItem.waitForExistence(timeout: 10))
        remoteItem.hover()

        let aliasItem = app.menuItems[alias]
        XCTAssertTrue(aliasItem.waitForExistence(timeout: 10))
        aliasItem.click()

        XCTAssertTrue(
            app.staticTexts["Add Remote Project"].waitForExistence(timeout: 20),
            "the remote project picker did not open"
        )

        // Discovery runs a bounded scan on the other computer.
        let addProjectButton = app.buttons["Add Project"]
        XCTAssertTrue(addProjectButton.waitForExistence(timeout: 20))

        let candidate = app.tables.cells.element(boundBy: 0)
            .waitForExistence(timeout: 90)
            ? app.tables.cells.element(boundBy: 0)
            : app.outlines.cells.element(boundBy: 0)
        XCTAssertTrue(
            candidate.waitForExistence(timeout: 60),
            "no repository was offered by the picker"
        )
        candidate.click()

        XCTAssertTrue(addProjectButton.isEnabled)
        addProjectButton.click()

        XCTAssertTrue(
            app.staticTexts["Add Remote Project"].waitForNonExistence(timeout: 60),
            "the picker stayed open, so adding the project failed"
        )

        // The project must appear in the same flat list, marked with its host.
        let badge = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@",
                    "Remote computer \(alias)"
                )
            )
            .firstMatch
        XCTAssertTrue(
            badge.waitForExistence(timeout: 30),
            "the remote project row is missing its host badge"
        )
        return badge
    }
}
