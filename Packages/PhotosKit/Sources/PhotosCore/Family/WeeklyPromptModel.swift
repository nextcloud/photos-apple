// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore
import UserNotifications

/// The weekly photo prompts' options (SPEC §16.7.3): off by default, and so is the reminder.
public enum WeeklyPromptSettings {
    public static let enabledKey = "weeklyPromptsEnabled"
    public static let remindersKey = "weeklyPromptReminders"
    /// When prompts were turned on; the history goes back to that week.
    public static let enabledAtKey = "weeklyPromptsEnabledAt"
    /// The invitation card in Memories was dismissed.
    public static let invitationDismissedKey = "weeklyPromptsInvitationDismissed"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }
    public static func remindersOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: remindersKey) }

    public static func enabledAt(_ defaults: UserDefaults = .standard) -> Date {
        (defaults.object(forKey: enabledAtKey) as? Date) ?? Date()
    }

    /// Turns prompts on or off; the first time on is remembered for the history.
    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        if enabled, defaults.object(forKey: enabledAtKey) == nil { defaults.set(Date(), forKey: enabledAtKey) }
    }
}

/// A week's prompt with what the user did for it.
public struct PromptWeek: Hashable, Sendable, Identifiable {
    public var prompt: WeeklyPrompt
    /// The prompt's album, when it exists.
    public var album: Album?
    /// Photos in that album that were taken in the prompt's week.
    public var photosThisWeek: Int

    public var id: Int { prompt.id }
}

/// Weekly photo prompts (SPEC §16.7.3): a built-in theme each week; photos taken that week go into a normal album
/// ("Prompt: Reflections") when the user adds them.
extension SessionModel {
    /// This week's prompt.
    public func currentPrompt(now: Date = Date()) -> WeeklyPrompt { WeeklyPrompts.prompt(for: now) }

    /// The user's own photos and videos taken in the prompt's week, newest first.
    public func photosForPrompt(_ prompt: WeeklyPrompt) async -> [MediaItem] {
        guard let services else { return [] }
        return (try? await FamilyStore(database: services.database).photosTaken(in: prompt.week, excludedFolders: excludedFolders)) ?? []
    }

    /// The prompt's album, if the user has one (an own album of that name).
    public func promptAlbum(_ prompt: WeeklyPrompt) -> Album? {
        guard let services else { return nil }
        let name = prompt.albumName
        return (try? services.collections.albums(.own))?.first { $0.name == name }
    }

    /// The prompt with its album and how many of the week's photos are in it.
    public func promptWeek(_ prompt: WeeklyPrompt) -> PromptWeek {
        guard let services, let album = promptAlbum(prompt) else { return PromptWeek(prompt: prompt, album: nil, photosThisWeek: 0) }
        let ids = ((try? services.collections.albumItems(albumId: album.id)) ?? []).map(\.fileId)
        let count = ids.compactMap { try? services.collections.mediaItem(fileId: $0) }.filter { prompt.week.contains($0.timestamp) }.count
        return PromptWeek(prompt: prompt, album: album, photosThisWeek: count)
    }

    /// The weeks before this one since prompts were turned on, newest first.
    public func promptHistory(now: Date = Date()) -> [PromptWeek] {
        WeeklyPrompts.history(since: WeeklyPromptSettings.enabledAt(), now: now).map(promptWeek)
    }

    /// Adds photos to the prompt's album, making the album when it is not there yet.
    public func addToPrompt(_ items: [MediaItem], prompt: WeeklyPrompt) async throws {
        guard !items.isEmpty else { return }
        let album: Album
        if let existing = promptAlbum(prompt) {
            album = existing
        } else {
            try? await refreshAlbums(force: true)
            if let found = promptAlbum(prompt) {
                album = found
            } else {
                album = try await createAlbum(name: prompt.albumName)
            }
        }
        await addToAlbum(items, album: album)
        try? await refreshAlbumContent(album, force: true)
        // This week is done: no reminder for it.
        await WeeklyPromptNotifications.reschedule(session: self)
    }

    /// The setting or the reminder changed.
    public func weeklyPromptSettingsChanged() async {
        await WeeklyPromptNotifications.reschedule(session: self)
    }
}

/// The gentle reminder of the weekly prompt (SPEC §16.7.3): off by default; on the week's sixth day at 10:00, without
/// a photo, and not for a week the user already added photos to. Four weeks are scheduled ahead and again after syncs.
public enum WeeklyPromptNotifications {
    static let identifierPrefix = "weeklyPrompt-"
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "weekly-prompt")

    /// What a reminder says.
    static func text(for prompt: WeeklyPrompt) -> (title: String, body: String) {
        (
            String(localized: "Weekly Photo Prompt", bundle: .module, comment: "Title of the weekly photo prompt reminder notification."),
            String(
                localized: "This week: \(prompt.theme.title). \(prompt.theme.hint)", bundle: .module,
                comment:
                    "Body of the weekly photo prompt reminder: the theme, then its hint, e.g. This week: Hands. Hands at work, at rest, holding on."
            )
        )
    }

    @MainActor public static func reschedule(session: SessionModel?, defaults: UserDefaults = .standard) async {
        #if !os(tvOS) && !os(watchOS)
            guard PhotoOfTheDayNotifications.isApp else { return }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard WeeklyPromptSettings.isEnabled(defaults), WeeklyPromptSettings.remindersOn(defaults), let session, !session.isSignedOut
            else { return }
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let now = Date()
            let done = session.promptWeek(session.currentPrompt(now: now)).photosThisWeek > 0
            for (prompt, date) in WeeklyPrompts.reminders(now: now, currentWeekDone: done) {
                let text = text(for: prompt)
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.threadIdentifier = "weeklyPrompt"
                content.userInfo[PushNotifications.accountKey] = session.account.id.rawValue
                content.userInfo[PushNotifications.destinationKey] = DeepLink.destination("memories").request
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let request = UNNotificationRequest(
                    identifier: identifierPrefix + String(prompt.index), content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                do {
                    try await center.add(request)
                } catch {
                    logger.error("could not schedule: \(error.localizedDescription, privacy: .public)")
                }
            }
        #endif
    }
}
