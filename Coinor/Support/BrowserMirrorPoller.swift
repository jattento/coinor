import AppKit
import Foundation

/// The cadence tier a Browser Mirror tab polls at.
enum BrowserMirrorPollCadence: Equatable, Sendable {
    /// The tab is the selected, visible tab: poll fast enough to feel live.
    case visible
    /// The tab exists but is not currently selected/visible.
    case backgrounded
    /// No ACP activity for this Task Space in a while: poll just often
    /// enough to notice the Space closing or coming back to life.
    case idle

    var interval: Duration {
        switch self {
        case .visible: .seconds(1)
        case .backgrounded: .seconds(6)
        case .idle: .seconds(20)
        }
    }
}

/// Owns the live-polling loop that keeps a `BrowserMirrorTab` fed with
/// screenshots from a real `ego-browser` CLI subprocess.
///
/// Tab lifecycle (open/close) is driven entirely by the passive ACP
/// detector (`GrokBrowserToolInvocation`); this type only ever produces
/// frames or soft failures for a tab that already exists. It never decides
/// to close one.
@MainActor
enum BrowserMirrorPoller {
    /// How long without a fresh "opened" signal before a tab is considered
    /// idle for cadence purposes only — this never closes a tab by itself.
    nonisolated static let idleThreshold: TimeInterval = 10 * 60

    /// Resolves the `ego-browser` CLI and starts (or restarts) the poll
    /// loop for `tab`. If the CLI cannot be found, the tab immediately
    /// reports `.unavailable` and no subprocess is ever spawned.
    static func start(
        for tab: BrowserMirrorTab,
        locator: EgoBrowserLocator,
        isVisible: @escaping @MainActor () -> Bool,
        clientFactory: (String) -> EgoBrowserScreenshotClient = {
            EgoBrowserScreenshotClient(executablePath: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        guard let executablePath = locator.resolve() else {
            tab.applyFailure(
                reason: EgoBrowserPollError.cliNotFound.errorDescription
                    ?? "ego-browser not found",
                maxConsecutiveFailures: 1
            )
            return
        }
        start(
            for: tab,
            client: clientFactory(executablePath),
            isVisible: isVisible,
            now: now
        )
    }

    /// Starts (or restarts) the poll loop against an already-constructed
    /// client. Exposed separately so tests can inject a stubbed client
    /// without touching the filesystem-backed locator.
    static func start(
        for tab: BrowserMirrorTab,
        client: EgoBrowserScreenshotClient,
        isVisible: @escaping @MainActor () -> Bool,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                let result = await client.captureScreenshot(
                    taskSpaceName: tab.taskSpaceName
                )
                guard !Task.isCancelled else { return }
                apply(result, to: tab)
                guard !Task.isCancelled else { return }
                let interval = cadence(
                    isVisible: isVisible(),
                    lastActivityAt: tab.lastActivityAt,
                    now: now()
                ).interval
                try? await Task.sleep(for: interval)
            }
        }
        tab.attachPoller(task)
    }

    static func apply(
        _ result: Result<EgoBrowserFrame, EgoBrowserPollError>,
        to tab: BrowserMirrorTab
    ) {
        switch result {
        case .success(let frame):
            guard let image = NSImage(data: frame.jpegData) else {
                tab.applyFailure(
                    reason: "ego-browser returned an undecodable image"
                )
                return
            }
            tab.applyFrame(image: image, url: frame.url, title: frame.title)
        case .failure(let error):
            tab.applyFailure(
                reason: error.errorDescription ?? "ego-browser poll failed"
            )
        }
    }

    /// Pure cadence selection, independent of any process or timer, so it
    /// is directly testable.
    nonisolated static func cadence(
        isVisible: Bool,
        lastActivityAt: Date,
        now: Date
    ) -> BrowserMirrorPollCadence {
        if isVisible {
            return .visible
        }
        if now.timeIntervalSince(lastActivityAt) >= idleThreshold {
            return .idle
        }
        return .backgrounded
    }
}
