// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosAppUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The photographer's tools (SPEC §15.2): compare view geometry, tile badges, auto-advance, Edit With saving rules.
struct PhotographerToolsTests {
    // MARK: Compare

    @Test func compareLayouts() {
        #expect(CompareLayout.grid(count: 2, size: CGSize(width: 1200, height: 800)) == (2, 1))
        #expect(CompareLayout.grid(count: 2, size: CGSize(width: 600, height: 900)) == (1, 2))
        #expect(CompareLayout.grid(count: 3, size: CGSize(width: 1200, height: 800)) == (2, 2))
        #expect(CompareLayout.grid(count: 4, size: CGSize(width: 1200, height: 800)) == (2, 2))
    }

    @Test func actualPixelsZoom() {
        // A 6000 × 4000 photo in a 600 × 400 pane on a 2× screen: fit is 0.1 points per pixel, 100 % is 0.5.
        let zoom = CompareLayout.actualPixelsZoom(
            pixels: CGSize(width: 6000, height: 4000), area: CGSize(width: 600, height: 400), displayScale: 2)
        #expect(abs(zoom - 5) < 0.0001)
        // A small photo is never shown smaller than fitting.
        #expect(
            CompareLayout.actualPixelsZoom(pixels: CGSize(width: 100, height: 100), area: CGSize(width: 600, height: 400), displayScale: 2)
                == 1)
        #expect(
            CompareLayout.pixelsNeeded(zoom: 5, fitScale: 0.1, pixels: CGSize(width: 6000, height: 4000), displayScale: 2) == 6000)
    }

    @Test func panStaysInsideThePicture() {
        let area = CGSize(width: 600, height: 400)
        // Not zoomed: always the middle.
        #expect(CompareLayout.clampedCenter(CGPoint(x: 0.9, y: 0.1), shown: area, area: area) == CGPoint(x: 0.5, y: 0.5))
        // Twice as large: the centre can go from 1/4 to 3/4.
        let shown = CGSize(width: 1200, height: 800)
        #expect(CompareLayout.clampedCenter(CGPoint(x: 0.9, y: 0.1), shown: shown, area: area) == CGPoint(x: 0.75, y: 0.25))
        #expect(CompareLayout.clampedCenter(CGPoint(x: 0.6, y: 0.4), shown: shown, area: area) == CGPoint(x: 0.6, y: 0.4))
    }

    // MARK: Grid

    @Test func tileBadges() {
        let rejected = CullingTileBadge(CullingMark(rating: 2, flag: .reject), tileSide: 120)
        #expect(rejected.isDimmed && rejected.flagSymbol == "xmark" && rejected.stars == "★★")
        #expect(rejected.accessibilityText != nil)
        // Zoomed far out: the flag stays, the stars go.
        let small = CullingTileBadge(CullingMark(rating: 4, flag: .pick), tileSide: 40)
        #expect(small.stars.isEmpty && small.flagSymbol == "flag.fill" && !small.isDimmed)
        #expect(CullingTileBadge(.none, tileSide: 120).isHidden)
    }

    @Test func autoAdvanceGoesThroughSections() {
        let counts = [2, 0, 3]
        #expect(
            GridNavigation.indexPath(after: IndexPath(item: 0, section: 0), sectionCount: 3) { counts[$0] }
                == IndexPath(item: 1, section: 0))
        // Empty sections are passed over.
        #expect(
            GridNavigation.indexPath(after: IndexPath(item: 1, section: 0), sectionCount: 3) { counts[$0] }
                == IndexPath(item: 0, section: 2))
        #expect(GridNavigation.indexPath(after: IndexPath(item: 2, section: 2), sectionCount: 3) { counts[$0] } == nil)
    }

    // MARK: Edit With

    @Test func editedCopyNames() {
        #expect(ExternalEditSaving.copyName(for: "IMG_1.JPG", savedAs: URL(filePath: "/t/IMG_1.JPG")) == "IMG_1 (edited).JPG")
        // Saved in another format (Photoshop's TIFF of a RAW).
        #expect(ExternalEditSaving.copyName(for: "IMG_1.CR3", savedAs: URL(filePath: "/t/IMG_1.tif")) == "IMG_1 (edited).tif")
    }

    @Test func aSaveIsUploadedOnceItHasSettled() {
        typealias Snapshot = ExternalEditSaving.Snapshot
        let original = Snapshot(modified: Date(timeIntervalSince1970: 1), size: 100)
        let saving = Snapshot(modified: Date(timeIntervalSince1970: 5), size: 40)
        let saved = Snapshot(modified: Date(timeIntervalSince1970: 6), size: 120)
        // Unchanged: nothing to upload.
        #expect(!ExternalEditSaving.isSettledSave(uploaded: original, previous: original, current: original))
        // Being written: wait for the next look.
        #expect(!ExternalEditSaving.isSettledSave(uploaded: original, previous: saving, current: saved))
        #expect(ExternalEditSaving.isSettledSave(uploaded: original, previous: saved, current: saved))
        // Gone for a moment (an app swapping in its saved file), or empty: wait.
        #expect(!ExternalEditSaving.isSettledSave(uploaded: original, previous: nil, current: nil))
        #expect(
            !ExternalEditSaving.isSettledSave(
                uploaded: original, previous: Snapshot(modified: nil, size: 0), current: Snapshot(modified: nil, size: 0)))
    }

    // MARK: Import

    @Test func exifDatesAreLocalTime() {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let date = CardThumbnails.exifDate("2026:11:24 18:30:05", timeZone: zone)
        #expect(date == Date(timeIntervalSince1970: 1_795_541_405))
        #expect(CardThumbnails.exifDate("not a date") == nil)
    }
}
