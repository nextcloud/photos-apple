// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Photos and videos of this device that are not on the server yet stand in the Library next to the server's photos
/// (SPEC §21.1). They have no server file id; they get a negative one, derived from PhotoKit's local identifier. Server
/// file ids are positive, so the two never meet, and the same device photo has the same id in every launch.
public enum DeviceMediaID {
    /// The id of a device photo: FNV-1a (64 bit) of its local identifier, made negative. Deterministic (unlike
    /// `Hasher`), so selections, the viewer and the grid's index agree across launches. At 100 000 photos a collision is
    /// about one in two billion; the layer drops the second photo of a collision rather than mixing them up.
    public static func id(for localIdentifier: String) -> FileID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in localIdentifier.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // -1 … -2^63: never 0, never positive.
        return -Int64(hash & 0x7fff_ffff_ffff_ffff) - 1
    }

    /// The id stands for a photo of this device, not a file on the server.
    public static func isDevice(_ id: FileID) -> Bool { id < 0 }
}

/// What the Library's tile of a device photo says about its backup (SPEC §21.1).
public enum DeviceBackupBadge: UInt8, Sendable, Hashable, Codable {
    /// Not on the server yet; the backup gets to it (or it is not turned on).
    case waiting
    /// Being uploaded right now, or handed to the system for it.
    case uploading
    /// Its upload failed; it is tried again later.
    case failed
    /// Its original is only in iCloud and "Download originals from iCloud" is off.
    case onlyInICloud

    /// SF Symbol of the badge: a cloud with a slash, an arrow while it uploads.
    public var systemImage: String {
        switch self {
        case .waiting: "icloud.slash"
        case .uploading: "icloud.and.arrow.up"
        case .failed: "exclamationmark.icloud"
        case .onlyInICloud: "icloud.and.arrow.down"
        }
    }
}
