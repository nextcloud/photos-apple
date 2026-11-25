// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

#if os(iOS)
    import CoreLocation
    import Photos
    import Synchronization
#endif

/// The Lock Screen album's options (SPEC §16.7.4), kept with the account.
public struct LockScreenAlbumSettings: Codable, Hashable, Sendable {
    /// The Nextcloud album that is mirrored; nil while it is off.
    public var albumId: String?
    public var albumTitle = ""
    /// The device album that holds the copies.
    public var deviceAlbumIdentifier: String?
    /// Copies taken out of the album whose deletion the user has not confirmed yet.
    public var pendingDeletion: [String] = []
    /// Of those, the ones the user said "Don't Allow" for: an automatic pass does not ask about them again.
    public var declinedDeletion: [String] = []

    public init(albumId: String? = nil, albumTitle: String = "") {
        self.albumId = albumId
        self.albumTitle = albumTitle
    }

    enum CodingKeys: String, CodingKey {
        case albumId, albumTitle, deviceAlbumIdentifier, pendingDeletion, declinedDeletion
    }

    /// Fields added later may be missing in what was stored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        albumId = try container.decodeIfPresent(String.self, forKey: .albumId)
        albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle) ?? ""
        deviceAlbumIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceAlbumIdentifier)
        pendingDeletion = try container.decodeIfPresent([String].self, forKey: .pendingDeletion) ?? []
        declinedDeletion = try container.decodeIfPresent([String].self, forKey: .declinedDeletion) ?? []
    }

    public var isOn: Bool { albumId != nil }

    static let key = "lockScreenAlbum.settings"

    public static func load(_ database: AccountDatabase) -> LockScreenAlbumSettings {
        guard let json = try? database.syncValue(key), let data = json.data(using: .utf8) else { return LockScreenAlbumSettings() }
        return (try? JSONDecoder().decode(LockScreenAlbumSettings.self, from: data)) ?? LockScreenAlbumSettings()
    }

    func save(_ database: AccountDatabase) throws {
        try database.setSyncValue(Self.key, String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }
}

/// The device's own photo library as the mirror uses it: PhotoKit on iPhone and iPad, a fake in tests.
protocol DeviceLibrary: Sendable {
    /// Asks for access when needed; true when the app may add and manage its own copies (full or limited access).
    func requestAccess() async -> Bool
    /// Which of these assets still exist.
    func existing(_ identifiers: [String]) async -> Set<String>
    /// The album with this identifier, or a new one with this title; renamed when the title changed.
    func album(identifier: String?, title: String) async throws -> String
    /// Adds a photo to the library and the album; returns the new asset's identifier.
    func add(_ data: Data, created: Date?, latitude: Double?, longitude: Double?, album: String) async throws -> String
    func removeFromAlbum(_ identifiers: [String], album: String) async throws
    /// Deletes assets (and the album when given); the system asks the user. False when the user said no.
    func delete(_ identifiers: [String], album: String?) async -> Bool
}

/// What the mirror pass did, for the settings.
public struct LockScreenAlbumStatus: Equatable, Sendable {
    public var copies = 0
    public var lastRun: Date?
    public var error: String?
    public var running = false
    public var accessDenied = false
}

/// Mirrors one Nextcloud album into an album of the device's photo library ("Nextcloud: <name>"), so the Lock Screen's
/// Photo Shuffle and other system features can use it (SPEC §16.7.4). iPhone and iPad only.
///
/// Copies are 2048 px previews, at most `DeviceMirror.maximumPhotos`; videos, archived photos and photos with a person
/// hidden on this device are left out. A pass adds new photos without asking; taking copies away deletes them from the
/// device, which the system confirms — while the user has not confirmed, they are out of the album and wait.
@MainActor
@Observable
public final class LockScreenAlbumModel {
    public static var isSupported: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    public private(set) var settings: LockScreenAlbumSettings
    public private(set) var status = LockScreenAlbumStatus()
    @ObservationIgnored private let services: AccountServices
    @ObservationIgnored private let library: (any DeviceLibrary)?
    @ObservationIgnored private let hiddenPeople: @Sendable () -> Set<String>
    @ObservationIgnored private let refreshAlbum: @MainActor (Album) async -> Void
    @ObservationIgnored private var lastPass: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "lock-screen-album")

    init(
        services: AccountServices, library: (any DeviceLibrary)?, hiddenPeople: @escaping @Sendable () -> Set<String>,
        refreshAlbum: @escaping @MainActor (Album) async -> Void
    ) {
        self.services = services
        self.library = library
        self.hiddenPeople = hiddenPeople
        self.refreshAlbum = refreshAlbum
        settings = LockScreenAlbumSettings.load(services.database)
        status.copies = (try? FamilyStore(database: services.database).mirroredEntries().count) ?? 0
    }

    var store: FamilyStore { FamilyStore(database: services.database) }

    private func save() { try? settings.save(services.database) }

    /// Mirrors this album from now on (another one's copies are taken away).
    public func choose(_ album: Album) async {
        guard let library else { return }
        guard await library.requestAccess() else {
            status.accessDenied = true
            return
        }
        status.accessDenied = false
        let title = album.title.isEmpty ? album.name : album.title
        settings.albumId = album.id
        settings.albumTitle = title
        save()
        await sync(force: true, userInitiated: true)
    }

    /// Stops mirroring and deletes the copies and the device album (the system asks).
    public func turnOff() async {
        settings.albumId = nil
        save()
        await sync(force: true, userInitiated: true)
    }

    /// Deletes copies that are waiting for the user's confirmation.
    public func deletePending() async {
        await sync(force: true, userInitiated: true)
    }

    /// A pass: at most every 15 minutes unless forced. Only a pass the user started asks again about copies whose
    /// deletion the user declined before.
    public func sync(force: Bool = false, userInitiated: Bool = false) async {
        guard let library, !status.running else { return }
        if !force, let lastPass, Date().timeIntervalSince(lastPass) < 900 { return }
        guard settings.isOn || !settings.pendingDeletion.isEmpty || status.copies > 0 || settings.deviceAlbumIdentifier != nil else {
            return
        }
        lastPass = Date()
        status.running = true
        defer {
            status.running = false
            status.lastRun = Date()
        }
        do {
            try await pass(library, userInitiated: userInitiated)
            status.error = nil
        } catch {
            logger.error("pass: \(error.localizedDescription, privacy: .public)")
            status.error = error.localizedDescription
        }
        status.copies = (try? store.mirroredEntries().count) ?? 0
    }

    private func pass(_ library: any DeviceLibrary, userInitiated: Bool) async throws {
        var desired: [MediaItem] = []
        if let albumId = settings.albumId {
            guard let album = try services.collections.album(id: albumId) else {
                // The album is gone on the server: nothing to show any more.
                settings.albumId = nil
                save()
                return try await pass(library, userInitiated: userInitiated)
            }
            await refreshAlbum(album)
            let items = try await services.collections.albumMedia(albumId: albumId)
            let people = try store.people(of: items.map(\.fileId))
            desired = DeviceMirror.eligible(items, peopleOf: people, hiddenPeople: hiddenPeople())
        }
        let mirrored = try store.mirroredEntries()
        let present = await library.existing(mirrored.map(\.localIdentifier))
        let plan = DeviceMirror.plan(desired: desired.map { ($0.fileId, $0.etag) }, mirrored: mirrored, presentOnDevice: present)
        try store.removeMirrored(localIdentifiers: plan.forget.map(\.localIdentifier))
        if settings.isOn {
            let album = try await library.album(
                identifier: settings.deviceAlbumIdentifier, title: DeviceMirror.deviceAlbumTitle(settings.albumTitle))
            if album != settings.deviceAlbumIdentifier {
                settings.deviceAlbumIdentifier = album
                save()
            }
            let removing = plan.remove.map(\.localIdentifier)
            if !removing.isEmpty {
                try await library.removeFromAlbum(removing, album: album)
                try store.removeMirrored(localIdentifiers: removing)
                settings.pendingDeletion = Array(Set(settings.pendingDeletion + removing)).sorted()
                save()
            }
            let byId = Dictionary(desired.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            for fileId in plan.add {
                guard let item = byId[fileId] else { continue }
                try Task.checkCancellation()
                let data = try await services.api.preview(fileId: item.fileId, size: DeviceMirror.copyPixelSize, etag: item.etag)
                let identifier = try await library.add(
                    data, created: item.capturedAt ?? item.timestamp, latitude: item.latitude, longitude: item.longitude, album: album)
                try store.addMirrored(DeviceMirror.Entry(fileId: item.fileId, etag: item.etag, localIdentifier: identifier))
                status.copies += 1
            }
        } else {
            // Off: every copy goes, and the device album with them.
            let all = mirrored.filter { present.contains($0.localIdentifier) }.map(\.localIdentifier)
            try store.removeMirrored(localIdentifiers: mirrored.map(\.localIdentifier))
            settings.pendingDeletion = Array(Set(settings.pendingDeletion + all)).sorted()
            save()
        }
        guard !settings.pendingDeletion.isEmpty || (!settings.isOn && settings.deviceAlbumIdentifier != nil) else { return }
        let waiting = Array(await library.existing(settings.pendingDeletion)).sorted()
        let album = settings.isOn ? nil : settings.deviceAlbumIdentifier
        if waiting.isEmpty && album == nil {
            settings.pendingDeletion = []
            settings.declinedDeletion = []
            save()
            return
        }
        settings.pendingDeletion = waiting
        // Nothing new since the user said no: wait until the user asks (Settings) instead of asking again.
        guard userInitiated || !Set(waiting).isSubset(of: Set(settings.declinedDeletion)) else {
            save()
            return
        }
        if await library.delete(waiting, album: album) {
            settings.pendingDeletion = []
            settings.declinedDeletion = []
            if !settings.isOn { settings.deviceAlbumIdentifier = nil }
        } else {
            settings.declinedDeletion = waiting
        }
        save()
    }
}

#if os(iOS)
    /// PhotoKit. Creating and managing an album needs access to the library; limited access is enough, because the app
    /// only ever touches the copies it made itself (they join the limited selection when they are created).
    struct PhotoKitDeviceLibrary: DeviceLibrary {
        func requestAccess() async -> Bool {
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            return status == .authorized || status == .limited
        }

        func existing(_ identifiers: [String]) async -> Set<String> {
            guard !identifiers.isEmpty else { return [] }
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var found: Set<String> = []
            result.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
            return found
        }

        func album(identifier: String?, title: String) async throws -> String {
            if let identifier,
                let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
            {
                if collection.localizedTitle != title {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCollectionChangeRequest(for: collection)?.title = title
                    }
                }
                return identifier
            }
            let created = Mutex<String?>(nil)
            try await PHPhotoLibrary.shared().performChanges {
                let identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    .placeholderForCreatedAssetCollection.localIdentifier
                created.withLock { $0 = identifier }
            }
            guard let identifier = created.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
            return identifier
        }

        func add(_ data: Data, created: Date?, latitude: Double?, longitude: Double?, album: String) async throws -> String {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
                throw CocoaError(.fileNoSuchFile)
            }
            let result = Mutex<String?>(nil)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                request.creationDate = created
                if let latitude, let longitude { request.location = CLLocation(latitude: latitude, longitude: longitude) }
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                result.withLock { $0 = placeholder.localIdentifier }
                PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
            }
            guard let identifier = result.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
            return identifier
        }

        func removeFromAlbum(_ identifiers: [String], album: String) async throws {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
                return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            guard assets.count > 0 else { return }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: collection)?.removeAssets(assets)
            }
        }

        func delete(_ identifiers: [String], album: String?) async -> Bool {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            let collections = album.map { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil) }
            guard assets.count > 0 || (collections?.count ?? 0) > 0 else { return true }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if assets.count > 0 { PHAssetChangeRequest.deleteAssets(assets) }
                    if let collections, collections.count > 0 { PHAssetCollectionChangeRequest.deleteAssetCollections(collections) }
                }
                return true
            } catch {
                // The user said "Don't Allow" (or the library refused): the copies stay until the next try.
                return false
            }
        }
    }
#endif
