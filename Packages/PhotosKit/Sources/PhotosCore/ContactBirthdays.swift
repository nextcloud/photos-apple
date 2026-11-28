// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore
import UserNotifications

/// Birthdays from the user's Nextcloud Contacts (SPEC §22.3): read over CardDAV once a day after a sync (read-only;
/// nothing is written to the contacts), matched with the named people, shown as "Anna's birthday" memories, and on the
/// day a reminder to look back (a notification at 9:00, only where notifications are allowed already; the app does not
/// ask for them for this). A server without contacts or birthdays shows nothing. Settings › Memories turns it off,
/// which deletes the birthdays read.
public enum ContactBirthdays {
    /// `UserDefaults` key of the switch (default on).
    public static let enabledKey = "contactBirthdays"
    /// The contacts are read again after this long.
    static let refreshInterval: TimeInterval = 24 * 3600
    static let identifierPrefix = "birthday-"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "birthdays")

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Reads the birthdays when due and schedules the reminders.
    @MainActor static func refreshIfDue(_ session: SessionModel, now: Date = Date()) async {
        guard isEnabled(), let services = session.services else { return }
        let store = ContactBirthdayStore(database: services.database)
        let last = (try? store.readAt()) ?? nil
        if last.map({ now.timeIntervalSince($0) >= refreshInterval }) ?? true {
            do {
                try store.replace(try await services.api.contactBirthdays(), at: now)
            } catch {
                // No contacts (no address books, or the server refuses): nothing to show, as without birthdays.
                logger.info("birthdays not read: \(error.localizedDescription, privacy: .public)")
            }
        }
        await scheduleReminders(session, now: now)
    }

    /// Turns the feature on or off: off deletes the birthdays and the reminders.
    @MainActor public static func apply(enabled: Bool, session: SessionModel) async {
        if enabled {
            await refreshIfDue(session)
        } else {
            if let services = session.services { try? ContactBirthdayStore(database: services.database).deleteAll() }
            await removeReminders()
        }
    }

    /// What a reminder says.
    public static func reminderText(person: String) -> (title: String, body: String) {
        (
            String(localized: "\(person)'s birthday", bundle: .module, comment: "Title of the birthday reminder notification."),
            String(
                localized: "It's \(person)'s birthday today. Look back at their birthdays and send a photo?", bundle: .module,
                comment: "Body of the birthday reminder notification, on the day.")
        )
    }

    /// Schedules a reminder at 9:00 on the next birthday of each matched person (and removes the ones no longer wanted).
    @MainActor static func scheduleReminders(_ session: SessionModel, now: Date = Date(), calendar: Calendar = .current) async {
        #if !os(tvOS)  // No notification content on Apple TV (SPEC §15.3).
            guard let services = session.services, PhotoOfTheDayNotifications.isApp else { return }
            let center = UNUserNotificationCenter.current()
            await removeReminders()
            guard isEnabled(), await center.notificationSettings().authorizationStatus == .authorized else { return }
            let birthdays = (try? ContactBirthdayStore(database: services.database).personBirthdays()) ?? []
            let locked = AppLockSettings.isEnabled()
            for birthday in birthdays {
                guard let day = Birthdays.next(birthday.contact, after: now, calendar: calendar) else { continue }
                var parts = calendar.dateComponents([.year, .month, .day], from: day)
                parts.hour = 9
                guard let fire = calendar.date(from: parts), fire > now else { continue }
                let content = UNMutableNotificationContent()
                let text = reminderText(person: birthday.person)
                // With app lock on, the notification says nothing about whom.
                content.title =
                    locked
                    ? String(localized: "A birthday today", bundle: .module, comment: "Birthday reminder while app lock is on.")
                    : text.title
                content.body = locked ? "" : text.body
                content.threadIdentifier = "birthdays"
                let link = DeepLink.person(name: birthday.person)
                content.userInfo[PushNotifications.destinationKey] = link.request
                if let url = link.url(for: session.account) { content.userInfo[PhotoOfTheDayNotifications.linkKey] = url.absoluteString }
                let request = UNNotificationRequest(
                    identifier: identifierPrefix + birthday.contact.uid, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                try? await center.add(request)
            }
        #endif
    }

    static func removeReminders() async {
        guard PhotoOfTheDayNotifications.isApp else { return }
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
