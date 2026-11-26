// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain

/// Per-size budgets and the free-space default of the preview cache (SPEC §18.2).
extension CacheLimits {
    /// `UserDefaults.standard` key (Bool) of "Keep thumbnails of the whole library" (SPEC §18.3; its default and its
    /// setting belong to the library-thumbnail filler). When true, a trim never removes the 64 and 256 px previews of
    /// photos that are still in the library, and they do not count towards the limit.
    public static let wholeLibraryThumbnailsKey = "cacheWholeLibraryThumbnails"

    /// Whether the whole library's thumbnails are kept, with the platform's default when unset (on on the Mac; SPEC
    /// §18.3.1). Read the key through `LibraryThumbnailSettings.isEnabled` everywhere.
    public static func keepsWholeLibraryThumbnails(_ defaults: UserDefaults = .standard) -> Bool {
        LibraryThumbnailSettings.isEnabled(defaults)
    }

    /// The preview cache's limit when the user has not set one: a twentieth of the free space (2 GB with 40 GB free),
    /// at least 512 MB and at most 4 GB. Without a free-space figure: `defaultPreviewBytes`.
    public static func defaultPreviewBytes(availableBytes: Int64?) -> Int64 {
        guard let availableBytes, availableBytes > 0 else { return defaultPreviewBytes }
        return min(max(availableBytes / 20, minimumPreviewBytes), maximumPreviewBytes)
    }

    public static let minimumPreviewBytes: Int64 = 512 * 1024 * 1024
    public static let maximumPreviewBytes: Int64 = 4 * 1024 * 1024 * 1024

    /// Free space for caches on the volume of `url` (the app's container): what the system would give to data that can be
    /// downloaded again ("opportunistic" usage), nil when it cannot tell.
    public static func availableDiskBytes(at url: URL = URL.homeDirectory) -> Int64? {
        #if os(tvOS)
            // tvOS has no "opportunistic" figure (its caches may be purged at any time anyway).
            return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #else
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey, .volumeAvailableCapacityKey])
            if let bytes = values?.volumeAvailableCapacityForOpportunisticUsage, bytes > 0 { return bytes }
            return values?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// How the preview limit is shared between thumbnails, screen-size and large previews.
    public var previewPools: CachePoolBudgets { CachePoolBudgets(total: previewBytes) }
}
