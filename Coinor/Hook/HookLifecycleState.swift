import Foundation

struct HookPaneRecord: Equatable, Sendable {
    let childSessionID: String
    let immediateParentSessionID: String
    let rootSessionID: String
    let workingDirectory: String
    let startedAt: String
    let startSequence: UInt64

    var startOrder: SubagentStartOrder {
        SubagentStartOrder(
            timestamp: startedAt,
            sequence: startSequence,
            sessionID: childSessionID
        )
    }
}

struct SubagentStartOrder: Comparable, Equatable, Sendable {
    let timestamp: TimeInterval?
    let sequence: UInt64
    let sessionID: String

    init(timestamp: String, sequence: UInt64, sessionID: String) {
        self.timestamp = Self.parseTimestamp(timestamp)
        self.sequence = sequence
        self.sessionID = sessionID
    }

    static func < (lhs: SubagentStartOrder, rhs: SubagentStartOrder) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.sequence != rhs.sequence {
                return lhs.sequence < rhs.sequence
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        if let numeric = Double(value) {
            return numeric > 100_000_000_000 ? numeric / 1_000 : numeric
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date.timeIntervalSince1970
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)?.timeIntervalSince1970
    }
}

enum HookLifecycleAction: Equatable, Sendable {
    case rootObserved(String)
    case panesOpened([HookPaneRecord])
    case panesClosed([String])
    case panesChanged(opened: [HookPaneRecord], closed: [String])
    case buffered(String)
    case ignored
}

struct HookLifecycleState: Sendable {
    private struct PendingStart: Sendable {
        let parentSessionID: String
        let childSessionID: String
        let workingDirectory: String
        let timestamp: String
        let sequence: UInt64
    }

    private var activatedRoots: Set<String> = []
    private var rootBySession: [String: String] = [:]
    private var panesByChild: [String: HookPaneRecord] = [:]
    private var pendingByChild: [String: PendingStart] = [:]
    private var terminalSessions: Set<String> = []
    private var ignoredSessions: Set<String> = []
    private var nextSequence: UInt64 = 0

    var orderedPanes: [HookPaneRecord] {
        panesByChild.values.sorted { $0.startOrder < $1.startOrder }
    }

    var pendingChildSessionIDs: Set<String> {
        Set(pendingByChild.keys)
    }

    func rootSessionID(for sessionID: String) -> String? {
        rootBySession[sessionID]
    }

    @discardableResult
    mutating func activateRoot(sessionID: String) -> [HookPaneRecord] {
        guard !terminalSessions.contains(sessionID) else { return [] }
        ignoredSessions.remove(sessionID)
        activatedRoots.insert(sessionID)
        rootBySession[sessionID] = sessionID
        return resolvePendingStarts()
    }

    mutating func apply(_ event: GrokHookEvent) -> HookLifecycleAction {
        switch event.hookEventName {
        case .sessionStart:
            guard activatedRoots.contains(event.sessionId),
                  !terminalSessions.contains(event.sessionId) else {
                if rootBySession[event.sessionId] == nil {
                    ignoreSubtree(rootedAt: event.sessionId)
                }
                return .ignored
            }
            rootBySession[event.sessionId] = event.sessionId
            let opened = resolvePendingStarts()
            if !opened.isEmpty {
                return .panesOpened(opened)
            }
            return .rootObserved(event.sessionId)

        case .subagentStart:
            guard let childID = event.subagentId else { return .ignored }
            return applyStart(
                parentSessionID: event.sessionId,
                childSessionID: childID,
                workingDirectory: event.cwd,
                timestamp: event.timestamp
            )

        case .subagentStop:
            guard event.phase?.lowercased() != "observe",
                  let childID = event.subagentId else {
                return .ignored
            }
            let transition = terminateSessionPreservingDescendants(
                sessionID: childID,
                fallbackParentSessionID: event.sessionId
            )
            return action(for: transition)

        case .sessionEnd:
            if activatedRoots.contains(event.sessionId) {
                let closed = rootProcessExited(sessionID: event.sessionId)
                return closed.isEmpty ? .ignored : .panesClosed(closed)
            }
            guard rootBySession[event.sessionId] != nil else { return .ignored }
            let transition = terminateSessionPreservingDescendants(
                sessionID: event.sessionId,
                fallbackParentSessionID: nil
            )
            return action(for: transition)
        }
    }

    mutating func apply(
        _ observation: GrokSubagentLifecycleObservation,
        workingDirectory: String
    ) -> HookLifecycleAction {
        switch observation.kind {
        case .started, .progressed:
            return applyStart(
                parentSessionID: observation.parentSessionID,
                childSessionID: observation.childSessionID,
                workingDirectory: workingDirectory,
                timestamp: observation.timestamp ?? ""
            )
        case .finished:
            let transition = terminateSessionPreservingDescendants(
                sessionID: observation.childSessionID,
                fallbackParentSessionID: observation.parentSessionID
            )
            return action(for: transition)
        }
    }

    mutating func apply(jsonData: Data) throws -> HookLifecycleAction {
        apply(try GrokHookEvent.decode(jsonData))
    }

    mutating func rootProcessExited(sessionID: String) -> [String] {
        guard activatedRoots.contains(sessionID) else { return [] }
        let closed = terminateSubtree(rootedAt: sessionID, markTerminal: true)
        activatedRoots.remove(sessionID)
        rootBySession.removeValue(forKey: sessionID)
        terminalSessions.insert(sessionID)
        return closed
    }

    mutating func deactivateRoot(sessionID: String) -> [String] {
        guard activatedRoots.remove(sessionID) != nil else { return [] }
        let closed = panesByChild.values
            .filter { $0.rootSessionID == sessionID }
            .sorted { $0.startSequence < $1.startSequence }
            .map(\.childSessionID)
        panesByChild = panesByChild.filter {
            $0.value.rootSessionID != sessionID
        }
        pendingByChild = pendingByChild.filter { pending in
            pending.value.parentSessionID != sessionID
                && rootBySession[pending.value.parentSessionID] != sessionID
        }
        rootBySession = rootBySession.filter {
            $0.value != sessionID
        }
        ignoredSessions.remove(sessionID)
        return closed
    }

    mutating func applyPersistedRecord(
        sessionID: String,
        jsonLine: Data
    ) -> HookLifecycleAction {
        guard PersistedSessionTermination.detect(in: jsonLine) != nil,
              rootBySession[sessionID] != sessionID else {
            return .ignored
        }
        return action(
            for: terminateSessionPreservingDescendants(
                sessionID: sessionID,
                fallbackParentSessionID: nil
            )
        )
    }

    private mutating func applyStart(
        parentSessionID: String,
        childSessionID: String,
        workingDirectory: String,
        timestamp: String
    ) -> HookLifecycleAction {
        guard childSessionID != parentSessionID,
              !terminalSessions.contains(childSessionID),
              panesByChild[childSessionID] == nil,
              pendingByChild[childSessionID] == nil else {
            return .ignored
        }

        if terminalSessions.contains(parentSessionID) {
            terminalSessions.insert(childSessionID)
            return .ignored
        }
        if ignoredSessions.contains(parentSessionID) {
            ignoreSubtree(rootedAt: childSessionID)
            return .ignored
        }

        nextSequence += 1
        let pending = PendingStart(
            parentSessionID: parentSessionID,
            childSessionID: childSessionID,
            workingDirectory: workingDirectory,
            timestamp: timestamp,
            sequence: nextSequence
        )
        guard let pane = openPaneIfPossible(pending) else {
            pendingByChild[childSessionID] = pending
            return .buffered(childSessionID)
        }
        return .panesOpened([pane] + resolvePendingStarts())
    }

    private mutating func openPaneIfPossible(
        _ pending: PendingStart
    ) -> HookPaneRecord? {
        guard let rootID = rootBySession[pending.parentSessionID],
              activatedRoots.contains(rootID),
              !terminalSessions.contains(pending.parentSessionID),
              !terminalSessions.contains(pending.childSessionID) else {
            return nil
        }

        let pane = HookPaneRecord(
            childSessionID: pending.childSessionID,
            immediateParentSessionID: pending.parentSessionID,
            rootSessionID: rootID,
            workingDirectory: pending.workingDirectory,
            startedAt: pending.timestamp,
            startSequence: pending.sequence
        )
        panesByChild[pending.childSessionID] = pane
        rootBySession[pending.childSessionID] = rootID
        pendingByChild.removeValue(forKey: pending.childSessionID)
        return pane
    }

    private mutating func resolvePendingStarts() -> [HookPaneRecord] {
        var opened: [HookPaneRecord] = []
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for pending in pendingByChild.values.sorted(by: {
                SubagentStartOrder(
                    timestamp: $0.timestamp,
                    sequence: $0.sequence,
                    sessionID: $0.childSessionID
                ) < SubagentStartOrder(
                    timestamp: $1.timestamp,
                    sequence: $1.sequence,
                    sessionID: $1.childSessionID
                )
            }) {
                if let pane = openPaneIfPossible(pending) {
                    opened.append(pane)
                    madeProgress = true
                }
            }
        }
        return opened
    }

    /// Finish one child without killing children Grok has already re-parented.
    private mutating func terminateSessionPreservingDescendants(
        sessionID: String,
        fallbackParentSessionID: String?
    ) -> (opened: [HookPaneRecord], closed: [String]) {
        let parentSessionID = panesByChild[sessionID]?.immediateParentSessionID
            ?? pendingByChild[sessionID]?.parentSessionID
            ?? fallbackParentSessionID

        if let parentSessionID, parentSessionID != sessionID {
            let childPanes = panesByChild.values.filter {
                $0.immediateParentSessionID == sessionID
            }
            for pane in childPanes {
                panesByChild[pane.childSessionID] = HookPaneRecord(
                    childSessionID: pane.childSessionID,
                    immediateParentSessionID: parentSessionID,
                    rootSessionID: pane.rootSessionID,
                    workingDirectory: pane.workingDirectory,
                    startedAt: pane.startedAt,
                    startSequence: pane.startSequence
                )
            }
            let pendingChildren = pendingByChild.values.filter {
                $0.parentSessionID == sessionID
            }
            for pending in pendingChildren {
                pendingByChild[pending.childSessionID] = PendingStart(
                    parentSessionID: parentSessionID,
                    childSessionID: pending.childSessionID,
                    workingDirectory: pending.workingDirectory,
                    timestamp: pending.timestamp,
                    sequence: pending.sequence
                )
            }
        }

        let existed = panesByChild.removeValue(forKey: sessionID) != nil
        pendingByChild.removeValue(forKey: sessionID)
        rootBySession.removeValue(forKey: sessionID)
        terminalSessions.insert(sessionID)
        let opened = resolvePendingStarts()
        return (opened, existed ? [sessionID] : [])
    }

    private mutating func terminateSubtree(
        rootedAt sessionID: String,
        markTerminal: Bool
    ) -> [String] {
        var sessions = [sessionID]
        var seen: Set<String> = [sessionID]
        var index = 0
        while index < sessions.count {
            let parent = sessions[index]
            let openedChildren = panesByChild.values
                .filter { $0.immediateParentSessionID == parent }
                .map(\.childSessionID)
            let pendingChildren = pendingByChild.values
                .filter { $0.parentSessionID == parent }
                .map(\.childSessionID)
            for child in openedChildren + pendingChildren
            where seen.insert(child).inserted {
                sessions.append(child)
            }
            index += 1
        }

        let paneIDs = sessions.compactMap { panesByChild[$0] }.sorted {
            $0.startSequence < $1.startSequence
        }.map(\.childSessionID)
        for id in sessions {
            panesByChild.removeValue(forKey: id)
            pendingByChild.removeValue(forKey: id)
            rootBySession.removeValue(forKey: id)
            ignoredSessions.remove(id)
            if markTerminal {
                terminalSessions.insert(id)
            }
        }
        return paneIDs
    }

    private func action(
        for transition: (
            opened: [HookPaneRecord],
            closed: [String]
        )
    ) -> HookLifecycleAction {
        switch (transition.opened.isEmpty, transition.closed.isEmpty) {
        case (true, true):
            return .ignored
        case (false, true):
            return .panesOpened(transition.opened)
        case (true, false):
            return .panesClosed(transition.closed)
        case (false, false):
            return .panesChanged(
                opened: transition.opened,
                closed: transition.closed
            )
        }
    }

    private mutating func ignoreSubtree(rootedAt sessionID: String) {
        ignoredSessions.insert(sessionID)
        pendingByChild = pendingByChild.filter {
            $0.value.parentSessionID != sessionID
        }
    }
}
