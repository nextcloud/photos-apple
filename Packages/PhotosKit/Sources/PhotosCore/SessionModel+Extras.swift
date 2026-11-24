// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import PhotosNetworking

/// Smart offline, the photo of the day, collages and sticker packs (SPEC §15.8).
extension SessionModel {
    /// After a sync: a smart offline pass (at most every ten minutes) and the photo of the day scheduled again with what
    /// the library has now (at most every half hour), so a photo archived since is not the one that comes.
    func afterSyncExtras(now: Date = Date()) async {
        // Only in the app: not in unit tests of the session (no notification centre there, and their stubbed servers do
        // not expect preview downloads) or in extensions.
        guard PhotoOfTheDayNotifications.isApp, let smartOffline, !isStopped else { return }
        if extrasState.smartOfflineRunAt.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
            extrasState.smartOfflineRunAt = now
            Task.detached(priority: .utility) { await smartOffline.run() }
        }
        if extrasState.photoOfTheDayScheduledAt.map({ now.timeIntervalSince($0) >= 1800 }) ?? true {
            extrasState.photoOfTheDayScheduledAt = now
            await PhotoOfTheDayNotifications.reschedule(session: self)
        }
    }

    /// The setting or app lock changed: schedule the photo of the day again now.
    public func photoOfTheDaySettingsChanged() async {
        extrasState.photoOfTheDayScheduledAt = Date()
        await PhotoOfTheDayNotifications.reschedule(session: self)
    }

    /// The smart offline budget or quality changed: a pass now (it removes at once what no longer fits).
    public func smartOfflineSettingsChanged() async {
        extrasState.smartOfflineRunAt = Date()
        SmartOfflineScheduling.schedule()
        await smartOffline?.run()
    }

    /// An album was opened: its photos are candidates for smart offline for a while.
    public func noteAlbumViewed(_ albumId: String) {
        guard let smartOffline else { return }
        Task { await smartOffline.noteAlbumViewed(albumId) }
    }

    // MARK: Collages

    /// Uploads a collage or card as a new photo into the upload folder (`photosLocation`), then syncs so it shows up.
    @discardableResult
    public func saveImageToLibrary(_ data: Data, fileName: String) async throws -> String {
        guard let services else { throw NetworkError.unauthorized }
        let directory = FileManager.default.temporaryDirectory.appending(path: "Creations/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: fileName)
        try data.write(to: file)
        let uploaded = try await Uploader(dav: services.dav).upload(
            file: file, fileName: fileName, folder: features.userConfig.photosLocation, capturedAt: Date())
        Task { await syncNow() }
        return uploaded.path
    }

    // MARK: Sticker packs

    /// The photos of a person's sticker pack with the person's face in each (unit coordinates, origin top left).
    public func stickerPackPhotos(person: String) async throws -> [(item: MediaItem, face: CGRect)] {
        guard let services else { throw NetworkError.unauthorized }
        let photos = try await services.api.personPhotos(person, key: await recognizeKey())
        var faces: [FileID: CGRect] = [:]
        var items: [FileID: MediaItem] = [:]
        for photo in photos {
            guard let box = photo.box else { continue }
            faces[photo.item.fileId] = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
            items[photo.item.fileId] = photo.item
        }
        let chosen = StickerSubjects.packPhotos(Array(items.values), faces: faces)
        return chosen.compactMap { id in items[id].flatMap { item in faces[id].map { (item, $0) } } }
    }
}

/// Bookkeeping of the extras for one session.
struct ExtrasState {
    var smartOfflineRunAt: Date?
    var photoOfTheDayScheduledAt: Date?
}
