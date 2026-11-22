// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import UserNotifications

/// Decrypts Nextcloud push payloads (SPEC §7.21). Tries the key of every account.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void)
    {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        guard let subject = request.content.userInfo["subject"] as? String else {
            contentHandler(content)
            return
        }
        for account in AccountRegistry.load().accounts {
            guard let payload = PushNotifications.decrypt(subject, account: account.id) else { continue }
            content.title = payload.app == "photos" ? "Nextcloud Photos" : "Nextcloud"
            content.body = payload.subject
            content.threadIdentifier = payload.app
            if payload.app == "photos" && payload.type == nil {
                content.userInfo["photosDestination"] = "onThisDay"
            }
            if payload.app != "photos" {
                // Only Photos notifications belong in this app; others are shown quietly (SPEC §7.21, filtering needs server support).
                content.interruptionLevel = .passive
            }
            break
        }
        contentHandler(content)
    }
}
