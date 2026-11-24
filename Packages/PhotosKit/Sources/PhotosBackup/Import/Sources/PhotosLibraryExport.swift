// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Photos
import PhotosModel

/// The Mac's Photos library as an import source (SPEC §15.7): every photo and video of the user's own library (with
/// originals kept in iCloud, downloaded one at a time while importing), the resources the backup would choose
/// (`PhotoLibrarySource.select`: original and edited version, RAW, the video of a Live Photo), favourites, hidden photos,
/// and the user's albums, also those inside folders. Captions are not available through PhotoKit.
public struct PhotosLibraryExport: Sendable {
    public init() {}

    /// What the import takes of each asset: the backup's default choice.
    static var settings: BackupSettings {
        var settings = BackupSettings()
        settings.includeHidden = true
        settings.edits = .originalAndEdited
        settings.livePhotos = true
        return settings
    }

    public static var isAuthorized: Bool {
        let status = PhotoLibrarySource.authorization
        return status == .authorized || status == .limited
    }

    /// The library's items and albums. Reads PhotoKit's records only (no image data); a large library takes a while.
    public func read(progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> (items: [ImportItem], albums: [ImportAlbum]) {
        let library = PhotoLibrarySource()
        let settings = Self.settings
        let assets = library.assets(settings)
        var albumsOfAsset: [String: [String]] = [:]
        var albums: [ImportAlbum] = []
        for (title, identifiers) in userAlbums() {
            guard !identifiers.isEmpty else { continue }
            albums.append(ImportAlbum(title: title, source: .photosLibrary))
            for identifier in identifiers { albumsOfAsset[identifier, default: []].append(title) }
        }
        var items: [ImportItem] = []
        items.reserveCapacity(assets.count)
        for (offset, asset) in assets.enumerated() {
            if offset % 200 == 0 {
                try Task.checkCancellation()
                progress?(offset, assets.count)
            }
            var metadata = ImportMetadata(
                takenAt: asset.creationDate, latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude, favorite: asset.isFavorite, hidden: asset.isHidden)
            if let altitude = asset.location?.altitude, altitude != 0 { metadata.altitude = altitude }
            for (resource, _) in library.resources(of: asset, settings: settings) {
                items.append(
                    ImportItem(
                        id: "photosLibrary|\(resource.localIdentifier)|\(resource.kind.rawValue)", origin: .asset(resource),
                        name: resource.originalName, size: UInt64(max(resource.byteSize ?? 0, 0)), kind: resource.mediaKind,
                        source: .photosLibrary, metadata: metadata, albums: albumsOfAsset[asset.localIdentifier] ?? []))
            }
        }
        progress?(assets.count, assets.count)
        return (items, albums)
    }

    /// The user's own albums with the assets in them, folders walked (an album's name is its own title).
    func userAlbums() -> [(String, [String])] {
        var result: [(String, [String])] = []
        func visit(_ collections: PHFetchResult<PHCollection>) {
            collections.enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection, album.assetCollectionSubtype == .albumRegular {
                    var identifiers: [String] = []
                    PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
                    result.append((album.localizedTitle ?? "", identifiers))
                } else if let folder = collection as? PHCollectionList {
                    visit(PHCollection.fetchCollections(in: folder, options: nil))
                }
            }
        }
        visit(PHCollection.fetchTopLevelUserCollections(with: nil))
        return result.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
