import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let coinorProjectReorder = UTType(
        exportedAs: "dev.coinor.project-reorder"
    )
    static let coinorConversationReorder = UTType(
        exportedAs: "dev.coinor.conversation-reorder"
    )
}

enum SidebarReorderScope: Equatable, Hashable {
    case projects
    case pinned
    case project(String)

    var contentType: UTType {
        switch self {
        case .projects:
            .coinorProjectReorder
        case .pinned, .project:
            .coinorConversationReorder
        }
    }
}

struct SidebarReorderSession: Equatable {
    let token: UUID
    let scope: SidebarReorderScope
    let draggedID: String
    let originalOrder: [String]
    var previewOrder: [String]
}

@MainActor
final class SidebarReorderModel: ObservableObject {
    @Published private(set) var session: SidebarReorderSession?

    private let monitorsMouseButton: Bool
    private var releaseMonitor: Task<Void, Never>?

    init(monitorsMouseButton: Bool = true) {
        self.monitorsMouseButton = monitorsMouseButton
    }

    var isActive: Bool {
        session != nil
    }

    var activeScope: SidebarReorderScope? {
        session?.scope
    }

    func begin(
        scope: SidebarReorderScope,
        itemID: String,
        currentOrder: [String]
    ) -> NSItemProvider {
        let order = SidebarReorderOrder.reconciled(
            previewOrder: currentOrder,
            currentOrder: currentOrder
        )
        let token = UUID()
        session = SidebarReorderSession(
            token: token,
            scope: scope,
            draggedID: itemID,
            originalOrder: order,
            previewOrder: order
        )
        armReleaseMonitor(token: token)
        return SidebarReorderPayload.provider(
            scope: scope,
            itemID: itemID
        )
    }

    func displayOrder(
        for scope: SidebarReorderScope,
        currentOrder: [String]
    ) -> [String] {
        guard let session, session.scope == scope else {
            return currentOrder
        }
        return SidebarReorderOrder.reconciled(
            previewOrder: session.previewOrder,
            currentOrder: currentOrder
        )
    }

    func isDragging(
        _ itemID: String,
        in scope: SidebarReorderScope
    ) -> Bool {
        session?.scope == scope && session?.draggedID == itemID
    }

    func canHandle(_ scope: SidebarReorderScope) -> Bool {
        session?.scope == scope
    }

    @discardableResult
    func updatePreview(
        scope: SidebarReorderScope,
        targetID: String,
        dropY: CGFloat,
        targetHeight: CGFloat,
        currentOrder: [String]
    ) -> Bool {
        guard var session, session.scope == scope else {
            return false
        }

        let reconciled = SidebarReorderOrder.reconciled(
            previewOrder: session.previewOrder,
            currentOrder: currentOrder
        )
        let reordered = SidebarReorderOrder.reorderedIDs(
            reconciled,
            moving: session.draggedID,
            relativeTo: targetID,
            dropY: dropY,
            targetHeight: targetHeight
        )
        guard reordered != session.previewOrder else {
            return false
        }

        session.previewOrder = reordered
        self.session = session
        return true
    }

    func commit(
        scope: SidebarReorderScope,
        currentOrder: [String]
    ) -> [String]? {
        guard let session, session.scope == scope else {
            return nil
        }
        let order = SidebarReorderOrder.reconciled(
            previewOrder: session.previewOrder,
            currentOrder: currentOrder
        )
        finish()
        return order
    }

    func cancel() {
        finish()
    }

    private func finish() {
        releaseMonitor?.cancel()
        releaseMonitor = nil
        session = nil
    }

    private func armReleaseMonitor(token: UUID) {
        releaseMonitor?.cancel()
        guard monitorsMouseButton else { return }

        // SwiftUI does not report a cancelled drop. Restore the catalog order
        // after the mouse is released if no delegate committed this drag.
        releaseMonitor = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled,
                  NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  self?.session?.token == token else {
                return
            }
            self?.cancel()
        }
    }
}

enum SidebarReorderOrder {
    static func reconciled(
        previewOrder: [String],
        currentOrder: [String]
    ) -> [String] {
        let currentIDs = Set(currentOrder)
        var seen: Set<String> = []
        let surviving = previewOrder.filter {
            currentIDs.contains($0) && seen.insert($0).inserted
        }
        return surviving + currentOrder.filter {
            seen.insert($0).inserted
        }
    }

    static func reorderedIDs(
        _ ids: [String],
        moving sourceID: String,
        relativeTo targetID: String,
        dropY: CGFloat,
        targetHeight: CGFloat
    ) -> [String] {
        guard sourceID != targetID,
              let sourceIndex = ids.firstIndex(of: sourceID),
              ids.contains(targetID) else {
            return ids
        }

        var reordered = ids
        reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(of: targetID) else {
            return ids
        }

        let insertAfter = dropY >= targetHeight / 2
        reordered.insert(
            sourceID,
            at: targetIndex + (insertAfter ? 1 : 0)
        )
        return reordered
    }
}

enum SidebarReorderMetrics {
    static let projectHeaderHeight: CGFloat = 18
    static let conversationHeight: CGFloat = 24
    static let listRowHeight: CGFloat = 40
}

enum SidebarReorderPayload {
    static func provider(
        scope: SidebarReorderScope,
        itemID: String
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = itemID
        provider.registerDataRepresentation(
            forTypeIdentifier: scope.contentType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(itemID.utf8), nil)
            return nil
        }
        return provider
    }
}

struct SidebarReorderDropDelegate: DropDelegate {
    let scope: SidebarReorderScope
    let targetID: String
    let targetHeight: CGFloat
    let forceAfterTarget: Bool
    let model: SidebarReorderModel
    let currentOrder: () -> [String]
    let commit: ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [scope.contentType])
            && model.canHandle(scope)
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        updatePreview(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let order = model.commit(
                  scope: scope,
                  currentOrder: currentOrder()
              ) else {
            return false
        }
        commit(order)
        return true
    }

    private func updatePreview(_ info: DropInfo) {
        guard validateDrop(info: info) else { return }
        let dropY = forceAfterTarget
            ? targetHeight
            : info.location.y
        _ = withAnimation(.easeInOut(duration: 0.16)) {
            model.updatePreview(
                scope: scope,
                targetID: targetID,
                dropY: dropY,
                targetHeight: targetHeight,
                currentOrder: currentOrder()
            )
        }
    }
}

struct SidebarReorderBackgroundDropDelegate: DropDelegate {
    let model: SidebarReorderModel
    let currentOrder: (SidebarReorderScope) -> [String]
    let commit: (SidebarReorderScope, [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let scope = model.activeScope else { return false }
        return info.hasItemsConforming(to: [scope.contentType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info)
            ? DropProposal(operation: .move)
            : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let scope = model.activeScope,
              let order = model.commit(
                  scope: scope,
                  currentOrder: currentOrder(scope)
              ) else {
            return false
        }
        commit(scope, order)
        return true
    }
}
