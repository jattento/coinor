import Foundation
import Testing

@testable import Coinor

private final class StubAgenticFinder: AgenticConversationFinding, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse {
        AgenticFinderResponse(message: "ok", matches: [])
    }

    func cancel() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }
}

@Test
@MainActor
func agenticSearchPanelStartsDismissed() {
    let panel = AgenticSearchPanelState()

    #expect(!panel.isPresented)
    #expect(panel.model == nil)
    #expect(!panel.acceptsInput)
    #expect(panel.unavailableMessage == nil)
}

@Test
@MainActor
func agenticSearchPanelDismissClosesThePanelAndStopsTheFinder() {
    let finder = StubAgenticFinder()
    let model = AgenticConversationFinderModel(finder: finder)
    var panel = AgenticSearchPanelState()

    panel.present(model)
    model.query = "yesterday's remote host conversation"

    #expect(panel.isPresented)
    #expect(panel.acceptsInput)
    #expect(panel.unavailableMessage == nil)

    panel.dismiss()

    #expect(!panel.isPresented)
    #expect(panel.model == nil)
    #expect(!panel.acceptsInput)
    #expect(panel.unavailableMessage == nil)
    #expect(finder.cancelCount == 1)
    #expect(model.query.isEmpty)
    #expect(model.state == .idle)
}

@Test
@MainActor
func agenticSearchPanelExplainsAnUnavailableFinderAndStillDismisses() {
    var panel = AgenticSearchPanelState()

    panel.present(nil)

    #expect(panel.isPresented)
    #expect(!panel.acceptsInput)
    #expect(panel.unavailableMessage == AgenticSearchPanelState.unavailableMessage)

    panel.dismiss()

    #expect(!panel.isPresented)
    #expect(panel.unavailableMessage == nil)
}

@Test
@MainActor
func agenticSearchPanelReopensWithAFreshFinder() {
    let first = StubAgenticFinder()
    let second = StubAgenticFinder()
    var panel = AgenticSearchPanelState()

    panel.present(AgenticConversationFinderModel(finder: first))
    panel.dismiss()
    panel.present(AgenticConversationFinderModel(finder: second))

    #expect(panel.isPresented)
    #expect(panel.acceptsInput)
    #expect(first.cancelCount == 1)
    #expect(second.cancelCount == 0)
}
