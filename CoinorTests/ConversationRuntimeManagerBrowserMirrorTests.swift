import Foundation
import Testing

@testable import Coinor

/// Real `GhosttyRuntime`, shared across every test in this file exactly the
/// way `AppCoordinator` shares one instance across every conversation for
/// the life of the app — constructing a second, independent
/// `ghostty_app_t` per test would be both wasteful and untested territory
/// for this codebase's Ghostty integration.
@MainActor
private let sharedGhosttyRuntime = try! GhosttyRuntime()

@MainActor
private func makeManager() -> ConversationRuntimeManager {
    ConversationRuntimeManager(
        ghosttyRuntime: sharedGhosttyRuntime,
        grokExecutable: "/usr/bin/true",
        leaderSocket: "/tmp/coinor-browser-mirror-tests-leader.sock"
    )
}

/// Never resolves to a real binary, so `BrowserMirrorPoller.start` reports
/// `.unavailable` synchronously and spawns no subprocess or async task —
/// these tests exercise the real tab-list/lifecycle code around the poller
/// without depending on `ego-browser` being installed.
private let unresolvableLocator = EgoBrowserLocator(
    environment: ["PATH": "/usr/bin:/bin"],
    homeDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
)

@Test
@MainActor
func openingABrowserMirrorTabAddsItToTheConversationsTabListAsSelectable() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )

    let tab = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "research the topic",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )

    #expect(
        runtime.tabs.contains {
            $0.id == tab.id && $0.kind == .browserMirror
        }
    )
    #expect(runtime.browserMirrorTabs.map(\.id) == [tab.id])
    #expect(runtime.selectedTabID != tab.id)

    runtime.selectTab(tabID: tab.id)

    #expect(runtime.selectedTabID == tab.id)
}

@Test
@MainActor
func reopeningTheSameOwnerAndTaskSpaceReusesTheSameTabInstead() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )

    let first = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "same space",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )
    let second = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "same space",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )

    #expect(first.id == second.id)
    #expect(runtime.browserMirrorTabs.count == 1)
}

@Test
@MainActor
func aDifferentTaskSpaceNameOpensASecondIndependentTab() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )

    let first = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "space one",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )
    let second = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "space two",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )

    #expect(first.id != second.id)
    #expect(runtime.browserMirrorTabs.count == 2)
    #expect(
        Set(runtime.tabs.filter { $0.kind == .browserMirror }.map(\.id))
            == [first.id, second.id]
    )
}

@Test
@MainActor
func closingAnIndividualBrowserMirrorTabRemovesItFromTheTabListAndClearsSelection() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )
    let tab = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "research the topic",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )
    runtime.selectTab(tabID: tab.id)
    #expect(runtime.selectedTabID == tab.id)

    runtime.closeBrowserMirrorTab(tabID: tab.id)

    #expect(runtime.browserMirrorTabs.isEmpty)
    #expect(!runtime.tabs.contains { $0.id == tab.id })
    #expect(runtime.selectedTabID != tab.id)
}

/// Regression test for the bug the verification panel caught: an
/// ACP-observed close signal without `keep: true` must remove the tab from
/// the strip immediately, not merely flip its published `state` while
/// leaving it mounted forever.
@Test
@MainActor
func anACPCloseSignalWithoutKeepFrameRemovesTheTabFromTheList() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )
    let tab = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "one-shot task",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )

    runtime.closeBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "one-shot task",
        keepFrame: false
    )

    #expect(runtime.browserMirrorTabs.isEmpty)
    #expect(!runtime.tabs.contains { $0.id == tab.id })
}

/// The `keep: true` counterpart: the tab must stay mounted, in `.finished`
/// state, until the user closes it themselves.
@Test
@MainActor
func anACPCloseSignalWithKeepFrameLeavesTheTabMountedAsFinished() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )
    let tab = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "leave open for review",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )

    runtime.closeBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "leave open for review",
        keepFrame: true
    )

    #expect(runtime.browserMirrorTabs.map(\.id) == [tab.id])
    #expect(runtime.tabs.contains { $0.id == tab.id })
    #expect(tab.state == .finished)

    // The user can still close it manually afterward.
    runtime.closeBrowserMirrorTab(tabID: tab.id)
    #expect(runtime.browserMirrorTabs.isEmpty)
}

@Test
@MainActor
func fullRuntimeShutdownRemovesEveryBrowserMirrorTab() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )
    _ = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "space one",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )
    _ = runtime.openBrowserMirrorTab(
        ownerSessionID: runtime.id,
        taskSpaceName: "space two",
        locator: unresolvableLocator,
        isVisible: { _ in false }
    )
    #expect(runtime.browserMirrorTabs.count == 2)

    runtime.shutdown()

    #expect(runtime.browserMirrorTabs.isEmpty)
    #expect(!runtime.tabs.contains { $0.kind == .browserMirror })
}

/// Manager-level routing: `ConversationRuntimeManager.openBrowserMirrorTab`
/// resolves the owning root conversation the same way `createManagedTab`
/// already does, and both manager-level entry points no-op for a root
/// session that is not currently loaded.
@Test
@MainActor
func managerLevelOpenAndCloseRouteToTheCorrectLoadedConversation() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )

    let tab = manager.openBrowserMirrorTab(
        rootSessionID: runtime.id,
        ownerSessionID: runtime.id,
        taskSpaceName: "manager routed space",
        locator: unresolvableLocator
    )

    #expect(tab != nil)
    #expect(runtime.browserMirrorTabs.map(\.id) == [tab?.id])

    manager.closeBrowserMirrorTab(
        rootSessionID: runtime.id,
        ownerSessionID: runtime.id,
        taskSpaceName: "manager routed space",
        keepFrame: false
    )

    #expect(runtime.browserMirrorTabs.isEmpty)
}

@Test
@MainActor
func managerLevelOpenAndCloseAreNoOpsForAnUnloadedConversation() {
    let manager = makeManager()

    let tab = manager.openBrowserMirrorTab(
        rootSessionID: "no-such-conversation-\(UUID().uuidString)",
        ownerSessionID: "no-such-conversation",
        taskSpaceName: "orphaned space",
        locator: unresolvableLocator
    )

    #expect(tab == nil)

    // Must not crash or throw for a root session Coinor never loaded.
    manager.closeBrowserMirrorTab(
        rootSessionID: "no-such-conversation-\(UUID().uuidString)",
        ownerSessionID: "no-such-conversation",
        taskSpaceName: "orphaned space",
        keepFrame: false
    )
}

/// A Browser Mirror tab opened by a subagent's session ID still surfaces in
/// its *parent* conversation's tab list — the same rule
/// `addDescendant`/subagent panes already follow.
@Test
@MainActor
func aSubagentOwnedTabSurfacesInTheParentConversationsTabList() {
    let manager = makeManager()
    let runtime = manager.activateRoot(
        sessionID: "root-\(UUID().uuidString)",
        workingDirectory: NSHomeDirectory(),
        mode: .newSession
    )
    let subagentSessionID = "subagent-\(UUID().uuidString)"
    runtime.addDescendant(
        TerminalSession(
            launch: TerminalLaunchRequest(
                sessionID: subagentSessionID,
                workingDirectory: NSHomeDirectory(),
                grokExecutable: "/usr/bin/true",
                leaderSocket: "/tmp/coinor-browser-mirror-tests-leader.sock",
                mode: .resume
            ),
            runtime: sharedGhosttyRuntime
        ),
        startedAt: "2026-01-01T00:00:00Z",
        sequence: 1
    )

    let tab = manager.openBrowserMirrorTab(
        rootSessionID: runtime.id,
        ownerSessionID: subagentSessionID,
        taskSpaceName: "subagent research",
        locator: unresolvableLocator
    )

    #expect(tab?.ownerSessionID == subagentSessionID)
    #expect(runtime.browserMirrorTabs.map(\.id) == [tab?.id])
}
