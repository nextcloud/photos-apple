// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import PhotosModel

/// Photos that Apple Vision Pro shows in more than a flat window (SPEC §6.2 visionOS specifics, M5): spatial photos (a
/// HEIC with a stereo pair, taken with iPhone 15 Pro or later or with Vision Pro) and panoramas.
///
/// A panorama is recognised from the size the server reports; a spatial photo only from the file itself (the stereo pair
/// group in its image properties), so the original is read on Vision Pro when a HEIC is viewed.
public enum SpatialMedia {
    /// Wider than this (width ÷ height) is a panorama. iPhone panoramas are about 3:1 to 5:1; 2:1 also takes
    /// equirectangular 360° photos.
    public static let panoramaAspect = 2.0
    /// Narrower panoramas are mostly banners and screenshots.
    public static let panoramaMinimumWidth = 3000

    /// From the item's metadata: a wide, large still image.
    public static func isPanorama(_ item: MediaItem) -> Bool {
        guard item.kind == .image, let width = item.width, let height = item.height, height > 0 else { return false }
        return width >= panoramaMinimumWidth && Double(width) / Double(height) >= panoramaAspect
    }

    /// Only a HEIC (HEIF) can carry a stereo pair.
    public static func maySpatial(_ item: MediaItem) -> Bool {
        guard item.kind == .image, !item.isLivePhotoVideo else { return false }
        let type = item.mimeType.lowercased()
        return type == "image/heic" || type == "image/heif" || type == "image/heic-sequence"
    }

    /// The image properties name a stereo pair group (`kCGImagePropertyGroups`, type `StereoPair`, with a left and a right
    /// image).
    public static func isStereoPair(properties: [CFString: Any]) -> Bool {
        guard let groups = properties[kCGImagePropertyGroups] as? [[CFString: Any]] else { return false }
        return groups.contains { group in
            guard let type = group[kCGImagePropertyGroupType] as? String, type == (kCGImagePropertyGroupTypeStereoPair as String)
            else { return false }
            return group[kCGImagePropertyGroupImageIndexLeft] != nil && group[kCGImagePropertyGroupImageIndexRight] != nil
        }
    }

    /// Reads the properties of a downloaded file.
    public static func isStereoPair(file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) >= 2,
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        else { return false }
        return isStereoPair(properties: properties)
    }

    /// How far around the viewer a panorama reaches, in radians: its aspect times a vertical field of view of 60°, at most
    /// all the way round.
    public static func panoramaArc(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return .pi / 2 }
        return min(2 * .pi, Double(width) / Double(height) * (.pi / 3))
    }
}
