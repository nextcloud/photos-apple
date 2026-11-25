// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import Testing

@testable import PhotosAppUI

/// The culling view's start, Insights' notation and the names of captured photos (SPEC §16.5).
@Suite struct ProPhotographerTests {
    @Test func loupeTakesTheSelectionOrTheWholeGrid() throws {
        let grid: [FileID] = [10, 20, 30, 40, 50]
        // Several selected: only those, in the grid's order.
        let several = try #require(LoupeRequest.from(gridIds: grid, selected: [40, 20]))
        #expect(several.ids == [20, 40] && several.startId == 20)
        // One selected: the whole grid, from there.
        let one = try #require(LoupeRequest.from(gridIds: grid, selected: [30]))
        #expect(one.ids == grid && one.startId == 30)
        // None, or one that is not in the grid: from the first.
        #expect(LoupeRequest.from(gridIds: grid, selected: [])?.startId == 10)
        #expect(LoupeRequest.from(gridIds: grid, selected: [99])?.startId == 10)
        #expect(LoupeRequest.from(gridIds: [], selected: [1]) == nil)
    }

    @Test func photographicNotation() {
        #expect(InsightsWording.aperture(2.8).hasSuffix("2.8") || InsightsWording.aperture(2.8).hasSuffix("2,8"))
        #expect(InsightsWording.aperture(8) == "ƒ/8")
        #expect(InsightsWording.shutter(1.0 / 250) == "1/250 s")
        #expect(InsightsWording.shutter(1.0 / 3.9) == "1/4 s")
        #expect(InsightsWording.shutter(2) == "2 s")
        #expect(InsightsWording.iso(12800) == "ISO 12800")
        #expect(InsightsWording.focalLength(35) == "35 mm")
    }

    @Test func capturedFilesAreNamedLikeACamera() throws {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 11, 25)
        (components.hour, components.minute, components.second) = (14, 2, 31)
        let date = try #require(Calendar.current.date(from: components))
        #expect(CapturedMedia.fileName(scan: false, date: date, fileExtension: "heic") == "IMG_20261125_140231.heic")
        #expect(CapturedMedia.fileName(scan: true, date: date, page: 2, fileExtension: "jpg") == "Scan_20261125_140231_2.jpg")
    }

    @Test func scanPagesKeepTheirOrder() throws {
        let sources = CapturedMedia.scanFiles([Data([1]), Data([2]), Data([3])], date: Date(timeIntervalSince1970: 1000))
        #expect(sources.map(\.fileName).allSatisfy { $0.hasPrefix("Scan_") && $0.hasSuffix(".jpg") })
        #expect(sources.map(\.fileName).map { $0.dropLast(4).last } == ["1", "2", "3"])
        #expect(sources.map(\.capturedAt) == [1000, 1001, 1002].map { Date(timeIntervalSince1970: $0) })
        let single = CapturedMedia.scanFiles([Data([1])], date: Date(timeIntervalSince1970: 1000))
        #expect(single.count == 1 && !single[0].fileName.hasSuffix("_1.jpg"))
        for source in sources + single { try? FileManager.default.removeItem(at: source.file.deletingLastPathComponent()) }
    }
}

/// A scanned PDF becomes one JPEG per page. Draws into bitmap contexts: Mac only, like the other rendering tests.
@Suite(.disabled(if: ProPhotographerEnvironment.isSimulator, "Rendering needs a GPU, which the CI simulator lacks"))
struct ScanPagesRenderingTests {
    @Test func pdfPagesBecomeJPEGs() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        let pages = CapturedMedia.jpegPages(ofPDF: data as Data, maxPixels: 600)
        #expect(pages.count == 2)
        let source = try #require(CGImageSourceCreateWithData(pages[0] as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 600)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 400)
        #expect(CapturedMedia.jpegPages(ofPDF: Data("not a pdf".utf8)).isEmpty)
    }
}

enum ProPhotographerEnvironment {
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }()
}
