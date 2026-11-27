// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosStore

/// The device layer in the Library's timeline (SPEC §21.1): device photos as grid rows, merged by capture time into the
/// server's rows. Pure and off the main actor; 100 000 + 100 000 rows merge in one pass.
public enum DeviceTimeline {
    /// The device photos a timeline of this kind shows: the Library and its Photos, Videos and Favorites filters. Other
    /// filters (archive, places, albums…) are about server files and show none.
    public static func assets(_ snapshot: DeviceLayerSnapshot, kind: MediaFilter) -> [DeviceAsset] {
        switch kind {
        case .all: snapshot.assets
        case .photos: snapshot.assets.filter { !$0.item.isVideo }
        case .videos: snapshot.assets.filter(\.item.isVideo)
        case .favorites: snapshot.assets.filter(\.item.isFavorite)
        default: []
        }
    }

    /// The grid row of a device photo.
    public static func gridMedia(_ asset: DeviceAsset) -> GridMedia {
        var media = GridMedia(mediaItem(asset))
        media.isLivePhoto = asset.item.isLivePhoto
        media.deviceBadge = asset.badge
        media.burstIdentifier = asset.item.burstIdentifier
        // A name of its own: the timeline's copy stacks group equal names in one folder, and device photos are never
        // copies of each other (bursts stack by `burstIdentifier`).
        media.name = "device-\(asset.id.magnitude)"
        return media
    }

    /// A device photo as a `MediaItem`, for the parts that show one (viewer page, info). It has no path on the server:
    /// `directory` marks it, and nothing that needs a server file is offered for it.
    public static func mediaItem(_ asset: DeviceAsset) -> MediaItem {
        let item = asset.item
        return MediaItem(
            fileId: asset.id, path: directory + "/" + item.localIdentifier.replacingOccurrences(of: "/", with: "-"), name: "",
            mimeType: item.isVideo ? "video/quicktime" : "image/heic", kind: item.isVideo ? .video : .image,
            etag: Self.etag, modifiedAt: item.createdAt, capturedAt: item.createdAt,
            width: item.pixelWidth > 0 ? item.pixelWidth : nil, height: item.pixelHeight > 0 ? item.pixelHeight : nil,
            isFavorite: item.isFavorite, permissions: Permissions(rawValue: ""), mountType: mountType, hasPreview: true,
            duration: item.isVideo && item.duration > 0 ? item.duration : nil)
    }

    /// Where device photos are, in place of a server folder: no server path starts like this.
    public static let directory = "/.device"
    /// `MediaItem.mountType` of a device photo.
    public static let mountType = "device"
    /// The ETag of every device photo's picture: PhotoKit's picture of an asset is the same for a launch, whatever its
    /// backup state.
    public static let etag = "device"

    /// The server's rows (newest first, as the timeline query returns them) with the device's merged in by capture time.
    ///
    /// A device photo the backup has not looked at yet (`DeviceAsset.isUnchecked`) whose capture second and kind are
    /// those of a server photo is left out: it is most likely that photo, uploaded by another app before backup's first
    /// pass, and showing it twice would be wrong. It still counts as not backed up until the backup confirms it; a
    /// photo the backup checked and did not find on the server is always shown.
    public static func merge(server: [GridMedia], device: [DeviceAsset]) -> [GridMedia] {
        guard !device.isEmpty else { return server }
        var serverSeconds = Set<Int64>()
        if device.contains(where: \.isUnchecked) {
            serverSeconds.reserveCapacity(server.count)
            for item in server { serverSeconds.insert(secondKey(item.timestamp, isVideo: item.kind == .video)) }
        }
        var result: [GridMedia] = []
        result.reserveCapacity(server.count + device.count)
        var serverIndex = 0
        for asset in device {
            if asset.isUnchecked, serverSeconds.contains(secondKey(asset.item.createdAt, isVideo: asset.item.isVideo)) { continue }
            // Ties: the server's photo first.
            while serverIndex < server.count, server[serverIndex].timestamp >= asset.item.createdAt {
                result.append(server[serverIndex])
                serverIndex += 1
            }
            result.append(gridMedia(asset))
        }
        if serverIndex < server.count { result.append(contentsOf: server[serverIndex...]) }
        return result
    }

    static func secondKey(_ date: Date, isVideo: Bool) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down)) * 2 + (isVideo ? 1 : 0)
    }
}
