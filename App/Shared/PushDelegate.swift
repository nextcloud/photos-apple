// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import UserNotifications

/// Shows notifications in the foreground and routes taps (SPEC §7.21).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    @MainActor var app: AppModel?

    @MainActor func requestAuthorizationAndRegister(_ register: @escaping @MainActor () -> Void) {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted { register() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let destination = userInfo["photosDestination"] as? String
        await MainActor.run {
            if let destination { self.app?.requestedDestination = destination }
        }
    }
}

#if os(macOS)
    import AppKit

    final class MacAppDelegate: NSObject, NSApplicationDelegate {
        @MainActor static var app: AppModel?

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                NotificationRouter.shared.app = MacAppDelegate.app
                PushNotifications.install(delegate: NotificationRouter.shared) { NSApplication.shared.registerForRemoteNotifications() }
            }
        }

        func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            Task { @MainActor in MacAppDelegate.app?.didRegisterForPush(deviceToken: deviceToken) }
        }
    }
#endif
