import AppKit
import Foundation
import UserNotifications

@MainActor
protocol UserNotificationCentering {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCentering {}

@MainActor
final class AttentionNotificationService {
    private let center: any UserNotificationCentering
    private let isApplicationActive: () -> Bool
    private var authorizationRequested = false
    private var authorizationGranted = false

    init(
        center: any UserNotificationCentering = UNUserNotificationCenter.current(),
        isApplicationActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.center = center
        self.isApplicationActive = isApplicationActive
    }

    func notifyIfNeeded(
        sessionID: String,
        conversationTitle: String
    ) async {
        guard await ensureAuthorization(), !isApplicationActive() else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = conversationTitle
        content.body = "Grok needs your attention."
        content.sound = .default
        content.userInfo = ["sessionID": sessionID]
        await add(
            identifier: "coinor.attention.\(sessionID)",
            content: content
        )
    }

    func notifyRemoteDisconnect(_ alias: RemoteHostAlias) async {
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(alias.rawValue) disconnected"
        content.body = "Conan Code will keep trying to reconnect."
        content.sound = .default
        content.userInfo = ["remoteHostAlias": alias.rawValue]
        await add(
            identifier: "coinor.remote-disconnect.\(alias.rawValue)",
            content: content
        )
    }

    private func ensureAuthorization() async -> Bool {
        if !authorizationRequested {
            authorizationRequested = true
            do {
                authorizationGranted = try await center.requestAuthorization(
                    options: [.alert, .sound]
                )
            } catch {
                authorizationRequested = false
                return false
            }
        }
        return authorizationGranted
    }

    private func add(
        identifier: String,
        content: UNMutableNotificationContent
    ) async {
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: nil
                )
            )
        } catch {
            // Notification failure must never affect the running application.
        }
    }
}

struct RemoteDisconnectNotificationEpisodes {
    private var previouslyConnected: Set<RemoteHostAlias> = []
    private var notifiedUnavailable: Set<RemoteHostAlias> = []

    mutating func markConnected(_ alias: RemoteHostAlias) {
        previouslyConnected.insert(alias)
        notifiedUnavailable.remove(alias)
    }

    mutating func markUnavailable(_ alias: RemoteHostAlias) -> Bool {
        guard previouslyConnected.contains(alias) else { return false }
        return notifiedUnavailable.insert(alias).inserted
    }

    mutating func remove(_ alias: RemoteHostAlias) {
        previouslyConnected.remove(alias)
        notifiedUnavailable.remove(alias)
    }
}
