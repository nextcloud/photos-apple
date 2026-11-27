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
        // Guest Mode (SPEC §16.8.3): no banner over the guest's photos; it waits in Notification Centre.
        GuestMode.isActiveNow ? [.list] : [.banner, .list]
    }

    /// The completion-handler form, called back on the main thread: UIKit asserts that the handler runs there (the async
    /// form finished on another thread and the app crashed when a notification was tapped).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let destination = userInfo["photosDestination"] as? String
        // The photo of the day carries a link with its account (SPEC §15.8.4).
        let link = (userInfo["photosLink"] as? String).flatMap(URL.init(string:))
        let done = NotificationCompletion(call: completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppLock.shared.refresh()
                if let link, AppHost.model.open(link) {
                } else if let destination {
                    AppHost.model.requestedDestination = destination
                }
                done.call()
            }
        }
    }
}

/// The completion handler of a notification response, which UserNotifications does not declare Sendable.
///
/// `@unchecked Sendable`: it is only passed to the main queue and called there once.
struct NotificationCompletion: @unchecked Sendable {
    let call: () -> Void
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
            // On-device feature prints for "Show Similar" and key photos, while the Mac is idle.
            SimilarIndexing.register { AppHost.model }
            // Descriptions of photos for VoiceOver and search, while charging and idle (SPEC §16.2).
            PhotoDescriptions.register { AppHost.model }
            // People on this device where the server has no Recognize, while the Mac is idle (SPEC §22.3).
            DevicePeopleIndexing.register { AppHost.model }
            // Smart offline fills up while the Mac is idle (SPEC §15.8.1).
            SmartOfflineScheduling.register { AppHost.model }
        }

        func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            AppHost.model.didRegisterForPush(deviceToken: deviceToken)
        }

        /// ⌘Q does not end Guest Mode (SPEC §16.8.3): only Touch ID or the password does. Logging out, shutting down and
        /// Force Quit still end the app (it comes back in Guest Mode).
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard GuestMode.isActiveNow, let event = NSApplication.shared.currentEvent, event.type == .keyDown else { return .terminateNow }
            return .terminateCancel
        }

        /// Silent pushes withdraw notifications that were read or dismissed elsewhere (SPEC §7.21).
        func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
            let subject = userInfo["subject"] as? String
            Task { await AppHost.model.handleBackgroundPush(subject: subject) }
        }
    }
#endif
