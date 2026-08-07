import Foundation
import Testing
import UserNotifications

@testable import Coinor

@MainActor
private final class NotificationCenterSpy: UserNotificationCentering {
    var authorizationRequests = 0
    var requests: [UNNotificationRequest] = []
    let grantsAuthorization: Bool

    init(grantsAuthorization: Bool = true) {
        self.grantsAuthorization = grantsAuthorization
    }

    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async throws -> Bool {
        authorizationRequests += 1
        return grantsAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }
}

@Test
@MainActor
func focusedAttentionRequestsAuthorizationButSuppressesNotification() async {
    let center = NotificationCenterSpy()
    let service = AttentionNotificationService(
        center: center,
        isApplicationActive: { true }
    )

    await service.notifyIfNeeded(
        sessionID: "session",
        conversationTitle: "Conversation"
    )

    #expect(center.authorizationRequests == 1)
    #expect(center.requests.isEmpty)
}

@Test
@MainActor
func attentionNotificationUsesEnglishCopyAndStableSessionIdentifier() async {
    let center = NotificationCenterSpy()
    let service = AttentionNotificationService(
        center: center,
        isApplicationActive: { false }
    )

    await service.notifyIfNeeded(
        sessionID: "session",
        conversationTitle: "Fix parser"
    )
    await service.notifyIfNeeded(
        sessionID: "session",
        conversationTitle: "Fix parser"
    )

    let requests = center.requests
    #expect(center.authorizationRequests == 1)
    #expect(requests.count == 2)
    #expect(requests.first?.identifier == "coinor.attention.session")
    #expect(requests.first?.content.title == "Fix parser")
    #expect(requests.first?.content.body == "Grok needs your attention.")
}
