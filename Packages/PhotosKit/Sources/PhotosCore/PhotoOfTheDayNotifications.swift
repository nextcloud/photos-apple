// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import UserNotifications

/// The "Photo of the day" setting (SPEC §15.8.4): off by default; the time of day is the user's.
public enum PhotoOfTheDaySettings {
    public static let enabledKey = "photoOfTheDayEnabled"
    /// Minutes after midnight (default 9:00).
    public static let timeKey = "photoOfTheDayTime"
    public static let defaultTime = 9 * 60
    /// Which photo was chosen for which day, so a photo is not shown again within `PhotoOfTheDay.repeatWindowDays`.
    static let historyKey = "photoOfTheDayHistory"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    public static func time(_ defaults: UserDefaults = .standard) -> Int {
        (defaults.object(forKey: timeKey) as? Int).map { min(max($0, 0), 24 * 60 - 1) } ?? defaultTime
    }
}

/// Schedules the "Photo of the day" as local notifications with the photo attached (SPEC §15.8.4).
///
/// The next `daysAhead` days are scheduled at once, each with its own photo, and scheduled again whenever the app syncs,
/// the setting or app lock changes, or another account is shown: a photo archived in the meantime is replaced before its
/// day comes. With app lock on a notification says only that a photo is waiting, without the photo, its date or place.
/// Tapping it opens the photo in the viewer (after the unlock).
public enum PhotoOfTheDayNotifications {
    static let identifierPrefix = "photoOfTheDay-"
    static let threadIdentifier = "photoOfTheDay"
    /// Today (when the time has not passed yet) and the next days.
    static let daysAhead = 3
    static let linkKey = "photosLink"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "photo-of-the-day")

    /// What a notification says.
    struct Text: Equatable {
        var title: String
        var body: String
    }

    static func text(for choice: DailyPhotoChoice?, locked: Bool, locale: Locale = .current) -> Text {
        let title = String(localized: "Photo of the Day", bundle: .module, comment: "Title of the daily photo notification.")
        guard let choice, !locked else {
            return Text(
                title: title,
                body: String(
                    localized: "A photo from your library is waiting for you.", bundle: .module,
                    comment: "Body of the daily photo notification while app lock is on: no photo, date or place is shown."))
        }
        let detail: String
        switch choice.reason {
        case .yearsAgo(let years):
            detail = String(
                localized: "On this day \(years) years ago", bundle: .module,
                comment: "Daily photo notification: the photo was taken on this day N years ago. Plural variations in the catalog.")
        case .aroundThisDay(let years):
            detail = String(
                localized: "This week \(years) years ago", bundle: .module,
                comment: "Daily photo notification: the photo was taken around this day N years ago. Plural variations in the catalog.")
        case .favorite:
            let month = choice.takenAt.formatted(.dateTime.month(.wide).year().locale(locale))
            detail = String(
                localized: "From your favorites · \(month)", bundle: .module,
                comment: "Daily photo notification when the photo is a favourite: the argument is its month and year, e.g. June 2019.")
        }
        if let place = choice.place, !place.isEmpty { return Text(title: title, body: "\(detail) · \(place)") }
        return Text(title: title, body: detail)
    }

    /// The times the next notifications go out: today at the chosen time if that is still to come, then the following days.
    static func fireDates(now: Date, minutes: Int, days: Int = daysAhead, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0...days).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                let time = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day), time > now
            else { return nil }
            return time
        }
        .prefix(days)
        .map { $0 }
    }

    /// Day keys ("2026-11-24") of the history that still count as "shown lately" for `day`: the days before it within the
    /// repeat window. The choices for `day` and later are made again on every reschedule.
    static func recentlyShown(_ history: [String: Int64], before day: Date, calendar: Calendar = .current) -> Set<FileID> {
        let start = calendar.startOfDay(for: day)
        guard let earliest = calendar.date(byAdding: .day, value: -PhotoOfTheDay.repeatWindowDays, to: start) else { return [] }
        return Set(
            history.compactMap { key, fileId in
                guard let date = dayDate(key, calendar: calendar), date >= earliest, date < start else { return nil }
                return FileID(fileId)
            })
    }

    /// The history without the days that no longer matter.
    static func pruned(_ history: [String: Int64], now: Date, calendar: Calendar = .current) -> [String: Int64] {
        guard let earliest = calendar.date(byAdding: .day, value: -PhotoOfTheDay.repeatWindowDays, to: calendar.startOfDay(for: now))
        else { return history }
        return history.filter { key, _ in (dayDate(key, calendar: calendar) ?? .distantPast) >= earliest }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func dayDate(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func loadHistory(_ defaults: UserDefaults) -> [String: Int64] {
        (defaults.dictionary(forKey: PhotoOfTheDaySettings.historyKey) as? [String: Int64])
            ?? (defaults.dictionary(forKey: PhotoOfTheDaySettings.historyKey) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:]
    }

    // MARK: Scheduling

    /// Asks for permission to notify (alerts and sounds, no push registration). True when notifications may be shown.
    @MainActor public static func requestAuthorization() async -> Bool {
        guard isApp else { return false }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .authorized || status == .provisional { return true }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Running as the app (the notification centre exists only for an app bundle, not in unit tests or extensions).
    static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Replaces the scheduled notifications with new ones for the account shown (none when the setting is off).
    @MainActor public static func reschedule(session: SessionModel?, defaults: UserDefaults = .standard) async {
        #if !os(tvOS)  // No notification content on Apple TV (SPEC §15.3).
            guard isApp else { return }
            let center = UNUserNotificationCenter.current()
            await removePending(center: center)
            guard PhotoOfTheDaySettings.isEnabled(defaults), let session, let services = session.services, !session.isSignedOut else {
                return
            }
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let locked = AppLockSettings.isEnabled()
            let excluded = session.excludedFolders
            let account = session.account
            let now = Date()
            var history = pruned(loadHistory(defaults), now: now)
            var chosenNow: Set<FileID> = []
            var dates = fireDates(now: now, minutes: PhotoOfTheDaySettings.time(defaults))
            #if DEBUG
                // UI checks: PHOTOS_DEBUG_PHOTO_OF_THE_DAY_IN=<seconds> adds a notification that soon.
                if let seconds = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_PHOTO_OF_THE_DAY_IN"].flatMap(Double.init) {
                    dates = [now.addingTimeInterval(seconds)] + dates.prefix(daysAhead - 1)
                }
            #endif
            for date in dates {
                guard
                    let pools = try? await services.library.dailyPhotoCandidates(for: date, excludedFolders: excluded)
                else { continue }
                let shown = recentlyShown(history, before: date).union(chosenNow)
                let choice = PhotoOfTheDay.choose(for: date, onThisDay: pools.onThisDay, favorites: pools.favorites, recentlyShown: shown)
                guard let choice else { continue }
                chosenNow.insert(choice.fileId)
                history[dayKey(date)] = Int64(choice.fileId)
                let text = text(for: choice, locked: locked)
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.threadIdentifier = threadIdentifier
                content.sound = nil
                content.userInfo[PushNotifications.accountKey] = account.id.rawValue
                content.userInfo[PushNotifications.destinationKey] = DeepLink.photo(fileId: choice.fileId).request
                if let link = DeepLink.photo(fileId: choice.fileId).url(for: account) { content.userInfo[linkKey] = link.absoluteString }
                if !locked, let attachment = await attachment(for: choice.fileId, day: dayKey(date), services: services) {
                    content.attachments = [attachment]
                }
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let request = UNNotificationRequest(
                    identifier: identifierPrefix + String(Int(date.timeIntervalSince1970)), content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                do {
                    try await center.add(request)
                } catch {
                    logger.error("could not schedule: \(error.localizedDescription, privacy: .public)")
                }
            }
            defaults.set(history, forKey: PhotoOfTheDaySettings.historyKey)
        #endif
    }

    #if !os(tvOS)
        /// A 1024 px preview of the photo as the notification's attachment (the system moves the file into its own store).
        static func attachment(for fileId: FileID, day: String, services: AccountServices) async -> UNNotificationAttachment? {
            guard let item = try? services.library.item(fileId) else { return nil }
            let data: Data
            if let image = services.images.cache.diskImage(fileId: fileId, etag: item.etag, bucket: 1024),
                let local = ImageDecoding.jpegData(image, quality: 0.85)
            {
                data = local
            } else if let downloaded = try? await services.api.preview(fileId: fileId, size: 1024, etag: item.etag) {
                data = downloaded
            } else {
                return nil
            }
            let directory = FileManager.default.temporaryDirectory.appending(path: "PhotoOfTheDay")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "\(day)-\(fileId).jpg")
            do {
                try data.write(to: file, options: .atomic)
                return try UNNotificationAttachment(
                    identifier: "photo", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
            } catch {
                return nil
            }
        }
    #endif

    /// Removes the notifications that are scheduled and not delivered yet.
    static func removePending(center: UNUserNotificationCenter = .current()) async {
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    /// Account removal: what was scheduled for it goes (delivered ones go with the account's other notifications).
    public static func removePending(account: AccountID) async {
        #if !os(tvOS)  // No notification content on Apple TV (SPEC §15.3).
            guard isApp else { return }
            let center = UNUserNotificationCenter.current()
            let ids = await center.pendingNotificationRequests()
                .filter {
                    $0.identifier.hasPrefix(identifierPrefix)
                        && ($0.content.userInfo[PushNotifications.accountKey] as? String) == account.rawValue
                }
                .map(\.identifier)
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        #endif
    }
}
