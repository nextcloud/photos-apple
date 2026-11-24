// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore
@preconcurrency import UserNotifications

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Whether the app is in front: activity found then is shown in the app, activity found by a background refresh is
/// announced with a notification. Follows the system's activation notifications (`UIApplication.shared` is not available
/// to the extensions PhotosCore is linked into); off until the app was activated once.
@MainActor
public final class ForegroundState {
    public static let shared = ForegroundState()
    public private(set) var isActive = false

    private init() {
        let center = NotificationCenter.default
        #if os(macOS)
            let active = NSApplication.didBecomeActiveNotification
            let inactive = NSApplication.didResignActiveNotification
        #else
            let active = UIApplication.didBecomeActiveNotification
            let inactive = UIApplication.willResignActiveNotification
        #endif
        // The state lives as long as the app, so the observers are never removed.
        center.addObserver(forName: active, object: nil, queue: .main) { _ in Task { @MainActor in ForegroundState.shared.isActive = true }
        }
        center.addObserver(forName: inactive, object: nil, queue: .main) { _ in
            Task { @MainActor in ForegroundState.shared.isActive = false }
        }
    }
}

/// Local notifications about new photos in shared albums (SPEC SH-7). The app posts them itself after a background
/// refresh found something; the server sends none (that would need a server change, companion S5), so they come as
/// often as the system lets the app refresh, not at once.
public enum SharedAlbumNotifications {
    /// `UserDefaults` key of the switch in Settings (default on).
    public static let enabledKey = "sharedAlbumNotifications"
    static let threadIdentifier = "sharedAlbums"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The text of the notification for one album.
    static func presentation(for activity: AlbumActivity) -> PushNotifications.Presentation {
        let body: String
        if activity.isNewAlbum {
            body =
                activity.ownerDisplayName.map {
                    String(localized: "\($0) shared the album with you.", bundle: .module, comment: "Notification; the owner's name")
                } ?? String(localized: "An album was shared with you.", bundle: .module, comment: "Notification")
        } else {
            body = String(
                localized: "\(activity.added) new photos", bundle: .module, comment: "Notification about a shared album; a count")
        }
        return PushNotifications.Presentation(
            title: activity.title, body: body, threadIdentifier: threadIdentifier, destination: "sharedAlbums", notificationId: nil)
    }

    /// Posts one notification per album (at most three, newest first), replacing an earlier one of the same album.
    /// Never asks for permission: without it nothing is shown, and the activity list in the app has it all.
    static func post(_ activities: [AlbumActivity], account: AccountID) async {
        guard !activities.isEmpty, isEnabled(), PushNotifications.isEnabled() else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        for activity in activities.prefix(3) {
            let content = UNMutableNotificationContent()
            PushNotifications.apply(presentation(for: activity), account: account, to: content)
            let request = UNNotificationRequest(
                identifier: "sharedAlbum-\(account.rawValue)-\(activity.albumId)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
