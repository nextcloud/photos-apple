// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Keeping a copy of one Nextcloud album in the device's own photo library, for the Lock Screen's Photo Shuffle
/// (SPEC §16.7.4). This part decides what to copy and what to take away; the app carries it out with PhotoKit.
public enum DeviceMirror {
    /// A photo copied to the device: which file in which version, and the device asset that holds it.
    public struct Entry: Codable, Hashable, Sendable {
        public var fileId: FileID
        public var etag: String
        public var localIdentifier: String

        public init(fileId: FileID, etag: String, localIdentifier: String) {
            self.fileId = fileId
            self.etag = etag
            self.localIdentifier = localIdentifier
        }
    }

    /// What a pass does. A photo edited on the server is taken away in its old version and copied again.
    public struct Plan: Equatable, Sendable {
        /// Photos to copy, in the album's order.
        public var add: [FileID] = []
        /// Copies to take out of the album and delete from the device.
        public var remove: [Entry] = []
        /// Copies the user deleted on the device: forgotten (and copied again when the photo is still wanted).
        public var forget: [Entry] = []

        public init(add: [FileID] = [], remove: [Entry] = [], forget: [Entry] = []) {
            self.add = add
            self.remove = remove
            self.forget = forget
        }

        public var isEmpty: Bool { add.isEmpty && remove.isEmpty && forget.isEmpty }
    }

    /// Lock Screen shuffles between a few photos; a few hundred are plenty and keep the copies small on the device.
    public static let maximumPhotos = 300
    /// The long edge of a copy: sharp on every iPhone and iPad screen, without the original's size.
    public static let copyPixelSize = 2048

    /// The photos of the album that may be copied: photos (no videos, no Live Photo motion parts), not archived, none
    /// with a person hidden on this device; at most `maximumPhotos`, in the album's order.
    public static func eligible(_ items: [MediaItem], peopleOf: [FileID: Set<String>], hiddenPeople: Set<String>) -> [MediaItem] {
        var seen: Set<FileID> = []
        var result: [MediaItem] = []
        for item in items where item.kind == .image && !item.isLivePhotoVideo && !item.isArchived && item.hasPreview {
            if let people = peopleOf[item.fileId], !people.isDisjoint(with: hiddenPeople) { continue }
            guard seen.insert(item.fileId).inserted else { continue }
            result.append(item)
            if result.count == maximumPhotos { break }
        }
        return result
    }

    /// Compares what should be on the device with what is there.
    ///
    /// - Parameters:
    ///   - desired: the eligible photos with their current ETag, in order.
    ///   - mirrored: the copies made before.
    ///   - presentOnDevice: the local identifiers of those copies that still exist in the device's library.
    public static func plan(desired: [(fileId: FileID, etag: String)], mirrored: [Entry], presentOnDevice: Set<String>) -> Plan {
        var plan = Plan()
        var current: [FileID: Entry] = [:]
        for entry in mirrored {
            if !presentOnDevice.contains(entry.localIdentifier) {
                plan.forget.append(entry)
            } else if current[entry.fileId] != nil {
                // A second copy of the same photo (a pass that was interrupted): one is enough.
                plan.remove.append(entry)
            } else {
                current[entry.fileId] = entry
            }
        }
        let wanted = Dictionary(desired.map { ($0.fileId, $0.etag) }, uniquingKeysWith: { first, _ in first })
        for (fileId, entry) in current where wanted[fileId] != entry.etag {
            plan.remove.append(entry)
        }
        for photo in desired where current[photo.fileId]?.etag != photo.etag && !plan.add.contains(photo.fileId) {
            plan.add.append(photo.fileId)
        }
        plan.remove.sort { $0.localIdentifier < $1.localIdentifier }
        plan.forget.sort { $0.localIdentifier < $1.localIdentifier }
        return plan
    }

    /// The device album's name: "Nextcloud: Summer 2026".
    public static func deviceAlbumTitle(_ albumTitle: String) -> String {
        String(
            localized: "Nextcloud: \(albumTitle)", bundle: .module,
            comment: "Name of the album in the device's Photos library that mirrors a Nextcloud album for the Lock Screen.")
    }
}
