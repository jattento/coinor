import Foundation

/// Why one conversation is sitting in the Activity Stack queue.
///
/// Ranked by how much it blocks the user: a question blocks a turn from
/// continuing at all, a failure is a question in disguise ("what now?"), and
/// a finished run only wants to be seen.
enum ActivityQueueReason: Int, Comparable, Equatable, Sendable {
    case needsInput = 0
    case failed = 1
    case finished = 2

    static func < (lhs: ActivityQueueReason, rhs: ActivityQueueReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .needsInput: "Needs input"
        case .failed: "Failed"
        case .finished: "Finished"
        }
    }
}

/// One conversation as the Activity Stack engine needs to see it, independent
/// of `AppCoordinator` so the ordering and suppression rules stay unit
/// testable without a live control connection.
struct ActivityStackCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let activity: RuntimeActivity
    let since: Date?

    init(
        id: String,
        title: String,
        project: String,
        activity: RuntimeActivity,
        since: Date?
    ) {
        self.id = id
        self.title = title
        self.project = project
        self.activity = activity
        self.since = since
    }
}

/// One row in the visible queue.
struct ActivityStackItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let reason: ActivityQueueReason
    let since: Date?
}

/// Why a conversation is not in the queue right now even though it would
/// otherwise qualify.
enum ActivityStackAwayReason: Equatable, Sendable {
    case muted
    case snoozed(until: Date)
}

/// One row in the "away" list: conversations pulled out of the queue by hand.
struct ActivityStackAwayItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let reason: ActivityStackAwayReason
}

/// The instance of attention a suppression was recorded against.
///
/// A suppression only holds while the conversation is still the exact same
/// attention instance: if it fails again, asks a new question, or finishes a
/// new run, the fingerprint changes and the suppression lifts on its own. A
/// broken agent does not stay silent forever just because it was muted once.
struct ActivityStackFingerprint: Equatable, Sendable {
    let reason: ActivityQueueReason
    let since: Date?
}

/// What the focus pane's header shows for the currently focused conversation.
///
/// `reason` is `nil` when the conversation is no longer a queue member (it
/// went back to `working`, or otherwise stopped blocking) but is still being
/// shown because nothing else is waiting — see
/// `ActivityStackModel.reconcileFocus`. That distinction is what lets the
/// header show a neutral "nothing else waiting" state instead of a stale
/// colored badge, and lets the action bar drop actions that only make sense
/// for an actual queue member.
struct ActivityStackFocusDisplay: Equatable, Sendable {
    let title: String
    let project: String
    let reason: ActivityQueueReason?
    let since: Date?
}

/// One conversation Grok reports as actively working, shown in the sidebar's
/// "N agents working" footer by name instead of only a count.
struct ActivityStackWorkingItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let since: Date?
}

/// A conversation removed from the queue by the user, and why.
enum ActivityStackSuppression: Equatable, Sendable {
    /// Acknowledged once ("D"). Reappears only on a new fingerprint.
    case dismissed(ActivityStackFingerprint)
    /// Removed until manually restored, or a new fingerprint appears.
    case muted(ActivityStackFingerprint)
    /// Removed until the timer expires, or a new fingerprint appears.
    case snoozed(until: Date, fingerprint: ActivityStackFingerprint)
}

/// The result of one Activity Stack recomputation: the read model plus the
/// carried-forward tracking state the next recomputation needs.
struct ActivityStackEngineResult: Equatable, Sendable {
    var queue: [ActivityStackItem]
    var away: [ActivityStackAwayItem]
    var working: [ActivityStackWorkingItem]
    var previousActivity: [String: RuntimeActivity]
    var pendingReason: [String: ActivityQueueReason]
    var suppressions: [String: ActivityStackSuppression]
}

/// Pure queue-building logic for the Activity Stack, kept free of
/// `AppCoordinator` so ordering and suppression rules are directly testable.
enum ActivityStackEngine {
    /// Recomputes the queue from scratch given the current candidates and the
    /// tracking state carried from the previous recomputation.
    ///
    /// Coinor never infers state by parsing terminal output; every reason a
    /// conversation appears here comes from Grok's own reported activity, via
    /// the same `ConversationAttention.transition` edge detection the sidebar
    /// uses. Unlike the sidebar, this engine evaluates every known,
    /// non-dormant, non-archived conversation, not only the ones already
    /// loaded into a runtime this run, so a conversation already sitting at
    /// `needsInput` the first time this model observes it is raised
    /// immediately rather than waiting for a fresh transition.
    static func recompute(
        candidates: [ActivityStackCandidate],
        previousActivity: [String: RuntimeActivity],
        pendingReason: [String: ActivityQueueReason],
        suppressions: [String: ActivityStackSuppression],
        pushedOrder: [String: Int],
        now: Date
    ) -> ActivityStackEngineResult {
        var nextPreviousActivity = previousActivity
        var nextPendingReason = pendingReason
        var nextSuppressions = suppressions
        var queueItems: [ActivityStackItem] = []
        var awayItems: [ActivityStackAwayItem] = []
        var workingItems: [ActivityStackWorkingItem] = []
        var seenIDs: Set<String> = []

        for candidate in candidates {
            seenIDs.insert(candidate.id)
            if candidate.activity == .working {
                workingItems.append(
                    ActivityStackWorkingItem(
                        id: candidate.id,
                        title: candidate.title,
                        project: candidate.project,
                        since: candidate.since
                    )
                )
            }

            let transition = ConversationAttention.transition(
                from: nextPreviousActivity[candidate.id],
                to: candidate.activity
            )
            nextPreviousActivity[candidate.id] = candidate.activity
            switch transition {
            case .raised(let reason):
                nextPendingReason[candidate.id] =
                    reason == .question ? .needsInput : .finished
            case .settled:
                nextPendingReason.removeValue(forKey: candidate.id)
            case .unchanged:
                break
            }

            // `.dormant` and `.completed` ("session closed" — the underlying
            // Grok process ended) never need the user, matching
            // `ConversationIndicator.propagatesToProject`, which excludes
            // both from attention aggregation everywhere else in Coinor.
            // `.completed` must not be read as a live "finished" reason: a
            // session that reports `completed` can sit there indefinitely
            // even while the user is actively chatting again through a new
            // resumed process, which previously kept an answered
            // conversation stuck in the queue forever.
            guard candidate.activity != .dormant,
                  candidate.activity != .completed else {
                continue
            }

            // `.failed` is a live state Grok reports directly rather than an
            // edge, so it is read straight off current activity instead of
            // the transition-tracked reason.
            let reason: ActivityQueueReason?
            if candidate.activity == .failed {
                reason = .failed
            } else {
                reason = nextPendingReason[candidate.id]
            }
            guard let reason else { continue }

            let fingerprint = ActivityStackFingerprint(
                reason: reason,
                since: candidate.since
            )

            if let suppression = nextSuppressions[candidate.id] {
                switch suppression {
                case .dismissed(let fp) where fp == fingerprint:
                    continue
                case .muted(let fp) where fp == fingerprint:
                    awayItems.append(
                        ActivityStackAwayItem(
                            id: candidate.id,
                            title: candidate.title,
                            project: candidate.project,
                            reason: .muted
                        )
                    )
                    continue
                case .snoozed(let until, let fp)
                    where fp == fingerprint && until > now:
                    awayItems.append(
                        ActivityStackAwayItem(
                            id: candidate.id,
                            title: candidate.title,
                            project: candidate.project,
                            reason: .snoozed(until: until)
                        )
                    )
                    continue
                default:
                    // The fingerprint moved on: a new question, a new
                    // failure, or a new finish. The suppression no longer
                    // applies.
                    nextSuppressions.removeValue(forKey: candidate.id)
                }
            }

            queueItems.append(
                ActivityStackItem(
                    id: candidate.id,
                    title: candidate.title,
                    project: candidate.project,
                    reason: reason,
                    since: candidate.since
                )
            )
        }

        nextPreviousActivity = nextPreviousActivity.filter { seenIDs.contains($0.key) }
        nextPendingReason = nextPendingReason.filter { seenIDs.contains($0.key) }
        nextSuppressions = nextSuppressions.filter { seenIDs.contains($0.key) }

        return ActivityStackEngineResult(
            queue: order(queueItems, pushedOrder: pushedOrder),
            away: awayItems.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            },
            working: workingItems.sorted {
                let lhs = $0.since ?? .distantPast
                let rhs = $1.since ?? .distantPast
                return lhs != rhs
                    ? lhs < rhs
                    : $0.title.localizedCaseInsensitiveCompare($1.title)
                        == .orderedAscending
            },
            previousActivity: nextPreviousActivity,
            pendingReason: nextPendingReason,
            suppressions: nextSuppressions
        )
    }

    /// Orders the queue: what blocks the user first (needs input), then
    /// failures, then finished runs; within a group, the longest-waiting item
    /// leads. An item pushed to the end of the current pass sorts after every
    /// other item regardless of reason, in the order it was pushed.
    static func order(
        _ items: [ActivityStackItem],
        pushedOrder: [String: Int]
    ) -> [ActivityStackItem] {
        items.sorted { lhs, rhs in
            let lhsPush = pushedOrder[lhs.id]
            let rhsPush = pushedOrder[rhs.id]
            switch (lhsPush, rhsPush) {
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case let (.some(left), .some(right)):
                return left < right
            case (nil, nil):
                if lhs.reason != rhs.reason { return lhs.reason < rhs.reason }
                let lhsSince = lhs.since ?? .distantPast
                let rhsSince = rhs.since ?? .distantPast
                if lhsSince != rhsSince { return lhsSince < rhsSince }
                return lhs.id < rhs.id
            }
        }
    }
}
