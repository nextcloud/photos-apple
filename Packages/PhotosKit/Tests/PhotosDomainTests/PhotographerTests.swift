// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// Insights' EXIF parsing, scales, filters and summary (SPEC §16.5.1).
@Suite struct PhotoInsightsTests {
    /// Tags as a stock server returned them for a photo of the test library.
    static let nikon: [String: String] = [
        "Make": "NIKON CORPORATION", "Model": "NIKON D700", "ExposureTime": "1/1000", "FNumber": "2/1", "ISOSpeedRatings": "125",
        "DateTimeOriginal": "2011:03:05 05:38:14", "FocalLength": "350/10",
    ]

    @Test func parsesAServerRecord() {
        let facts = ExifFacts.parse(Self.nikon)
        #expect(facts.camera == "Nikon D700")
        #expect(facts.lens == nil)
        #expect(facts.focalLength == 35)
        #expect(facts.chartFocalLength == 35)
        #expect(facts.aperture == 2)
        #expect(facts.iso == 125)
        #expect(facts.exposure == 0.001)
        #expect(facts.hour == 5)
    }

    @Test func prefersThe35mmEquivalentForCharts() {
        let facts = ExifFacts.parse([
            "Make": "Apple", "Model": "iPhone 14 Pro", "FocalLength": "6.86", "FocalLengthIn35mmFilm": "24",
            "LensModel": "iPhone 14 Pro back triple camera 6.86mm f/1.78",
        ])
        #expect(facts.camera == "iPhone 14 Pro")
        #expect(facts.focalLength == 6.86)
        #expect(facts.chartFocalLength == 24)
        #expect(facts.lens == "iPhone 14 Pro back triple camera 6.86mm f/1.78")
    }

    @Test func usesAPEXValuesWhenTheDirectOnesAreMissing() {
        let facts = ExifFacts.parse(["ApertureValue": "3", "ShutterSpeedValue": "8"])
        #expect(abs((facts.aperture ?? 0) - 2.828) < 0.01)
        #expect(abs((facts.exposure ?? 0) - 1.0 / 256) < 0.0001)
    }

    @Test func dropsNonsense() {
        let facts = ExifFacts.parse([
            "FNumber": "0/0", "FocalLength": "0", "ISOSpeedRatings": "abc", "ExposureTime": "-1", "LensModel": "----",
            "DateTimeOriginal": "0000:00:00 00:00:00",
        ])
        #expect(facts.isEmpty)
        #expect(ExifFacts.parse(["LensModel": " 0 "]).lens == nil)
        #expect(ExifFacts.parse(["DateTimeOriginal": "2024:06:14 25:00:00"]).hour == nil)
        #expect(ExifFacts.parse(["DateTimeDigitized": "2024:06:14 23:59:59"]).hour == 23)
    }

    @Test(arguments: [
        ("NIKON CORPORATION", "NIKON D700", "Nikon D700"),
        ("Canon", "Canon EOS 5D Mark II", "Canon EOS 5D Mark II"),
        ("SONY", "ILCE-7RM3", "Sony ILCE-7RM3"),
        ("Apple", "iPhone X", "iPhone X"),
        ("OLYMPUS IMAGING CORP.", "E-M5", "Olympus E-M5"),
        ("FUJIFILM", "X100V", "Fujifilm X100V"),
        ("", "X100V", "X100V"),
        ("Acme Corp", "Acme 9000", "Acme 9000"),
        ("Acme", "", "Acme"),
        ("Google", "Pixel 7", "Google Pixel 7"),
    ])
    func cameraNames(make: String, model: String, expected: String) {
        #expect(ExifFacts.cameraName(make: make, model: model) == expected)
    }

    @Test func noCameraWithoutMakeAndModel() {
        #expect(ExifFacts.cameraName(make: nil, model: nil) == nil)
        #expect(ExifFacts.cameraName(make: " ", model: "") == nil)
    }

    @Test func scalesPickTheNearestStop() {
        #expect(StopScale.shutter.stop(for: 1.0 / 320) == 1.0 / 250)
        #expect(StopScale.shutter.stop(for: 1.0 / 1250) == 1.0 / 1000)
        #expect(StopScale.shutter.stop(for: 45) == 30)
        #expect(StopScale.aperture.stop(for: 1.7) == 1.8)
        #expect(StopScale.aperture.stop(for: 9.0 / 5) == 1.8)
        #expect(StopScale.iso.stop(for: 125) == 100)
        #expect(StopScale.iso.stop(for: 300) == 400)
        #expect(StopScale.focalLength.stop(for: 4.15) == 4)
        #expect(StopScale.focalLength.stop(for: 33) == 35)
        #expect(StopScale.focalLength.stop(for: 2000) == 1200)
    }

    @Test func rangesTileTheScaleAndHoldTheirValues() {
        for scale in [StopScale.focalLength, .aperture, .iso, .shutter] {
            for (index, stop) in scale.stops.enumerated() {
                let range = scale.range(of: stop)
                #expect(range.lower <= stop && stop < range.upper)
                if index > 0 { #expect(scale.range(of: scale.stops[index - 1]).upper == range.lower) }
            }
            #expect(scale.range(of: scale.stops[0]).lower == 0)
            #expect(scale.range(of: scale.stops.last!).upper == .infinity)
            // Every value lands in the range of its own stop.
            var value = scale.stops[0] / 3
            while value < scale.stops.last! * 3 {
                let range = scale.range(of: scale.stop(for: value))
                #expect(value >= range.lower && value < range.upper, "\(value)")
                value *= 1.07
            }
        }
    }

    @Test func filtersMatchTheBarsTheyCameFrom() {
        let facts = ExifFacts.parse(Self.nikon)
        #expect(InsightsFilter.camera("Nikon D700").matches(facts))
        #expect(!InsightsFilter.camera("Nikon D750").matches(facts))
        #expect(InsightsFilter.focalLength(35).matches(facts))
        #expect(!InsightsFilter.focalLength(28).matches(facts))
        #expect(InsightsFilter.aperture(2).matches(facts))
        #expect(InsightsFilter.iso(100).matches(facts))
        #expect(InsightsFilter.shutter(1.0 / 1000).matches(facts))
        #expect(InsightsFilter.hour(5).matches(facts))
        #expect(!InsightsFilter.lens("50mm").matches(facts))
        #expect(!InsightsFilter.focalLength(35).matches(ExifFacts()))
        let keeperFilter = InsightsFilter.keepers(lens: nil, camera: "Nikon D700")
        #expect(keeperFilter.matches(facts, mark: CullingMark(flag: .pick)))
        #expect(!keeperFilter.matches(facts, mark: CullingMark(rating: 2)))
        #expect(!InsightsFilter.keepers(lens: "50mm", camera: nil).matches(facts, mark: CullingMark(flag: .pick)))
    }

    @Test func keepers() {
        #expect(PhotoInsights.isKeeper(CullingMark(flag: .pick)))
        #expect(PhotoInsights.isKeeper(CullingMark(rating: 3)))
        #expect(PhotoInsights.isKeeper(CullingMark(rating: 1, flag: .pick)))
        #expect(!PhotoInsights.isKeeper(CullingMark(rating: 5, flag: .reject)))
        #expect(!PhotoInsights.isKeeper(CullingMark(rating: 2)))
        #expect(!PhotoInsights.isKeeper(.none))
    }

    @Test func summarizes() {
        var rows: [InsightsRow] = []
        // Six with a 50 mm lens, two of them keepers; five with the camera's own lens, none kept; four without data.
        for index in 0..<6 {
            rows.append(
                InsightsRow(
                    facts: ExifFacts(
                        camera: "Canon EOS 6D", lens: "EF50mm f/1.8 STM", focalLength: 50, aperture: 1.8, iso: 100, exposure: 1.0 / 250,
                        hour: 9),
                    mark: index < 2 ? CullingMark(flag: .pick) : CullingMark(flag: .reject)))
        }
        for _ in 0..<5 {
            rows.append(InsightsRow(facts: ExifFacts(camera: "iPhone X", focalLength: 4, focalLength35: 28, iso: 25, hour: 18)))
        }
        for _ in 0..<4 { rows.append(InsightsRow(facts: ExifFacts(hour: 12))) }
        let summary = PhotoInsights.summarize(rows)
        #expect(summary.analysed == 15)
        #expect(summary.withCameraData == 11)
        #expect(summary.reviewed == 6)
        #expect(summary.keepers == 2)
        #expect(summary.cameras.map(\.key) == ["Canon EOS 6D", "iPhone X"])
        #expect(summary.cameras.map(\.count) == [6, 5])
        #expect(summary.lenses.map(\.key) == ["EF50mm f/1.8 STM"])
        #expect(summary.focalLengths == [InsightsBar(key: 28, count: 5), InsightsBar(key: 50, count: 6)])
        #expect(summary.apertures == [InsightsBar(key: 1.8, count: 6)])
        #expect(summary.isos == [InsightsBar(key: 25, count: 5), InsightsBar(key: 100, count: 6)])
        #expect(summary.shutterSpeeds == [InsightsBar(key: 1.0 / 250, count: 6)])
        #expect(summary.hours[9] == 6 && summary.hours[18] == 5 && summary.hours[12] == 4)
        #expect(summary.hours.reduce(0, +) == 15)
        #expect(summary.keeperRates.count == 2)
        #expect(summary.keeperRates[0].lens == "EF50mm f/1.8 STM")
        #expect(summary.keeperRates[0].keepers == 2 && summary.keeperRates[0].total == 6)
        #expect(summary.keeperRates[1].lens == nil && summary.keeperRates[1].camera == "iPhone X")
        #expect(summary.keeperRates[1].rate == 0)
        #expect(summary.keeperRates[1].filter == .keepers(lens: nil, camera: "iPhone X"))
    }

    @Test func noKeeperRatesBeforeAnythingWasReviewedOrForFewPhotos() {
        let unreviewed = (0..<10).map { _ in InsightsRow(facts: ExifFacts(camera: "Nikon Z 6", lens: "NIKKOR Z 24-70mm f/4 S")) }
        #expect(PhotoInsights.summarize(unreviewed).keeperRates.isEmpty)
        let few = (0..<4).map { _ in InsightsRow(facts: ExifFacts(lens: "Rare lens"), mark: CullingMark(flag: .pick)) }
        #expect(PhotoInsights.summarize(unreviewed + few).keeperRates.map(\.lens) == ["NIKKOR Z 24-70mm f/4 S"])
        #expect(PhotoInsights.summarize([]).isEmpty)
    }
}

/// Histogram, clipping and focus peaking on raw pixels, and the loupe's geometry (SPEC §16.5.2).
@Suite struct LoupeAnalysisTests {
    /// Left half black, right half white: one hard edge in the middle.
    static func edge(width: Int = 32, height: Int = 16) -> RGBAPixels {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width / 2) {
                let index = (y * width + x) * 4
                bytes[index] = 0
                bytes[index + 1] = 0
                bytes[index + 2] = 0
            }
        }
        return RGBAPixels(width: width, height: height, bytes: bytes)
    }

    /// A soft ramp from dark to light over the whole width: no edge anywhere.
    static func ramp(width: Int = 64, height: Int = 16) -> RGBAPixels {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(40 + x * 2)
                let index = (y * width + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        return RGBAPixels(width: width, height: height, bytes: bytes)
    }

    @Test func histogramCountsEveryPixel() {
        let histogram = LoupeAnalysis.histogram(Self.edge())
        #expect(histogram.luminance[0] == 256)
        #expect(histogram.luminance[255] == 256)
        #expect(histogram.red[0] == 256 && histogram.green[255] == 256 && histogram.blue[255] == 256)
        #expect(histogram.luminance.reduce(0, +) == 512)
        let grey = LoupeAnalysis.histogram(RGBAPixels(width: 4, height: 4, fill: (100, 150, 200)))
        #expect(grey.red[100] == 16 && grey.green[150] == 16 && grey.blue[200] == 16)
        #expect(grey.luminance.firstIndex(where: { $0 > 0 }) == LoupeAnalysis.luma(100, 150, 200))
        #expect(LoupeHistogram.empty.scale == 1)
    }

    @Test func clippingMarksBlownHighlightsAndBlockedShadows() {
        let overlay = LoupeAnalysis.clipping(Self.edge())
        #expect(overlay.coverage == 1)
        // A black pixel turns blue, a white one red.
        #expect(Array(overlay.pixels.bytes[0..<4]) == [0, 90, 255, 255])
        let white = (16 + 15) * 4
        #expect(Array(overlay.pixels.bytes[white..<white + 4]) == [255, 0, 0, 255])
        let midtones = LoupeAnalysis.clipping(RGBAPixels(width: 4, height: 4, fill: (120, 130, 140)))
        #expect(midtones.coverage == 0)
        #expect(midtones.pixels.bytes.allSatisfy { $0 == 0 })
        // One channel at the top is enough for a highlight warning (a saturated red flower).
        #expect(LoupeAnalysis.clipping(RGBAPixels(width: 2, height: 2, fill: (255, 30, 30))).coverage == 1)
    }

    @Test func peakingMarksTheSharpEdgeOnly() {
        let overlay = LoupeAnalysis.focusPeaking(Self.edge(), color: (1, 2, 3))
        #expect(overlay.coverage > 0)
        let width = 32
        for y in 1..<15 {
            // The two columns at the edge are marked, columns far from it are not.
            #expect(overlay.pixels.bytes[(y * width + 15) * 4 + 3] == 255)
            #expect(overlay.pixels.bytes[(y * width + 16) * 4 + 3] == 255)
            #expect(overlay.pixels.bytes[(y * width + 4) * 4 + 3] == 0)
            #expect(overlay.pixels.bytes[(y * width + 28) * 4 + 3] == 0)
        }
        #expect(Array(overlay.pixels.bytes[(1 * width + 15) * 4..<(1 * width + 15) * 4 + 3]) == [1, 2, 3])
    }

    @Test func aSoftPhotoShowsNoPeaking() {
        #expect(LoupeAnalysis.focusPeaking(Self.ramp()).coverage == 0)
        #expect(LoupeAnalysis.focusPeaking(RGBAPixels(width: 2, height: 2, fill: (0, 0, 0))).coverage == 0)
    }

    @Test func peakingKeepsToTheSharpestShare() {
        // Fine noise everywhere: strong gradients all over, of which only the sharpest share may be marked.
        let width = 64
        let height = 64
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let value = UInt8.random(in: 0...255, using: &generator)
            bytes[index] = value
            bytes[index + 1] = value
            bytes[index + 2] = value
        }
        let overlay = LoupeAnalysis.focusPeaking(RGBAPixels(width: width, height: height, bytes: bytes))
        #expect(overlay.coverage > 0)
        #expect(overlay.coverage <= LoupeAnalysis.peakingShare + 0.02)
    }

    @Test func actualPixelsZoom() {
        // A 6000 × 4000 photo in a 1500 × 1000 point area on a 2× screen: fit is 0.25 pt/px, 100 % is 2× fit.
        let zoom = LoupeGeometry.actualPixelsZoom(
            pixels: CGSize(width: 6000, height: 4000), area: CGSize(width: 1500, height: 1000), displayScale: 2)
        #expect(zoom == 2)
        // A small photo is never shown smaller than fit.
        #expect(
            LoupeGeometry.actualPixelsZoom(
                pixels: CGSize(width: 400, height: 300), area: CGSize(width: 1500, height: 1000), displayScale: 2)
                == 1)
    }

    @Test func pointUnderThePointer() {
        // A square photo in a wide area: bars left and right.
        let pixels = CGSize(width: 1000, height: 1000)
        let area = CGSize(width: 300, height: 100)
        #expect(LoupeGeometry.photoPoint(at: CGPoint(x: 150, y: 50), pixels: pixels, area: area) == CGPoint(x: 0.5, y: 0.5))
        #expect(LoupeGeometry.photoPoint(at: CGPoint(x: 100, y: 0), pixels: pixels, area: area) == CGPoint(x: 0, y: 0))
        #expect(LoupeGeometry.photoPoint(at: CGPoint(x: 0, y: 100), pixels: pixels, area: area) == CGPoint(x: 0, y: 1))
        #expect(LoupeGeometry.photoPoint(at: CGPoint(x: 175, y: 75), pixels: pixels, area: area) == CGPoint(x: 0.75, y: 0.75))
    }

    @Test func clampedCenterKeepsThePhotoInPlace() {
        let center = LoupeGeometry.clampedCenter(
            CGPoint(x: 0, y: 1), shown: CGSize(width: 400, height: 400), area: CGSize(width: 100, height: 100))
        #expect(center == CGPoint(x: 0.125, y: 0.875))
        #expect(
            LoupeGeometry.clampedCenter(
                CGPoint(x: 0.1, y: 0.9), shown: CGSize(width: 50, height: 50), area: CGSize(width: 100, height: 100))
                == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func filmstripWindowAndAdvance() {
        #expect(LoupeGeometry.window(around: 0, count: 100, radius: 3) == 0..<4)
        #expect(LoupeGeometry.window(around: 50, count: 100, radius: 3) == 47..<54)
        #expect(LoupeGeometry.window(around: 99, count: 100, radius: 3) == 96..<100)
        #expect(LoupeGeometry.window(around: 5, count: 0, radius: 3) == 0..<0)
        #expect(LoupeGeometry.advanced(from: 3, count: 10) == 4)
        #expect(LoupeGeometry.advanced(from: 9, count: 10) == 9)
        #expect(LoupeGeometry.advanced(from: 0, count: 0) == 0)
    }
}
