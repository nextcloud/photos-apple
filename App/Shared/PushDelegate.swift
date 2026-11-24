// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import UserNotifications

/// Shows notifications in the foreground and routes taps (SPEC §7.21).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let destination = userInfo["photosDestination"] as? String
        await MainActor.run {
            if let destination { AppHost.model.requestedDestination = destination }
        }
    }
}

#if os(macOS)
    import AppKit

    final class MacAppDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            // Creates the app model now, whether or not a window follows.
            _ = AppHost.model
            PushNotifications.install(delegate: NotificationRouter.shared) { NSApplication.shared.registerForRemoteNotifications() }
            // On-device recognition for search, while the Mac is idle (opt-in).
            ContentLabeling.register { AppHost.model }
        }

        func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            AppHost.model.didRegisterForPush(deviceToken: deviceToken)
        }

        /// Silent pushes withdraw notifications that were read or dismissed elsewhere (SPEC §7.21).
        func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
            let subject = userInfo["subject"] as? String
            Task { await AppHost.model.handleBackgroundPush(subject: subject) }
        }
    }
#endif
