// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore

/// Sharing and family (SPEC §16.7): the models of one session and what runs after a sync.
extension SessionModel {
    func setUpFamily(_ services: AccountServices) {
        family = FamilyLibraryModel(
            services: services, excludedFolders: { [weak self] in self?.excludedFolders ?? [] },
            mimeTypes: { [weak self] in (self?.features.allMimeTypes ?? []) + MimeTypes.appleExtras },
            afterChange: { [weak self] in await self?.syncNow() })
        #if os(iOS)
            let library: (any DeviceLibrary)? = PhotoKitDeviceLibrary()
        #else
            let library: (any DeviceLibrary)? = nil
        #endif
        let directory = services.layout.accountDirectory(services.account.id)
        lockScreenAlbum = LockScreenAlbumModel(
            services: services, library: library, hiddenPeople: { HiddenPeopleFile.names(in: directory) },
            refreshAlbum: { [weak self] album in try? await self?.refreshAlbumContent(album) })
    }

    /// After a sync: the Lock Screen album follows its Nextcloud album (at most every 15 minutes), the family
    /// suggestions are looked for again (every 30), and the prompt reminders are scheduled again (every 6 hours).
    func afterSyncFamily(now: Date = Date()) async {
        guard PhotoOfTheDayNotifications.isApp, !isStopped else { return }
        // Not awaited: copying photos to the device can take a while and must not hold up the rest.
        if let lockScreenAlbum { Task { await lockScreenAlbum.sync() } }
        if family?.settings.isSetUp == true { await family?.refresh() }
        if familyState.promptsScheduledAt.map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true {
            familyState.promptsScheduledAt = now
            await WeeklyPromptNotifications.reschedule(session: self)
        }
    }
}

/// Bookkeeping of the family features for one session.
struct FamilyState {
    var promptsScheduledAt: Date?
}
