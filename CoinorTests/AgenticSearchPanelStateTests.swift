import Foundation
import Testing

@testable import Coinor

private final class StubAgenticFinder: AgenticConversationFinding, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0
    private var requests: [AgenticFinderRequest] = []

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    var submittedRequests: [AgenticFinderRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func find(_ request: AgenticFinderRequest) async throws -> AgenticFinderResponse {
        lock.withLock {
            requests.append(request)
        }
        return AgenticFinderResponse(message: "ok", matches: [])
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
func agenticSearchActivationSubmitsOnlyANonEmptyCarriedQuery() {
    #expect(AgenticSearchActivation.shouldSubmit(carriedQuery: "yesterday remote"))
    #expect(AgenticSearchActivation.shouldSubmit(carriedQuery: "  keep me  "))
    #expect(!AgenticSearchActivation.shouldSubmit(carriedQuery: ""))
    #expect(!AgenticSearchActivation.shouldSubmit(carriedQuery: "   \n\t"))
}

@Test
@MainActor
func activatingAISearchCarriesTheFuzzyQueryAndReportsSubmit() {
    let finder = StubAgenticFinder()
    let model = AgenticConversationFinderModel(finder: finder)
    var panel = AgenticSearchPanelState()

    let shouldSubmit = panel.present(model, carrying: "yesterday remote")

    #expect(shouldSubmit)
    #expect(panel.isPresented)
    #expect(panel.model?.query == "yesterday remote")
}

@Test
@MainActor
func activatingAISearchSubmitsTheCarriedQueryExactlyOnce() async {
    let finder = StubAgenticFinder()
    let model = AgenticConversationFinderModel(finder: finder)
    var panel = AgenticSearchPanelState()

    let shouldSubmit = panel.present(model, carrying: "yesterday remote")
    #expect(shouldSubmit)

    model.submit(loadCandidates: { [] })
    model.submit(loadCandidates: { [] })
    for _ in 0..<50 where finder.submittedRequests.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(finder.submittedRequests.count == 1)
    #expect(finder.submittedRequests.first?.query == "yesterday remote")
    panel.dismiss()
    panel.dismiss()
    #expect(finder.submittedRequests.count == 1)
}

@Test
@MainActor
func activatingAISearchWithEmptyTextDoesNotSubmitOrInventAQuery() {
    let finder = StubAgenticFinder()
    let model = AgenticConversationFinderModel(finder: finder)
    var panel = AgenticSearchPanelState()

    let shouldSubmit = panel.present(model, carrying: "   ")

    #expect(!shouldSubmit)
    #expect(panel.model?.query == "   ")
    panel.model?.submit(loadCandidates: { [] })
    #expect(finder.submittedRequests.isEmpty)
    #expect(panel.model?.state == .idle)
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
