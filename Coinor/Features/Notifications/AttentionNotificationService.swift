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
        guard !isApplicationActive() else { return }

        do {
            if !authorizationRequested {
                authorizationRequested = true
                guard try await center.requestAuthorization(
                    options: [.alert, .sound]
                ) else {
                    return
                }
            }

            let content = UNMutableNotificationContent()
            content.title = conversationTitle
            content.body = "Grok needs your attention."
            content.sound = .default
            content.userInfo = ["sessionID": sessionID]
            try await center.add(
                UNNotificationRequest(
                    identifier: "coinor.attention.\(sessionID)",
                    content: content,
                    trigger: nil
                )
            )
        } catch {
            // Notification failure must never affect the running conversation.
        }
    }
}
