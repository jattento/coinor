import Foundation
import Testing

@testable import Coinor

@Suite
struct AutomationRunRequestTests {
    @Test
    func urlRoundTripsBackToTheSameRequest() throws {
        let request = AutomationRunRequest(
            automationID: "auto-1",
            runID: "run-1",
            sessionID: "session-1",
            trigger: .scheduled
        )

        let url = AutomationRunRequestRouting.url(for: request)
        let parsed = AutomationRunRequestRouting.parse(url)

        #expect(url.scheme == "coinor")
        #expect(url.host == "run-automation")
        #expect(parsed == request)
    }

    @Test
    func forcedTriggerRoundTrips() throws {
        let request = AutomationRunRequest(
            automationID: "auto-2",
            runID: "run-2",
            sessionID: "session-2",
            trigger: .forced
        )

        #expect(AutomationRunRequestRouting.parse(AutomationRunRequestRouting.url(for: request)) == request)
    }

    @Test
    func parseRejectsAWrongSchemeOrHost() throws {
        #expect(AutomationRunRequestRouting.parse(URL(string: "https://run-automation?automationID=a&runID=r&sessionID=s&trigger=scheduled")!) == nil)
        #expect(AutomationRunRequestRouting.parse(URL(string: "coinor://something-else?automationID=a&runID=r&sessionID=s&trigger=scheduled")!) == nil)
    }

    @Test
    func parseRejectsMissingOrUnknownFields() throws {
        #expect(AutomationRunRequestRouting.parse(URL(string: "coinor://run-automation?automationID=a&runID=r&sessionID=s")!) == nil)
        #expect(AutomationRunRequestRouting.parse(URL(string: "coinor://run-automation?automationID=a&runID=r&sessionID=s&trigger=unknown")!) == nil)
        #expect(AutomationRunRequestRouting.parse(URL(string: "coinor://run-automation")!) == nil)
    }

    @Test
    func urlPercentEncodesUnsafeCharactersInIdentifiers() throws {
        let request = AutomationRunRequest(
            automationID: "auto with space & stuff",
            runID: "run-3",
            sessionID: "session-3",
            trigger: .scheduled
        )

        let url = AutomationRunRequestRouting.url(for: request)

        #expect(AutomationRunRequestRouting.parse(url) == request)
        #expect(!url.absoluteString.contains(" "))
    }
}
