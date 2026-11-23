// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

@Suite struct GridLayoutTests {
    let macOptions = [3, 4, 5, 6, 8, 10, 12, 16]

    @Test func columnsFollowTheWidthNotTheZoomStep() {
        // Default Mac step: 8 columns in the default window …
        let target = GridZoom.targetSide(step: 8, referenceWidth: 1056, spacing: 2)
        let normal = GridGeometry.fitting(width: 1056, targetSide: target, spacing: 2)
        #expect(normal.columns == 8)
        // … and more columns of the same size in a wide one, instead of 8 huge tiles.
        let wide = GridGeometry.fitting(width: 1934, targetSide: target, spacing: 2)
        #expect(wide.columns == 15)
        #expect(abs(wide.side - normal.side) < normal.side * 0.1)
        // Tiles always fill the width exactly.
        #expect(abs(Double(wide.columns) * wide.side + Double(wide.columns - 1) * 2 - 1934) < 0.001)
    }

    @Test func everyStepGivesItsColumnsAtTheReferenceWidth() {
        for step in macOptions {
            let target = GridZoom.targetSide(step: step, referenceWidth: 1056, spacing: 2)
            #expect(GridGeometry.fitting(width: 1056, targetSide: target, spacing: 2).columns == step)
        }
        for step in [1, 3, 5, 7, 9, 13] {
            let target = GridZoom.targetSide(step: step, referenceWidth: 390, spacing: 1)
            #expect(GridGeometry.fitting(width: 390, targetSide: target, spacing: 1).columns == step)
        }
    }

    @Test func degenerateWidths() {
        #expect(GridGeometry.fitting(width: 0, targetSide: 100, spacing: 2).columns == 1)
        #expect(GridGeometry.fitting(width: 40, targetSide: 130, spacing: 2).columns == 1)
        #expect(GridGeometry.fitting(width: 500, targetSide: 0, spacing: 2).columns == 1)
    }

    @Test func zoomSteps() {
        #expect(GridZoom.step(8, in: macOptions, zoomIn: true) == 6)
        #expect(GridZoom.step(8, in: macOptions, zoomIn: false) == 10)
        #expect(GridZoom.step(3, in: macOptions, zoomIn: true) == 3)
        #expect(GridZoom.step(16, in: macOptions, zoomIn: false) == 16)
        // A stored value that is not a step (older version, other platform) snaps to the next one.
        #expect(GridZoom.step(7, in: macOptions, zoomIn: false) == 10)
    }

    @Test func granularityFollowsZoom() {
        #expect(macOptions.map { GridZoom.granularity(step: $0, in: macOptions) } == [.day, .day, .day, .day, .day, .month, .month, .year])
        let phone = [1, 3, 5, 7, 9, 13]
        #expect(phone.map { GridZoom.granularity(step: $0, in: phone) } == [.day, .day, .day, .month, .month, .year])
    }

    @Test func sectionHeightsAndOffsets() {
        let geometry = GridGeometry(columns: 4, side: 100, spacing: 2)
        #expect(geometry.rows(forItems: 0) == 0)
        #expect(geometry.rows(forItems: 4) == 1)
        #expect(geometry.rows(forItems: 5) == 2)
        #expect(geometry.height(forItems: 5) == 202)
        let offsets = geometry.sectionOffsets(itemCounts: [5, 1, 9], headerHeights: [60, 30, 30])
        #expect(offsets == [0, 262, 392, 726])
        #expect(GridGeometry.section(at: 0, in: offsets) == 0)
        #expect(GridGeometry.section(at: 261, in: offsets) == 0)
        #expect(GridGeometry.section(at: 262, in: offsets) == 1)
        #expect(GridGeometry.section(at: 500, in: offsets) == 2)
        #expect(GridGeometry.section(at: 99_999, in: offsets) == 2)
        #expect(GridGeometry.section(at: -5, in: offsets) == 0)
        #expect(GridGeometry.section(at: 0, in: []) == nil)
    }

    /// The review's case: 8 columns in a 1200 pt Retina window are 262 px tiles, which got the 256 px bucket; the
    /// server preview is aspect-fit, so a 4:3 photo had only 192 px for them.
    @Test func previewBucketCoversTheTileInPixels() {
        func bucket(_ side: Double, _ scale: Double, _ aspect: Double) -> Int {
            PreviewSizing.bucket(forPixels: PreviewSizing.neededPixels(tileSide: side, scale: scale, aspectRatio: aspect))
        }
        #expect(bucket(131, 2, 4.0 / 3) == 1024)
        #expect(bucket(131, 2, 3.0 / 4) == 1024)
        // A square photo in the same tile is covered by 256 px (within the tolerance).
        #expect(bucket(131, 2, 1) == 256)
        // The same tile on a 1× display needs a quarter of the pixels.
        #expect(bucket(131, 1, 4.0 / 3) == 256)
        // Smallest Mac tiles (66 pt, Retina).
        #expect(bucket(66, 2, 4.0 / 3) == 256)
        #expect(bucket(20, 1, 1) == 64)
        // Largest tiles in a wide window.
        #expect(bucket(350, 2, 1.5) == 1024)
        #expect(bucket(700, 2, 1.5) == 4096)
    }

    /// Album covers of ~170 pt looked soft with the 256 preview on a 2× screen.
    @Test func albumCoversGetAPreviewForTheirPixelSize() {
        #expect(PreviewSizing.coverBucket(side: 170, scale: 2) == 1024)
        #expect(PreviewSizing.coverBucket(side: 170, scale: 1) == 256)
        #expect(PreviewSizing.coverBucket(side: 44, scale: 2) == 256)
        #expect(PreviewSizing.coverBucket(side: 900, scale: 3) == 4096)
    }

    @Test func previewSizingEdgeCases() {
        // A panorama does not pull the next bucket: the factor is capped.
        #expect(PreviewSizing.neededPixels(tileSide: 100, scale: 2, aspectRatio: 6) == 400)
        // Unknown or broken ratios count as square.
        #expect(PreviewSizing.neededPixels(tileSide: 100, scale: 2, aspectRatio: 0) == 200)
        #expect(PreviewSizing.neededPixels(tileSide: 100, scale: 2, aspectRatio: .nan) == 200)
        #expect(PreviewSizing.bucket(forPixels: 100_000) == 4096)
        // Exactly the bucket ≥ what is needed, no rounding down beyond the tolerance.
        #expect(PreviewSizing.bucket(forPixels: 284) == 256)
        #expect(PreviewSizing.bucket(forPixels: 286) == 1024)
    }

    @Test func previewsAreDecodedAtTheTileSizeNotTheBucketSize() {
        // A 200 pt Retina tile of a 4:3 photo needs 533 px: the 1024 bucket is fetched, decoded at 576 px.
        let pixels = PreviewSizing.neededPixels(tileSide: 200, scale: 2, aspectRatio: 4.0 / 3)
        let bucket = PreviewSizing.bucket(forPixels: pixels)
        #expect(bucket == 1024)
        #expect(PreviewSizing.decodePixels(forPixels: pixels, bucket: bucket) == 576)
        // A few points more or less give the same size (no new decode while a window is resized).
        #expect(PreviewSizing.decodePixels(forPixels: 520, bucket: 1024) == 576)
        #expect(PreviewSizing.decodePixels(forPixels: 576, bucket: 1024) == 576)
        // Never more than the bucket, never less than one step.
        #expect(PreviewSizing.decodePixels(forPixels: 1100, bucket: 1024) == 1024)
        #expect(PreviewSizing.decodePixels(forPixels: 3, bucket: 64) == 64)
        #expect(PreviewSizing.decodePixels(forPixels: .nan, bucket: 256) == 256)
    }

    @Test func emptyStateOnlyAfterAFinishedFirstSync() {
        func phase(loaded: Bool = true, waits: Bool = true, running: Bool = false, synced: Bool = false, stopped: Bool = false)
            -> GridEmptyPhase
        {
            GridEmptyPhase.phase(
                feedLoaded: loaded, waitsForFirstSync: waits, firstSyncRunning: running, hasSyncedBefore: synced, syncStopped: stopped)
        }
        // Cold start: nothing synced yet, the sync has not even reported that it started.
        #expect(phase() == .loading)
        #expect(phase(running: true) == .loading)
        #expect(phase(loaded: false, synced: true) == .loading)
        // The library is really empty.
        #expect(phase(synced: true) == .empty)
        // Offline or failed before anything was synced: say so instead of loading forever.
        #expect(phase(stopped: true) == .empty)
        // Albums, search results: empty as soon as the local query says so, whatever the sync does.
        #expect(phase(waits: false, running: true) == .empty)
        #expect(phase(loaded: false, waits: false) == .loading)
    }
}
