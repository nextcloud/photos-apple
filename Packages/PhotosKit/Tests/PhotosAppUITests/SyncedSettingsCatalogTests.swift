// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import Testing

@testable import PhotosAppUI

/// The settings that follow the user (SPEC §22.5.2) are named in PhotosCore by their `UserDefaults` keys: they must be
/// the keys the screens use, or a renamed key would silently stop syncing.
@Suite @MainActor struct SyncedSettingsCatalogTests {
    @Test func catalogNamesTheKeysTheScreensUse() {
        let synced = Set(SyncedDefaultsCatalog.items.map(\.defaultsKey))
        let used = [
            TimelineDisplay.showsMemoriesKey, MemoriesStyle.key, TimelineDisplay.showsMomentsKey, TileStyle.squareTilesKey,
            TimelineDisplay.stackCopiesKey, LookSettings.backdropKey, LookSettings.headerTintKey, LookSettings.liveCoversKey,
            SlideshowSettings.intervalKey, SlideshowSettings.repeatsKey, FilmChoiceStore.key, BirthdayStore.key("{account}"),
            CullingSettings.autoAdvanceKey, LoupeSettings.peakingKey, LoupeSettings.clippingKey, LoupeSettings.histogramKey,
            PhotoEditSaving.applyToFileKey, CardImportSettings.patternKey,
            // `@AppStorage` with a literal key.
            "throughTheYearsSpeed", "batchRenamePattern", "albumsSortOrder", "albumPhotosSortOrder",
        ]
        #expect(Set(used) == synced)
        // Settings of the device are never in it.
        for key in [AdvancedFeatures.storageKey, "gridColumns", SyncedDefaults.enabledKey] { #expect(!synced.contains(key)) }
    }
}
