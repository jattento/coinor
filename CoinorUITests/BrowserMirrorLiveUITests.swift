import XCTest

/// Manual/live QA proof, not a CI-safe test: drives the real, shipped
/// Conan Code UI end to end — add a real project, start a real conversation,
/// ask a real agent to use `ego-browser` — and asserts a Browser Mirror tab
/// actually appears with a live frame. Depends on a live LLM turn and the
/// real `ego-browser`/`ego lite` install on the machine, so it is gated
/// behind an opt-in env var, the same convention already used for
/// `COINOR_RUN_LIVE_AGENTIC_FINDER`.
@MainActor
final class BrowserMirrorLiveUITests: XCTestCase {
    private func launchApp() -> (app: XCUIApplication, supportDirectory: URL) {
        continueAfterFailure = false
        // The terminal-control Unix socket path has a hard 103-byte limit
        // (`TerminalControlSocket.maximumPathLength`), so — exactly like
        // `AppShellUITests.launchApp()` — the app is pointed at a short
        // `/private/tmp` symlink rather than the long per-run temporary
        // directory XCTest normally provides.
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CoinorBrowserMirrorLiveUITest-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let supportLink = URL(
            fileURLWithPath: "/private/tmp/cnr-browser-mirror-uitest",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: supportLink)
        try? FileManager.default.createSymbolicLink(
            at: supportLink,
            withDestinationURL: supportDirectory
        )
        let app = XCUIApplication()
        app.launchEnvironment["COINOR_APPLICATION_SUPPORT_DIRECTORY"] =
            supportLink.path
        app.launch()
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: supportLink)
        }
        return (app, supportDirectory)
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testAgentDrivenEgoBrowserUsageOpensALiveBrowserMirrorTab() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "COINOR_RUN_LIVE_BROWSER_MIRROR_UI"
            ] == "1",
            "Set COINOR_RUN_LIVE_BROWSER_MIRROR_UI=1 to run this live, "
                + "agent-driven manual QA test."
        )

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "coinor-browser-mirror-qa-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: repo,
            withIntermediateDirectories: true
        )
        try Data("Coinor Browser Mirror QA fixture\n".utf8).write(
            to: repo.appendingPathComponent("README.md")
        )
        try runGit(["init"], in: repo)
        try runGit(
            [
                "-c", "user.email=qa@coinor.test",
                "-c", "user.name=Coinor QA",
                "add", ".",
            ],
            in: repo
        )
        try runGit(
            [
                "-c", "user.email=qa@coinor.test",
                "-c", "user.name=Coinor QA",
                "commit", "-m", "QA fixture",
            ],
            in: repo
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: repo)
        }

        let (app, supportDirectory) = launchApp()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let addProject = app.menuButtons["Add Project"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 15))
        addProject.click()
        let onThisMac = app.menuItems["On This Mac…"]
        XCTAssertTrue(onThisMac.waitForExistence(timeout: 5))
        onThisMac.click()

        // NSOpenPanel: "Go to folder" and type the path directly rather than
        // navigating, then confirm with the panel's "Add" button
        // (`panel.prompt = "Add"` in AppShellSidebar.addProject()).
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = sheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        pathField.typeText(repo.path)
        pathField.typeText("\n")
        let addButton = sheet.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let projectName = repo.lastPathComponent
        let projectRow = app.staticTexts[projectName]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10))

        let newConversation = app.menuButtons["New Conversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 10))
        newConversation.click()
        let inMainCheckout = app.menuItems["In Main Checkout"]
        XCTAssertTrue(inMainCheckout.waitForExistence(timeout: 5))
        inMainCheckout.click()

        let terminalRegion = element("AppShellTerminalRegion", in: app)
        XCTAssertTrue(terminalRegion.waitForExistence(timeout: 30))

        // Give the fresh root Grok session a moment to finish starting
        // before typing into its terminal.
        Thread.sleep(forTimeInterval: 5)
        terminalRegion.click()
        app.typeText(
            "ego-browser: open https://example.com and tell me the page title"
        )
        app.typeKey(.return, modifierFlags: [])

        let browserMirror = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'browser-mirror.'")
        ).firstMatch
        let appeared = browserMirror.waitForExistence(timeout: 150)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "BrowserMirrorLiveQA"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(
            appeared,
            "No Browser Mirror tab (identifier prefix 'browser-mirror.') "
                + "appeared within the timeout after asking the agent to "
                + "use ego-browser."
        )
    }
}
