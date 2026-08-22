import Foundation
import Testing

@testable import Coinor

/// Covers the optimistic rename path: `AppCoordinator.renameConversation`
/// applies `OptimisticTitleUpdate` synchronously so the sidebar shows the new
/// title before the rename RPC and any catalog refresh complete.
@Suite
struct OptimisticTitleUpdateTests {
    @Test
    func replacesTheMatchingSessionsTitleAndReturnsItsPreviousState() throws {
        let target = try session(id: "target", title: "Old title")
        let other = try session(id: "other", title: "Untouched")

        let result = OptimisticTitleUpdate.apply(
            to: [other, target],
            sessionID: "target",
            title: "New title"
        )

        #expect(result.sessions.count == 2)
        #expect(result.sessions.first(where: { $0.id.rawValue == "target" })?.title == "New title")
        #expect(result.sessions.first(where: { $0.id.rawValue == "other" })?.title == "Untouched")
        #expect(result.previous?.title == "Old title")
    }

    @Test
    func leavesTheArrayUntouchedAndReturnsNilWhenTheSessionIsMissing() throws {
        let other = try session(id: "other", title: "Untouched")

        let result = OptimisticTitleUpdate.apply(
            to: [other],
            sessionID: "missing",
            title: "New title"
        )

        #expect(result.sessions == [other])
        #expect(result.previous == nil)
    }

    @Test
    func withTitlePreservesEveryOtherFieldOnTheSession() throws {
        let original = try session(
            id: "target",
            title: "Old title",
            cwd: "/tmp/example",
            branch: "main"
        )

        let renamed = original.withTitle("New title")

        #expect(renamed.title == "New title")
        #expect(renamed.id == original.id)
        #expect(renamed.cwd == original.cwd)
        #expect(renamed.branch == original.branch)
        #expect(renamed.raw == original.raw)
    }

    private func session(
        id: String,
        title: String,
        cwd: String? = nil,
        branch: String? = nil
    ) throws -> GrokPersistedSession {
        var raw: [String: GrokJSONValue] = [
            "sessionId": .string(id),
            "title": .string(title),
        ]
        if let cwd {
            raw["cwd"] = .string(cwd)
        }
        if let branch {
            raw["branch"] = .string(branch)
        }
        return try GrokPersistedSession(raw: .object(raw))
    }
}
