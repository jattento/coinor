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

    /// Mirrors the `osascript display notification` the launchd job's own
    /// shell script posts for a run it executed itself (see
    /// `AutomationJob.script`), for a run Coinor executed live instead.
    func notifyAutomationFinished(name: String, succeeded: Bool) async {
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Automation finished" : "Automation failed"
        content.body = name
        content.sound = .default
        await add(
            identifier: "coinor.automation-finished.\(UUID().uuidString)",
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

/// Where the user is standing when a registered remote computer drops.
///
/// A computer that goes away is only worth interrupting for while the user is
/// actually looking at remote work: a remote conversation is selected, or the
/// remote-computers interface is on screen. Everywhere else the sidebar badge
/// already carries the state, so the alert would be noise about a machine the
/// user is not using.
struct RemoteDisconnectNotificationScope: Equatable {
    /// The selected conversation runs on a remote computer.
    var isViewingRemoteConversation: Bool
    /// The add/manage remote-computer interface is presented.
    var isRemoteHostsInterfacePresented: Bool

    static let quiet = RemoteDisconnectNotificationScope(
        isViewingRemoteConversation: false,
        isRemoteHostsInterfacePresented: false
    )

    /// Builds the scope from what the shell knows: which computer owns the
    /// selected conversation, if any, and whether the remote-computers
    /// interface is up.
    init(
        selectedConversationHost: RemoteHostAlias?,
        isRemoteHostsInterfacePresented: Bool
    ) {
        self.isViewingRemoteConversation = selectedConversationHost != nil
        self.isRemoteHostsInterfacePresented = isRemoteHostsInterfacePresented
    }

    init(
        isViewingRemoteConversation: Bool,
        isRemoteHostsInterfacePresented: Bool
    ) {
        self.isViewingRemoteConversation = isViewingRemoteConversation
        self.isRemoteHostsInterfacePresented = isRemoteHostsInterfacePresented
    }

    var allowsDisconnectNotification: Bool {
        isViewingRemoteConversation || isRemoteHostsInterfacePresented
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
