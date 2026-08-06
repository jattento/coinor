import Foundation

public struct SyntheticPane: Codable, Equatable {
    public let childSessionID: String
    public let immediateParentSessionID: String
    public let rootSessionID: String
    public let cwd: String
    public let startedAt: String
    public let startSequence: UInt64
}

public struct HookLifecycleSnapshot: Codable, Equatable {
    public let observedEvents: [GrokHookEvent]
    public let observedEventNames: [GrokHookEventName]
    public let activeRootSessionIDs: [String]
    public let panes: [SyntheticPane]
    public let pendingChildSessionIDs: [String]
    public let terminalSessionIDs: [String]
}

public enum HookLifecycleChange: Equatable {
    case rootObserved(String)
    case paneOpened(String)
    case panesClosed([String])
    case buffered(String)
    case ignored
}

public struct HookLifecycleState {
    private struct PendingStart {
        let event: GrokHookEvent
        let sequence: UInt64
    }

    private var activatedRootSessionIDs: Set<String>
    private var rootSessionBySessionID: [String: String]
    private var panesByChildSessionID: [String: SyntheticPane]
    private var pendingStartsByChildSessionID: [String: PendingStart]
    private var terminalSessionIDs: Set<String>
    private var ignoredSessionIDs: Set<String>
    private var nextSequence: UInt64

    public private(set) var observedEventNames: [GrokHookEventName]
    public private(set) var observedEvents: [GrokHookEvent]

    public init(activatedRootSessionIDs: Set<String> = []) {
        self.activatedRootSessionIDs = activatedRootSessionIDs
        self.rootSessionBySessionID = Dictionary(
            uniqueKeysWithValues: activatedRootSessionIDs.map { ($0, $0) }
        )
        self.panesByChildSessionID = [:]
        self.pendingStartsByChildSessionID = [:]
        self.terminalSessionIDs = []
        self.ignoredSessionIDs = []
        self.nextSequence = 0
        self.observedEventNames = []
        self.observedEvents = []
    }

    public var orderedPanes: [SyntheticPane] {
        panesByChildSessionID.values.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.startSequence < $1.startSequence
        }
    }

    public var pendingChildSessionIDs: Set<String> {
        Set(pendingStartsByChildSessionID.keys)
    }

    public func rootSessionID(for sessionID: String) -> String? {
        rootSessionBySessionID[sessionID]
    }

    public mutating func activateRoot(sessionID: String) {
        guard !terminalSessionIDs.contains(sessionID) else {
            return
        }
        ignoredSessionIDs.remove(sessionID)
        activatedRootSessionIDs.insert(sessionID)
        rootSessionBySessionID[sessionID] = sessionID
        resolvePendingStarts()
    }

    @discardableResult
    public mutating func apply(jsonData: Data) throws -> HookLifecycleChange {
        try apply(GrokHookEvent.decode(jsonData))
    }

    @discardableResult
    public mutating func apply(_ event: GrokHookEvent) -> HookLifecycleChange {
        observedEvents.append(event)
        observedEventNames.append(event.hookEventName)

        switch event.hookEventName {
        case .sessionStart:
            guard activatedRootSessionIDs.contains(event.sessionId),
                  !terminalSessionIDs.contains(event.sessionId)
            else {
                if rootSessionBySessionID[event.sessionId] == nil {
                    ignoreSubtree(rootedAt: event.sessionId)
                }
                return .ignored
            }
            rootSessionBySessionID[event.sessionId] = event.sessionId
            resolvePendingStarts()
            return .rootObserved(event.sessionId)

        case .subagentStart:
            return applySubagentStart(event)

        case .subagentStop:
            guard event.phase?.lowercased() != "observe",
                  let childSessionID = event.subagentId else {
                return .ignored
            }
            let closed = terminateSubtree(
                rootedAt: childSessionID,
                markTerminal: true
            )
            return closed.isEmpty ? .ignored : .panesClosed(closed)

        case .sessionEnd:
            if activatedRootSessionIDs.contains(event.sessionId) {
                let closed = rootProcessExited(sessionID: event.sessionId)
                return closed.isEmpty ? .ignored : .panesClosed(closed)
            }

            guard rootSessionBySessionID[event.sessionId] != nil else {
                return .ignored
            }
            let closed = terminateSubtree(
                rootedAt: event.sessionId,
                markTerminal: true
            )
            return closed.isEmpty ? .ignored : .panesClosed(closed)
        }
    }

    @discardableResult
    public mutating func rootProcessExited(sessionID: String) -> [String] {
        guard activatedRootSessionIDs.contains(sessionID) else {
            return []
        }

        let closed = terminateSubtree(
            rootedAt: sessionID,
            markTerminal: true
        )
        activatedRootSessionIDs.remove(sessionID)
        rootSessionBySessionID.removeValue(forKey: sessionID)
        terminalSessionIDs.insert(sessionID)
        return closed
    }

    @discardableResult
    public mutating func applyPersistedRecord(
        sessionID: String,
        jsonLine: Data
    ) -> [String] {
        guard PersistedSessionTermination.detect(in: jsonLine) != nil,
              rootSessionBySessionID[sessionID] != sessionID
        else {
            return []
        }

        return terminateSubtree(
            rootedAt: sessionID,
            markTerminal: true
        )
    }

    public func snapshot() -> HookLifecycleSnapshot {
        HookLifecycleSnapshot(
            observedEvents: observedEvents,
            observedEventNames: observedEventNames,
            activeRootSessionIDs: activatedRootSessionIDs.sorted(),
            panes: orderedPanes,
            pendingChildSessionIDs: pendingStartsByChildSessionID.keys.sorted(),
            terminalSessionIDs: terminalSessionIDs.sorted()
        )
    }

    private mutating func applySubagentStart(
        _ event: GrokHookEvent
    ) -> HookLifecycleChange {
        guard let childSessionID = event.subagentId,
              childSessionID != event.sessionId,
              !terminalSessionIDs.contains(childSessionID)
        else {
            return .ignored
        }

        if panesByChildSessionID[childSessionID] != nil {
            return .ignored
        }

        if terminalSessionIDs.contains(event.sessionId) {
            terminalSessionIDs.insert(childSessionID)
            return .ignored
        }

        if ignoredSessionIDs.contains(event.sessionId) {
            ignoreSubtree(rootedAt: childSessionID)
            return .ignored
        }

        nextSequence += 1
        let pending = PendingStart(event: event, sequence: nextSequence)

        guard openPaneIfPossible(pending) else {
            if pendingStartsByChildSessionID[childSessionID] == nil {
                pendingStartsByChildSessionID[childSessionID] = pending
            }
            return .buffered(childSessionID)
        }

        resolvePendingStarts()
        return .paneOpened(childSessionID)
    }

    private mutating func openPaneIfPossible(_ pending: PendingStart) -> Bool {
        let event = pending.event
        guard let childSessionID = event.subagentId,
              let rootSessionID = rootSessionBySessionID[event.sessionId],
              activatedRootSessionIDs.contains(rootSessionID),
              !terminalSessionIDs.contains(event.sessionId),
              !terminalSessionIDs.contains(childSessionID)
        else {
            return false
        }

        panesByChildSessionID[childSessionID] = SyntheticPane(
            childSessionID: childSessionID,
            immediateParentSessionID: event.sessionId,
            rootSessionID: rootSessionID,
            cwd: event.cwd,
            startedAt: event.timestamp,
            startSequence: pending.sequence
        )
        rootSessionBySessionID[childSessionID] = rootSessionID
        pendingStartsByChildSessionID.removeValue(forKey: childSessionID)
        return true
    }

    private mutating func resolvePendingStarts() {
        var madeProgress = true

        while madeProgress {
            madeProgress = false
            let pendingStarts = pendingStartsByChildSessionID.values.sorted {
                $0.sequence < $1.sequence
            }

            for pending in pendingStarts where openPaneIfPossible(pending) {
                madeProgress = true
            }
        }
    }

    private mutating func terminateSubtree(
        rootedAt sessionID: String,
        markTerminal: Bool
    ) -> [String] {
        var queue = [sessionID]
        var visited: Set<String> = []
        var sessionsToClose: [String] = []

        while let current = queue.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }

            let activeChildren = panesByChildSessionID.values
                .filter { $0.immediateParentSessionID == current }
                .map(\.childSessionID)
            let pendingChildren = pendingStartsByChildSessionID.values
                .filter { $0.event.sessionId == current }
                .compactMap(\.event.subagentId)
            queue.append(contentsOf: activeChildren)
            queue.append(contentsOf: pendingChildren)

            if panesByChildSessionID[current] != nil {
                sessionsToClose.append(current)
            }
        }

        for current in visited {
            panesByChildSessionID.removeValue(forKey: current)
            pendingStartsByChildSessionID.removeValue(forKey: current)
            if rootSessionBySessionID[current] != current {
                rootSessionBySessionID.removeValue(forKey: current)
            }
            if markTerminal {
                terminalSessionIDs.insert(current)
            }
        }

        return sessionsToClose.sorted()
    }

    private mutating func ignoreSubtree(rootedAt sessionID: String) {
        var queue = [sessionID]
        var visited: Set<String> = []

        while let current = queue.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }

            let pendingChildren = pendingStartsByChildSessionID.values
                .filter { $0.event.sessionId == current }
                .compactMap(\.event.subagentId)
            queue.append(contentsOf: pendingChildren)
        }

        for current in visited {
            pendingStartsByChildSessionID.removeValue(forKey: current)
            ignoredSessionIDs.insert(current)
        }
    }
}
