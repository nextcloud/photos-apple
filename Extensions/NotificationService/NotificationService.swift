// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import UserNotifications

/// Decrypts Nextcloud push payloads (SPEC §7.21). Tries the key of every account.
///
/// Only notifications of the Photos app are shown. Everything else — notifications of other Nextcloud apps, delete pushes,
/// payloads no account can decrypt — is delivered as empty content, which the system drops when the app has the
/// `com.apple.developer.usernotifications.filtering` entitlement.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void)
    {
        guard let subject = request.content.userInfo["subject"] as? String else {
            // Not a Nextcloud push: leave it as it is.
            contentHandler(request.content)
            return
        }
        for account in AccountRegistry.load().accounts {
            guard let payload = PushNotifications.decrypt(subject, account: account.id) else { continue }
            let action = PushNotifications.action(for: payload)
            switch action {
            case .show(let presentation):
                let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
                PushNotifications.apply(presentation, account: account.id, to: content)
                contentHandler(content)
            case .suppress:
                contentHandler(UNNotificationContent())
            case .removeDelivered, .removeAllDelivered:
                // The handler is not Sendable, but it is only called once, from this task, after the removal.
                nonisolated(unsafe) let finish = contentHandler
                let accountId = account.id
                Task {
                    await PushNotifications.removeDelivered(action, account: accountId)
                    finish(UNNotificationContent())
                }
            }
            return
        }
        // No account has the key (notifications were turned off, or the account was removed): nothing to show.
        contentHandler(UNNotificationContent())
    }
}
