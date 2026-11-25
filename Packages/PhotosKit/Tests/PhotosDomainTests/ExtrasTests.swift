// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

@Suite struct PhotoOfTheDayTests {
    let today = day(2026, 11, 24)

    func candidate(
        _ id: FileID, _ date: Date, favorite: Bool = false, name: String = "IMG.jpg", mime: String = "image/jpeg", people: Bool = false
    )
        -> DailyPhotoCandidate
    {
        DailyPhotoCandidate(fileId: id, timestamp: date, isFavorite: favorite, name: name, mimeType: mime, hasPeople: people)
    }

    @Test func prefersThisVeryDayInAnEarlierYear() throws {
        let choice = try #require(
            PhotoOfTheDay.choose(
                for: today,
                onThisDay: [candidate(1, day(2023, 11, 22), favorite: true), candidate(2, day(2021, 11, 24))],
                favorites: [candidate(9, day(2020, 1, 1), favorite: true)], recentlyShown: [], calendar: utcCalendar))
        #expect(choice.fileId == 2)
        #expect(choice.reason == .yearsAgo(5))
    }

    @Test func nearbyDaysWhenTheDayItselfHasNothingGood() throws {
        let choice = try #require(
            PhotoOfTheDay.choose(
                for: today,
                onThisDay: [candidate(1, day(2023, 11, 22)), candidate(2, day(2021, 11, 24), name: "Screenshot 2021-11-24.png")],
                favorites: [], recentlyShown: [], calendar: utcCalendar))
        #expect(choice.fileId == 1)
        #expect(choice.reason == .aroundThisDay(3))
    }

    @Test func favouritesAndPeopleWinAmongTheSameDay() throws {
        let photos = [
            candidate(1, day(2020, 11, 24)), candidate(2, day(2019, 11, 24), people: true), candidate(3, day(2018, 11, 24), favorite: true),
        ]
        let choice = try #require(
            PhotoOfTheDay.choose(for: today, onThisDay: photos, favorites: [], recentlyShown: [], calendar: utcCalendar))
        #expect(choice.fileId == 3)
        let withoutFavourite = try #require(
            PhotoOfTheDay.choose(for: today, onThisDay: Array(photos.prefix(2)), favorites: [], recentlyShown: [], calendar: utcCalendar))
        #expect(withoutFavourite.fileId == 2)
    }

    @Test func fallsBackToAFavouriteNotShownLately() throws {
        let favorites = [candidate(7, day(2015, 2, 3), favorite: true), candidate(8, day(2016, 4, 5), favorite: true)]
        let choice = try #require(
            PhotoOfTheDay.choose(for: today, onThisDay: [], favorites: favorites, recentlyShown: [7], calendar: utcCalendar))
        #expect(choice.fileId == 8)
        #expect(choice.reason == .favorite)
        // Everything was shown lately: a repeat is better than nothing.
        let repeated = PhotoOfTheDay.choose(for: today, onThisDay: [], favorites: favorites, recentlyShown: [7, 8], calendar: utcCalendar)
        #expect(repeated != nil)
    }

    @Test func screenshotsTinyImagesAndThisYearsPhotosAreNeverChosen() {
        let photos = [
            candidate(1, day(2020, 11, 24), name: "Screenshot 2020-11-24 at 10.00.00.jpg"),
            candidate(2, day(2020, 11, 24), mime: "image/png"),
            DailyPhotoCandidate(fileId: 3, timestamp: day(2020, 11, 24), width: 300, height: 200),
            candidate(4, day(2026, 11, 24)),
        ]
        #expect(PhotoOfTheDay.choose(for: today, onThisDay: photos, favorites: [], recentlyShown: [], calendar: utcCalendar) == nil)
    }

    @Test func theChoiceIsStableForADayAndVariesBetweenDays() {
        let favorites = (1...20).map { candidate(FileID($0), day(2015, 1, $0), favorite: true) }
        let first = PhotoOfTheDay.choose(for: today, onThisDay: [], favorites: favorites, recentlyShown: [], calendar: utcCalendar)
        let again = PhotoOfTheDay.choose(
            for: today.addingTimeInterval(3600), onThisDay: [], favorites: favorites, recentlyShown: [], calendar: utcCalendar)
        #expect(first == again)
        let week = (1...7).compactMap {
            PhotoOfTheDay.choose(
                for: today.addingTimeInterval(Double($0) * 86_400), onThisDay: [], favorites: favorites, recentlyShown: [],
                calendar: utcCalendar)?
                .fileId
        }
        #expect(Set(week).count > 1)
    }
}

@Suite struct CollageLayoutTests {
    let square = CGSize(width: 1000, height: 1000)

    func photos(_ aspects: [Double]) -> [CollagePhoto] {
        aspects.enumerated().map { CollagePhoto(id: FileID($0.offset + 1), aspect: $0.element) }
    }

    /// Cells lie inside the canvas and do not overlap (prints may: they are laid on top of each other).
    func expectTidy(_ layout: CollageLayout, file: StaticString = #filePath) {
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        for cell in layout.cells {
            #expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(cell.frame))
            #expect(cell.crop.minX >= -1e-9 && cell.crop.minY >= -1e-9 && cell.crop.maxX <= 1 + 1e-9 && cell.crop.maxY <= 1 + 1e-9)
        }
        let flat = layout.cells.filter { !$0.isPrint }
        for (i, a) in flat.enumerated() {
            for b in flat.dropFirst(i + 1) {
                let overlap = a.frame.intersection(b.frame)
                #expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5)
            }
        }
        if let title = layout.titleFrame, !layout.titleOverPhoto {
            for cell in flat { #expect(!cell.frame.insetBy(dx: 0.5, dy: 0.5).intersects(title)) }
        }
    }

    @Test(arguments: CollageStyle.allCases) func everyStyleIsTidyForEveryCount(style: CollageStyle) {
        for count in 1...12 {
            let aspects = (0..<count).map { [1.5, 0.75, 1.0, 1.33, 0.56][$0 % 5] }
            for canvas in [square, CGSize(width: 1200, height: 1500), CGSize(width: 1800, height: 1200)] {
                let layout = CollageLayouts.layout(style, photos: photos(aspects), canvas: canvas, hasTitle: count % 2 == 0)
                #expect(layout.cells.count == min(count, style.maxPhotos))
                #expect(Set(layout.cells.map(\.index)) == Set(0..<min(count, style.maxPhotos)))
                expectTidy(layout)
            }
        }
    }

    @Test func gridUsesNearlySquareCellsAndAShorterLastRowFillsTheWidth() {
        let layout = CollageLayouts.layout(.grid, photos: photos(Array(repeating: 1, count: 5)), canvas: square, hasTitle: false)
        let rows = Dictionary(grouping: layout.cells, by: { Int($0.frame.minY) })
        #expect(rows.count == 2)
        let last = rows[rows.keys.max()!]!
        #expect(abs(last.map(\.frame.width).reduce(0, +) + 15 * CGFloat(last.count - 1) - 920) < 1)
    }

    @Test func mosaicKeepsPhotosCloseToTheirShape() {
        let aspects = [1.5, 1.5, 0.75, 1.0, 1.5, 0.75]
        let layout = CollageLayouts.layout(.mosaic, photos: photos(aspects), canvas: square, hasTitle: false)
        for cell in layout.cells {
            let shown = Double(cell.frame.width / cell.frame.height)
            let ratio = shown / aspects[cell.index]
            #expect(ratio > 0.6 && ratio < 1.7)
        }
        // The rows fill the area to its bottom edge.
        let bottom = layout.cells.map(\.frame.maxY).max()!
        #expect(abs(bottom - 960) < 1)
    }

    @Test func magazineMakesTheFirstPhotoLargestAndPutsTheTitleOnIt() throws {
        let layout = CollageLayouts.layout(
            .magazine, photos: photos([1.5, 1, 1, 1, 1]), canvas: CGSize(width: 1200, height: 1500), hasTitle: true)
        let hero = try #require(layout.cells.first { $0.index == 0 })
        for cell in layout.cells where cell.index != 0 {
            #expect(cell.frame.width * cell.frame.height < hero.frame.width * hero.frame.height)
        }
        #expect(layout.titleOverPhoto)
        let title = try #require(layout.titleFrame)
        #expect(hero.frame.contains(title))
    }

    @Test func polaroidPrintsAreSquarePhotosTurnedALittleAndTheSameForTheSameSeed() {
        let first = CollageLayouts.layout(.polaroid, photos: photos([1.5, 0.75, 1, 1.3]), canvas: square, hasTitle: false, seed: 7)
        let again = CollageLayouts.layout(.polaroid, photos: photos([1.5, 0.75, 1, 1.3]), canvas: square, hasTitle: false, seed: 7)
        #expect(first == again)
        for cell in first.cells {
            #expect(cell.isPrint)
            #expect(abs(cell.photoFrame.width - cell.photoFrame.height) < 0.5)
            #expect(abs(cell.rotation) <= 6)
            #expect(cell.frame.contains(cell.photoFrame))
        }
    }

    @Test func cropKeepsTheFocusInView() {
        // A tall photo in a wide cell, the face near the top: the crop starts high enough to hold it.
        let face = CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.15)
        let crop = CollageLayouts.crop(imageAspect: 0.75, cellAspect: 1.5, focus: face)
        #expect(abs(crop.width - 1) < 1e-9)
        #expect(abs(crop.height - 0.5) < 1e-9)
        #expect(crop.contains(face))
        // A wide photo in a square cell, the subject on the right edge: the crop slides right, but not out of the picture.
        let right = CollageLayouts.crop(imageAspect: 2, cellAspect: 1, focus: CGRect(x: 0.85, y: 0.3, width: 0.15, height: 0.3))
        #expect(abs(right.maxX - 1) < 1e-9)
        #expect(abs(right.width - 0.5) < 1e-9)
        // A focus larger than the crop keeps its top.
        let tall = CollageLayouts.crop(imageAspect: 1, cellAspect: 2, focus: CGRect(x: 0, y: 0.2, width: 1, height: 0.8))
        #expect(abs(tall.minY - 0.2) < 1e-9)
    }

    @Test func partitionKeepsOrderAndUsesEveryRow() {
        let rows = CollageLayouts.partition([1, 1, 1, 1, 1, 1], into: 3)
        #expect(rows == [[0, 1], [2, 3], [4, 5]])
        #expect(CollageLayouts.partition([3, 0.5, 0.5], into: 3) == [[0], [1], [2]])
        #expect(CollageLayouts.partition([1, 1], into: 5) == [[0], [1]])
    }
}

@Suite struct CollagePickerTests {
    func item(_ id: FileID, _ date: Date, favorite: Bool = false, kind: MediaKind = .image, name: String? = nil) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/\(name ?? "p\(id).jpg")", mimeType: kind == .video ? "video/mp4" : "image/jpeg", capturedAt: date,
            width: 4000, height: 3000, isFavorite: favorite)
    }

    @Test func picksFavouritesAndSpreadsTheRestOverTime() {
        let items =
            (1...40).map { item(FileID($0), day(2025, 6, 1).addingTimeInterval(Double($0) * 3600), favorite: $0 == 33) }
            + [item(99, day(2025, 6, 2), kind: .video), item(98, day(2025, 6, 2), name: "Screenshot 1.jpg")]
        let picked = CollagePicker.pick(items, count: 6)
        #expect(picked.count == 6)
        #expect(picked.first?.fileId == 33)
        #expect(!picked.contains { $0.fileId == 99 || $0.fileId == 98 })
        // The others in time order and from across the day.
        let rest = picked.dropFirst().map(\.timestamp)
        #expect(rest == rest.sorted())
        let span = rest.last!.timeIntervalSince(rest.first!)
        #expect(span > 20 * 3600)
    }

    @Test func swappingTwoPhotos() {
        #expect(CollagePicker.swapped([1, 2, 3, 4], 2, 4) == [1, 4, 3, 2])
        #expect(CollagePicker.swapped([1, 2, 3], 2, 9) == [1, 2, 3])
    }
}

@Suite struct StickerSubjectsTests {
    @Test func withoutAFaceEverySubjectButSpecksIsLifted() {
        let subjects = [
            StickerSubject(instance: 1, box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), coverage: 0.2),
            StickerSubject(instance: 2, box: CGRect(x: 0.6, y: 0.5, width: 0.3, height: 0.4), coverage: 0.08),
            StickerSubject(instance: 3, box: CGRect(x: 0.9, y: 0.9, width: 0.02, height: 0.02), coverage: 0.0004),
        ]
        #expect(StickerSubjects.choose(subjects) == [1, 2])
        #expect(StickerSubjects.choose([subjects[2]]) == [3])
        #expect(StickerSubjects.choose([]) == [])
    }

    @Test func withAFaceOnlyThatPersonIsLifted() {
        let subjects = [
            StickerSubject(instance: 1, box: CGRect(x: 0.0, y: 0.1, width: 0.4, height: 0.9), coverage: 0.2),
            StickerSubject(instance: 2, box: CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.9), coverage: 0.25),
        ]
        #expect(StickerSubjects.choose(subjects, face: CGRect(x: 0.1, y: 0.15, width: 0.1, height: 0.1)) == [1])
        #expect(StickerSubjects.choose(subjects, face: CGRect(x: 0.6, y: 0.15, width: 0.1, height: 0.1)) == [2])
        // The face's centre is outside every subject but it overlaps one.
        #expect(StickerSubjects.choose(subjects, face: CGRect(x: 0.35, y: 0.05, width: 0.1, height: 0.1)) == [1])
        // Nobody there.
        #expect(StickerSubjects.choose(subjects, face: CGRect(x: 0.42, y: 0.0, width: 0.05, height: 0.05)) == [])
    }

    @Test func packPhotosNeedALargeEnoughFaceAndSpreadOverTime() {
        let items = (1...30).map {
            MediaItem(
                fileId: FileID($0), path: "/p\($0).jpg", mimeType: "image/jpeg",
                capturedAt: day(2020, 1, 1).addingTimeInterval(Double($0) * 86_400),
                isFavorite: $0 == 5)
        }
        var faces: [FileID: CGRect] = [:]
        for id in 1...30 { faces[FileID(id)] = CGRect(x: 0.3, y: 0.2, width: id % 3 == 0 ? 0.02 : 0.1 + Double(id) / 1000, height: 0.1) }
        let pack = StickerSubjects.packPhotos(items, faces: faces, count: 8)
        #expect(pack.count == 8)
        #expect(pack.contains(5))
        #expect(!pack.contains { $0 % 3 == 0 })
        // Larger faces first.
        let widths = pack.map { faces[$0]!.width }
        #expect(widths == widths.sorted(by: >))
    }
}
