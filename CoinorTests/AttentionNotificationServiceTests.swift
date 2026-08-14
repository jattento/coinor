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

@Test
@MainActor
func remoteDisconnectNotificationUsesNativeEnglishCopyEvenWhileFocused() async throws {
    let center = NotificationCenterSpy()
    let service = AttentionNotificationService(
        center: center,
        isApplicationActive: { true }
    )

    let alias = try #require(RemoteHostAlias(rawValue: "work-mac"))
    await service.notifyRemoteDisconnect(alias)

    let request = try #require(center.requests.first)
    #expect(center.authorizationRequests == 1)
    #expect(center.requests.count == 1)
    #expect(request.identifier == "coinor.remote-disconnect.work-mac")
    #expect(request.content.title == "work-mac disconnected")
    #expect(
        request.content.body
            == "Conan Code will keep trying to reconnect."
    )
}

@Test
func remoteDisconnectNotificationScopeStaysQuietOnlyOutsideRemoteWork() {
    let matrix: [(RemoteDisconnectNotificationScope, Bool)] = [
        (
            RemoteDisconnectNotificationScope(
                isViewingRemoteConversation: false,
                isRemoteHostsInterfacePresented: false
            ),
            false
        ),
        (
            RemoteDisconnectNotificationScope(
                isViewingRemoteConversation: true,
                isRemoteHostsInterfacePresented: false
            ),
            true
        ),
        (
            RemoteDisconnectNotificationScope(
                isViewingRemoteConversation: false,
                isRemoteHostsInterfacePresented: true
            ),
            true
        ),
        (
            RemoteDisconnectNotificationScope(
                isViewingRemoteConversation: true,
                isRemoteHostsInterfacePresented: true
            ),
            true
        ),
    ]

    for (scope, expected) in matrix {
        #expect(scope.allowsDisconnectNotification == expected)
    }
    #expect(!RemoteDisconnectNotificationScope.quiet.allowsDisconnectNotification)
}

@Test
func remoteDisconnectScopeReadsTheSelectedConversationsHost() throws {
    let alias = try #require(RemoteHostAlias(rawValue: "work-mac"))

    let localAndClosed = RemoteDisconnectNotificationScope(
        selectedConversationHost: nil,
        isRemoteHostsInterfacePresented: false
    )
    let remoteConversation = RemoteDisconnectNotificationScope(
        selectedConversationHost: alias,
        isRemoteHostsInterfacePresented: false
    )
    let localButManaging = RemoteDisconnectNotificationScope(
        selectedConversationHost: nil,
        isRemoteHostsInterfacePresented: true
    )

    #expect(!localAndClosed.allowsDisconnectNotification)
    #expect(remoteConversation.allowsDisconnectNotification)
    #expect(remoteConversation.isViewingRemoteConversation)
    #expect(localButManaging.allowsDisconnectNotification)
}

@Test
@MainActor
func coordinatorStaysQuietUntilTheRemoteInterfaceIsPresented() {
    let coordinator = AppCoordinator()

    #expect(coordinator.remoteDisconnectNotificationScope == .quiet)
    #expect(
        !coordinator.remoteDisconnectNotificationScope
            .allowsDisconnectNotification
    )

    coordinator.selectedSessionID = "local-session"

    #expect(
        !coordinator.remoteDisconnectNotificationScope
            .allowsDisconnectNotification
    )

    coordinator.isRemoteHostsInterfacePresented = true

    #expect(
        coordinator.remoteDisconnectNotificationScope
            .allowsDisconnectNotification
    )
    #expect(
        !coordinator.remoteDisconnectNotificationScope
            .isViewingRemoteConversation
    )
}

@Test
func remoteDisconnectEpisodesNotifyOnlyAfterAConnectedHostDrops() throws {
    let alias = try #require(RemoteHostAlias(rawValue: "work-mac"))
    var episodes = RemoteDisconnectNotificationEpisodes()

    let startupDrop = episodes.markUnavailable(alias)
    #expect(!startupDrop)
    episodes.markConnected(alias)
    let firstDrop = episodes.markUnavailable(alias)
    let repeatedRetry = episodes.markUnavailable(alias)
    #expect(firstDrop)
    #expect(!repeatedRetry)
    episodes.markConnected(alias)
    let secondEpisode = episodes.markUnavailable(alias)
    #expect(secondEpisode)
    episodes.remove(alias)
    let afterRemoval = episodes.markUnavailable(alias)
    #expect(!afterRemoval)
}
