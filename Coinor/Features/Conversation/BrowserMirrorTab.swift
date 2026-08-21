import AppKit
import Foundation

/// The lifecycle state of one `BrowserMirrorTab`.
enum BrowserMirrorState: Equatable, Sendable {
    /// Created, waiting for the first successful poll.
    case connecting
    /// At least one frame has been published.
    case live
    /// The owning agent finished the task and asked to keep the last frame
    /// visible (`completeTaskSpace(..., { keep: true })`).
    case finished
    /// The Task Space closed and the tab is scheduled for removal.
    case closed
    /// The `ego-browser` CLI is missing, or polling failed repeatedly.
    case unavailable(reason: String)
}

/// Presentation state for one Browser Mirror tab.
///
/// This is a pure state container: it owns no process and makes no network
/// or subprocess calls itself, so its transitions are directly testable by
/// feeding it decoded frames/failures, independent of the poller that
/// produces them (`BrowserMirrorPoller`).
@MainActor
final class BrowserMirrorTab: ObservableObject, Identifiable {
    /// Consecutive poll failures before the tab gives up and reports
    /// `.unavailable` instead of retrying forever at full speed.
    static let maxConsecutiveFailuresBeforeUnavailable = 3

    let id: String
    let ownerSessionID: String
    let taskSpaceName: String
    let name: String

    @Published private(set) var state: BrowserMirrorState = .connecting
    @Published private(set) var image: NSImage?
    @Published private(set) var pageURL: String?
    @Published private(set) var pageTitle: String?
    @Published private(set) var lastActivityAt: Date

    private(set) var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?

    init(
        id: String = UUID().uuidString.lowercased(),
        ownerSessionID: String,
        taskSpaceName: String,
        name: String? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.ownerSessionID = ownerSessionID
        self.taskSpaceName = taskSpaceName
        self.name = name ?? taskSpaceName
        self.lastActivityAt = now
    }

    /// The poller task driving this tab. Cancelled and replaced by whoever
    /// (re)starts polling; always cancelled on `cancelPolling()`.
    func attachPoller(_ task: Task<Void, Never>) {
        pollTask?.cancel()
        pollTask = task
    }

    func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// A fresh `useOrCreateTaskSpace`/`takeOverTaskSpace` signal was observed
    /// for this tab's key. Bumps activity and, if the tab had already
    /// wound down, brings it back to `.connecting` so polling resumes.
    func markOpened(now: Date = Date()) {
        lastActivityAt = now
        switch state {
        case .closed, .finished, .unavailable:
            consecutiveFailures = 0
            state = .connecting
        case .connecting, .live:
            break
        }
    }

    func markClosed(keepFrame: Bool, now: Date = Date()) {
        lastActivityAt = now
        cancelPolling()
        state = keepFrame ? .finished : .closed
    }

    func applyFrame(
        image: NSImage,
        url: String?,
        title: String?,
        now: Date = Date()
    ) {
        self.image = image
        pageURL = url
        pageTitle = title
        consecutiveFailures = 0
        lastActivityAt = now
        if state == .connecting {
            state = .live
        }
    }

    func applyFailure(
        reason: String,
        maxConsecutiveFailures: Int = BrowserMirrorTab
            .maxConsecutiveFailuresBeforeUnavailable
    ) {
        guard state == .connecting || state == .live else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            state = .unavailable(reason: reason)
        }
    }
}
