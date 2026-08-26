import Foundation

/// Drives the Activity Stack: a queue of conversations that need the user,
/// built from `AppCoordinator`'s existing roster and catalog, so it never
/// duplicates or races Coinor's own activity tracking.
///
/// The panel is opened only by an explicit user action (toolbar button or
/// shortcut); it never raises itself. While it is open, the focused
/// conversation is always the app's real selected conversation, so the same
/// Ghostty surface the sidebar would show renders inside the panel and
/// answering it is exactly the same terminal input the user already knows.
///
/// This model does not subscribe to `AppCoordinator` itself: the owning view
/// forwards `coordinator.objectWillChange` into `recompute()` so every update
/// stays on the view's own MainActor turn, and a periodic tick covers the
/// wait-time text and snooze expirations while nothing else changes.
@MainActor
final class ActivityStackModel: ObservableObject {
    let coordinator: AppCoordinator

    @Published private(set) var isPresented = false
    @Published private(set) var queue: [ActivityStackItem] = []
    @Published private(set) var away: [ActivityStackAwayItem] = []
    @Published private(set) var working: [ActivityStackWorkingItem] = []
    var workingCount: Int { working.count }
    @Published private(set) var focusedID: String?

    /// Whether `focusedID` was explicitly chosen while not a queue member
    /// (a working agent the user tapped to check in on). See `selectFocus`.
    private var isWatchingNonQueueItem = false

    private var previousActivity: [String: RuntimeActivity] = [:]
    private var pendingReason: [String: ActivityQueueReason] = [:]
    private var suppressions: [String: ActivityStackSuppression] = [:]
    private var pushedOrder: [String: Int] = [:]
    private var pushSequence = 0

    private var tickTask: Task<Void, Never>?

    /// How often the focused wait time re-renders, a snooze timer is
    /// re-checked, and (as a backstop) the queue is recomputed while the
    /// panel is open. Only runs while presented, and kept short: it is the
    /// safety net that catches the panel up if it ever misses a live update,
    /// so a stuck-looking queue self-heals within a few seconds instead of
    /// needing the next unrelated coordinator change to nudge it.
    private static let tickInterval: Duration = .seconds(5)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        recompute()
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Presentation

    func present() {
        isPresented = true
        recompute()
        startTicking()
    }

    func close() {
        isPresented = false
        // Dropping focus here (rather than leaving it pinned to whatever was
        // last shown) is what makes every `present()` deterministic: the
        // very next open always lands on the true current head of the
        // queue instead of silently resuming a stale selection that may no
        // longer be first once new items arrived while the panel was shut.
        focusedID = nil
        isWatchingNonQueueItem = false
        stopTicking()
    }

    @discardableResult
    func togglePresented() -> Bool {
        if isPresented {
            close()
        } else {
            present()
        }
        return true
    }

    // MARK: - Focus

    var focusedItem: ActivityStackItem? {
        guard let focusedID else { return nil }
        return queue.first { $0.id == focusedID }
    }

    /// The header display for whatever is focused, whether or not it is
    /// still a queue member. Falls back to `AppCoordinator`'s own catalog so
    /// a conversation kept on screen only because nothing else is waiting
    /// still shows a correct title and project.
    var focusedDisplay: ActivityStackFocusDisplay? {
        guard let focusedID else { return nil }
        if let item = focusedItem {
            return ActivityStackFocusDisplay(
                title: item.title,
                project: item.project,
                reason: item.reason,
                since: item.since
            )
        }
        guard let summary = coordinator.summaries.first(where: {
            $0.id == focusedID
        }) else {
            return nil
        }
        return ActivityStackFocusDisplay(
            title: summary.title,
            project: coordinator.projectDisplayName(summary.projectID),
            reason: nil,
            since: nil
        )
    }

    /// Explicitly stops watching a conversation that is no longer a queue
    /// member (the "Close" action shown once nothing else is waiting).
    func closeFocused() {
        focusedID = nil
        isWatchingNonQueueItem = false
        reconcileFocus()
    }

    /// Focuses a conversation directly. Used for an explicit rail tap or a
    /// tap on a "working" row: browsing ahead is always allowed, independent
    /// of automatic advancing.
    ///
    /// Picking a conversation that is not currently a queue member (a
    /// working agent the user wants to check in on) marks it so
    /// `reconcileFocus` leaves it alone even while other items are waiting —
    /// otherwise the periodic tick would silently drag the panel back to the
    /// queue's head a few seconds after the user chose to watch something
    /// else. A queue member never needs this: it already keeps focus on its
    /// own via `reconcileFocus`'s membership check.
    func selectFocus(_ id: String) {
        focusedID = id
        isWatchingNonQueueItem = !queue.contains(where: { $0.id == id })
        coordinator.selectConversation(id)
    }

    // MARK: - Actions on the focused item

    /// "Done, remove" while the focused item is still a queue member;
    /// "Close" once it is only being watched because nothing else is
    /// waiting. Both are the same physical action (⌘D / the action-bar
    /// button), so this is the one entry point both call.
    func dismissOrCloseFocused() {
        guard let focusedID else { return }
        if queue.contains(where: { $0.id == focusedID }) {
            dismiss(focusedID)
        } else {
            closeFocused()
        }
    }

    func pushFocusedToEnd() {
        guard let focusedID else { return }
        pushToEnd(focusedID)
    }

    func muteFocused() {
        guard let focusedID else { return }
        mute(focusedID)
    }

    func snoozeFocused(minutes: Int) {
        guard let focusedID else { return }
        snooze(focusedID, minutes: minutes)
    }

    // MARK: - Actions on an arbitrary item

    /// "Listo, sacar": acknowledges the current attention instance. It
    /// reappears the next time this conversation raises a new one.
    func dismiss(_ id: String) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        suppressions[id] = .dismissed(fingerprint(for: item))
        pushedOrder.removeValue(forKey: id)
        recompute()
    }

    /// "Al final": keeps the item in this pass but moves it behind every
    /// other current item.
    func pushToEnd(_ id: String) {
        pushSequence += 1
        pushedOrder[id] = pushSequence
        recompute()
    }

    /// Removes the item from this pass for a fixed duration; it returns on
    /// its own once the timer expires, or sooner if it raises a new instance
    /// of attention.
    func snooze(_ id: String, minutes: Int) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        suppressions[id] = .snoozed(
            until: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            fingerprint: fingerprint(for: item)
        )
        pushedOrder.removeValue(forKey: id)
        recompute()
    }

    /// Removes the item until the user explicitly restores it, or it raises a
    /// new instance of attention.
    func mute(_ id: String) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        suppressions[id] = .muted(fingerprint(for: item))
        pushedOrder.removeValue(forKey: id)
        recompute()
    }

    /// Returns a muted or snoozed item to the queue immediately.
    func restore(_ id: String) {
        suppressions.removeValue(forKey: id)
        recompute()
    }

    private func fingerprint(for item: ActivityStackItem) -> ActivityStackFingerprint {
        ActivityStackFingerprint(reason: item.reason, since: item.since)
    }

    // MARK: - Recompute

    func recompute() {
        let candidates = coordinator.summaries.compactMap {
            summary -> ActivityStackCandidate? in
            guard !coordinator.metadata.isSessionArchived(summary.id),
                  !coordinator.metadata.isProjectArchived(summary.projectID)
            else {
                return nil
            }
            return ActivityStackCandidate(
                id: summary.id,
                title: summary.title,
                project: coordinator.projectDisplayName(summary.projectID),
                activity: coordinator.activity(for: summary.id),
                since: coordinator.roster[summary.id]?.lastChange
            )
        }

        let result = ActivityStackEngine.recompute(
            candidates: candidates,
            previousActivity: previousActivity,
            pendingReason: pendingReason,
            suppressions: suppressions,
            pushedOrder: pushedOrder,
            now: Date()
        )

        previousActivity = result.previousActivity
        pendingReason = result.pendingReason
        suppressions = result.suppressions
        queue = result.queue
        away = result.away
        working = result.working

        // "Send to end" only holds "for this pass", per its own docstring:
        // once an item actually leaves the queue (answered, muted, snoozed,
        // dismissed…) its push position is stale. Dropping it here means a
        // conversation that later raises a brand-new, unrelated instance
        // reappears at its natural priority instead of staying pinned to
        // the back of the line forever because of something pushed away
        // long ago.
        let queueIDs = Set(queue.map(\.id))
        pushedOrder = pushedOrder.filter { queueIDs.contains($0.key) }

        if isPresented {
            reconcileFocus()
        }
    }

    /// Advances the focused item only when something else actually needs the
    /// user.
    ///
    /// A conversation that goes quiet (answered, or otherwise stopped
    /// blocking) never gets yanked out from under the user just because it
    /// left the queue: a run of clarifying questions would otherwise bounce
    /// the panel to an empty state and back on every answer. It only moves
    /// on once another conversation is actually waiting, or the user acts
    /// explicitly (a rail tap, a working-row tap, or "Close" once nothing
    /// else is left). Runs on every recompute — including the presented
    /// tick — so a queue that changed while nothing else happened to notify
    /// `AppCoordinator` still self-corrects within one tick instead of
    /// waiting indefinitely for an unrelated update.
    private func reconcileFocus() {
        if let focusedID {
            if queue.contains(where: { $0.id == focusedID }) {
                return
            }
            if isWatchingNonQueueItem {
                return
            }
        }
        guard let next = queue.first else { return }
        selectFocus(next.id)
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ActivityStackModel.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.recompute()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
