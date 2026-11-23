// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel

@Suite struct BackupMatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func local(
        _ name: String, at offset: TimeInterval = 0, size: Int64? = 2_000_000, w: Int? = 4032, h: Int? = 3024, kind: MediaKind = .image,
        rendition: LocalResource.Rendition = .original
    ) -> LocalResource {
        LocalResource(
            localIdentifier: name, kind: kind, createdAt: t0 + offset, originalName: name, byteSize: size, pixelWidth: w, pixelHeight: h,
            rendition: rendition)
    }

    func remote(
        _ path: String, captured: TimeInterval? = 0, modified: TimeInterval = 999, size: Int64 = 1, w: Int? = nil, h: Int? = nil,
        kind: MediaKind = .image
    )
        -> RemoteCandidate
    {
        RemoteCandidate(
            fileId: Int64(path.hashValue & 0xffff), path: path, kind: kind, size: size, capturedAt: captured.map { t0 + $0 },
            modifiedAt: t0 + modified, width: w, height: h)
    }

    @Test func exactCopyBySize() {
        let resource = local("IMG_1234.HEIC")
        let result = BackupMatcher.match(
            resource, candidates: [remote("/Photos/2026/IMG_1234.HEIC", size: 2_000_000)], localSiblings: [resource])
        #expect(result?.1 == .serverTimeSize)
    }

    @Test func filesAppNamingKeepsTheNumber() {
        // Files app: "26-09-21 16-53-20 1234.jpg", JPEG-converted, so the size differs; mtime = capture time.
        let resource = local("IMG_1234.HEIC")
        let candidate = remote("/Photos/2026/09/26-09-21 16-53-20 1234.jpg", captured: nil, modified: 0, size: 3_100_000)
        #expect(BackupMatcher.match(resource, candidates: [candidate], localSiblings: [resource])?.1 == .serverTimeName)
    }

    @Test func burstsAreNotMergedByTime() {
        // Two burst photos in the same second; only IMG_0011 is on the server (converted, different size and name scheme).
        let first = local("IMG_0010.HEIC")
        let second = local("IMG_0011.HEIC", at: 0.4)
        let candidate = remote("/Photos/IMG_0011.jpg", size: 1_234, w: 4032, h: 3024)
        #expect(BackupMatcher.match(first, candidates: [candidate], localSiblings: [first, second]) == nil)
        #expect(BackupMatcher.match(second, candidates: [candidate], localSiblings: [first, second])?.1 == .serverTimeName)
    }

    @Test func convertedCopyByDimensionsWhenUnique() {
        let resource = local("DSC.HEIC")  // no number in the name
        let candidate = remote("/Photos/Photo 26-09-21.jpg", size: 999, w: 3024, h: 4032)  // rotated dimensions still match
        #expect(BackupMatcher.match(resource, candidates: [candidate], localSiblings: [resource])?.1 == .serverTimeSize)
    }

    @Test func shiftedExifTimeNeedsTheNumber() {
        let resource = local("IMG_2000.JPG")
        let shifted = remote("/Photos/IMG_2000.JPG", captured: 2 * 3600, modified: 50_000, size: 5)
        #expect(BackupMatcher.match(resource, candidates: [shifted], localSiblings: [resource])?.1 == .serverTimeName)
        let otherNumber = remote("/Photos/IMG_2001.JPG", captured: 2 * 3600, modified: 50_000, size: 5)
        #expect(BackupMatcher.match(resource, candidates: [otherNumber], localSiblings: [resource]) == nil)
    }

    @Test func differentKindOrTimeIsNotAMatch() {
        let resource = local("IMG_3000.MOV", kind: .video)
        #expect(BackupMatcher.match(resource, candidates: [remote("/Photos/IMG_3000.HEIC", size: 2_000_000)], localSiblings: []) == nil)
        let photo = local("IMG_3001.HEIC")
        #expect(
            BackupMatcher.match(
                photo, candidates: [remote("/Photos/IMG_3001.HEIC", captured: 10, modified: 10, size: 2_000_000)], localSiblings: []) == nil
        )
    }

    // MARK: Renditions (an edit or a RAW is not the file that is already there)

    @Test func editIsNotMatchedByTheOriginalOnTheServer() {
        let edit = local("IMG_E1234.HEIC", size: 1_500_000, rendition: .edited)
        // Same second, same number, same dimensions, the only candidate: still the original, not the edit.
        let original = remote("/Photos/IMG_1234.HEIC", size: 2_000_000, w: 4032, h: 3024)
        #expect(BackupMatcher.match(edit, candidates: [original], localSiblings: [edit]) == nil)
        let filesNaming = remote("/Photos/26-09-21 16-53-20 1234.jpg", captured: nil, modified: 0, size: 3_100_000)
        #expect(BackupMatcher.match(edit, candidates: [filesNaming], localSiblings: [edit]) == nil)
        let shifted = remote("/Photos/IMG_1234.HEIC", captured: 2 * 3600, modified: 50_000, size: 5)
        #expect(BackupMatcher.match(edit, candidates: [shifted], localSiblings: [edit]) == nil)
    }

    @Test func editMatchesAnEditedNameOrTheSameBytes() {
        let edit = local("IMG_E1234.HEIC", size: 1_500_000, rendition: .edited)
        let original = remote("/Photos/IMG_1234.HEIC", size: 2_000_000)
        let apple = remote("/Photos/IMG_E1234.jpg", size: 777)
        #expect(BackupMatcher.match(edit, candidates: [original, apple], localSiblings: [edit])?.0 == apple)
        let suffixed = remote("/Photos/26-09-21 16-53-20 1234 (edited).jpg", size: 777)
        #expect(BackupMatcher.match(edit, candidates: [original, suffixed], localSiblings: [edit])?.0 == suffixed)
        let renamed = remote("/Photos/IMG_E1234 (2).HEIC", size: 777)
        #expect(BackupMatcher.match(edit, candidates: [renamed], localSiblings: [edit])?.1 == .serverTimeName)
        // Whatever it is called: the same second and the same bytes are the same file.
        let sameBytes = remote("/Photos/holiday.heic", size: 1_500_000)
        #expect(BackupMatcher.match(edit, candidates: [original, sameBytes], localSiblings: [edit])?.1 == .serverTimeSize)
        // Without a known size only the name can say so.
        let unknownSize = local("IMG_E1234.HEIC", size: nil, rendition: .edited)
        #expect(BackupMatcher.match(unknownSize, candidates: [original, sameBytes], localSiblings: [unknownSize]) == nil)
        #expect(BackupMatcher.match(unknownSize, candidates: [original, apple], localSiblings: [unknownSize])?.0 == apple)
    }

    @Test func originalIsNotMatchedByAnEditOnTheServer() {
        let photo = local("IMG_1234.HEIC")
        let edit = remote("/Photos/IMG_E1234.HEIC", size: 1_500_000, w: 4032, h: 3024)
        #expect(BackupMatcher.match(photo, candidates: [edit], localSiblings: [photo]) == nil)
        let original = remote("/Photos/IMG_1234.HEIC", size: 5)
        #expect(BackupMatcher.match(photo, candidates: [edit, original], localSiblings: [photo])?.0 == original)
    }

    @Test func rawOnlyMatchesRaw() {
        let raw = local("IMG_1234.DNG", size: 25_000_000, rendition: .raw)
        let jpeg = remote("/Photos/IMG_1234.JPG", size: 2_000_000, w: 4032, h: 3024)
        let heic = remote("/Photos/26-09-21 16-53-20 1234.heic", size: 25_000_000)  // not even with the same size
        #expect(BackupMatcher.match(raw, candidates: [jpeg, heic], localSiblings: [raw]) == nil)
        let dng = remote("/Photos/IMG_1234.dng", size: 5)
        #expect(BackupMatcher.match(raw, candidates: [jpeg, dng], localSiblings: [raw])?.0 == dng)
        // And a JPEG is not matched by the RAW next to it.
        let photo = local("IMG_1234.JPG")
        #expect(BackupMatcher.match(photo, candidates: [dng], localSiblings: [photo]) == nil)
        // ProRAW: the original itself is a DNG.
        let proRaw = local("IMG_1234.DNG", size: nil)
        #expect(BackupMatcher.match(proRaw, candidates: [jpeg], localSiblings: [proRaw]) == nil)
        #expect(BackupMatcher.match(proRaw, candidates: [dng], localSiblings: [proRaw])?.0 == dng)
    }

    @Test func otherRenditionsOfTheAssetAreNotBurstSiblings() {
        // Original and edit share the second; the converted original on the server is still found by its dimensions.
        let photo = local("DSC.HEIC", size: nil)
        let edit = local("DSC (edited).HEIC", size: nil, rendition: .edited)
        let candidate = remote("/Photos/Photo 26-09-21.jpg", size: 999, w: 4032, h: 3024)
        #expect(BackupMatcher.match(photo, candidates: [candidate], localSiblings: [photo, edit])?.1 == .serverTimeSize)
        #expect(BackupMatcher.match(edit, candidates: [candidate], localSiblings: [photo, edit]) == nil)
    }

    @Test func exactSizeNeedsAKnownSize() {
        // Production used to build every resource without a size, so this rule never fired.
        let candidate = remote("/Photos/holiday.heic", size: 2_000_000)
        let sized = local("DSC.HEIC", w: nil, h: nil)
        #expect(BackupMatcher.match(sized, candidates: [candidate], localSiblings: [sized])?.1 == .serverTimeSize)
        let unsized = local("DSC.HEIC", size: nil, w: nil, h: nil)
        #expect(BackupMatcher.match(unsized, candidates: [candidate], localSiblings: [unsized]) == nil)
        // An empty server file is not "the same size" as an unknown one.
        let zero = local("DSC.HEIC", size: 0, w: nil, h: nil)
        #expect(BackupMatcher.match(zero, candidates: [remote("/Photos/empty.heic", size: 0)], localSiblings: [zero]) == nil)
    }

    @Test func editedNames() {
        #expect(BackupMatcher.isEditedName("IMG_E1234.HEIC"))
        #expect(BackupMatcher.isEditedName("IMG_E1234 (2).jpg"))
        #expect(BackupMatcher.isEditedName("Photo 26-09-21 16-53-20 1234 (edited).jpg"))
        #expect(BackupMatcher.isEditedName("Holiday (Edited).png"))
        #expect(!BackupMatcher.isEditedName("IMG_1234.HEIC"))
        #expect(!BackupMatcher.isEditedName("26-09-21 16-53-20 1234.jpg"))
        #expect(!BackupMatcher.isEditedName("HOME_E12.jpg"))
        #expect(!BackupMatcher.isEditedName("edited.jpg"))
    }

    @Test func theSourcePassesSizeAndRenditionToTheMatcher() {
        var resource = BackupResource(
            localIdentifier: "a", kind: .edited, mediaKind: .image, originalName: "IMG_E1.HEIC", createdAt: t0, modifiedAt: nil,
            pixelWidth: 0, pixelHeight: 0, byteSize: 4711)
        #expect(resource.local.byteSize == 4711)
        #expect(resource.local.rendition == .edited)
        #expect(resource.local.pixelWidth == nil)
        resource.kind = .raw
        resource.byteSize = nil
        #expect(resource.local.rendition == .raw)
        #expect(resource.local.byteSize == nil)
        resource.kind = .pairedVideo
        #expect(resource.local.rendition == .original)
        #expect(PhotoLibrarySource.validSize(nil) == nil)
        #expect(PhotoLibrarySource.validSize(0) == nil)
        #expect(PhotoLibrarySource.validSize(-1) == nil)
        #expect(PhotoLibrarySource.validSize(123) == 123)
    }

    @Test func numberMustBeAWholeDigitRun() {
        #expect(BackupMatcher.containsNumber("26-09-21 16-53-20 1234.jpg", "1234"))
        #expect(!BackupMatcher.containsNumber("IMG_12345.jpg", "1234"))
        #expect(!BackupMatcher.containsNumber("IMG_01234.jpg", "1234"))
    }
}

@Suite struct BackupNamingTests {
    let date: Date = {
        var components = DateComponents(year: 2026, month: 9, day: 21, hour: 16, minute: 53, second: 20)
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()
    let utc = TimeZone(identifier: "UTC")!

    @Test func originalNames() {
        #expect(
            BackupNaming.fileName(originalName: "IMG_1234.HEIC", fileExtension: "heic", isVideo: false, date: date, naming: .original)
                == "IMG_1234.heic")
        #expect(
            BackupNaming.fileName(originalName: "IMG_1234.HEIC", fileExtension: "JPG", isVideo: false, date: date, naming: .original)
                == "IMG_1234.jpg")
    }

    @Test func filesAppNames() {
        let name = BackupNaming.fileName(
            originalName: "IMG_1234.HEIC", fileExtension: "jpg", isVideo: false, date: date,
            naming: .filesApp(typePrefix: false, mask: nil), timeZone: utc)
        #expect(name == "26-09-21 16-53-20 1234.jpg")
        let masked = BackupNaming.fileName(
            originalName: "IMG_7.MOV", fileExtension: "mov", isVideo: true, date: date,
            naming: .filesApp(typePrefix: false, mask: "YYYY-MM-DD_HH.mm"),
            timeZone: utc)
        #expect(masked == "2026-09-21_16.53 7.mov")
    }

    @Test func editsKeepAMarkerInFilesAppNames() {
        // The scheme only keeps the number, so IMG_E1234 would get the original's name.
        let edit = BackupNaming.fileName(
            originalName: "IMG_E1234.HEIC", fileExtension: "jpg", isVideo: false, date: date,
            naming: .filesApp(typePrefix: false, mask: nil), timeZone: utc)
        #expect(edit == "26-09-21 16-53-20 1234 (edited).jpg")
        #expect(BackupMatcher.isEditedName(edit))
        #expect(
            BackupNaming.fileName(originalName: "IMG_E1234.HEIC", fileExtension: "heic", isVideo: false, date: date, naming: .original)
                == "IMG_E1234.heic")
        #expect(PhotoLibrarySource.editedName("IMG_1234.HEIC", ext: "FullSizeRender.jpg") == "IMG_E1234.jpg")
        #expect(PhotoLibrarySource.editedName("Holiday.png", ext: "FullSizeRender.jpg") == "Holiday (edited).jpg")
    }

    @Test func folders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(BackupNaming.folder(base: "/Photos/", subfolders: .yearMonth, date: date, calendar: calendar) == "/Photos/2026/09")
        #expect(BackupNaming.folder(base: "/Photos", subfolders: .none, date: date, calendar: calendar) == "/Photos")
        #expect(BackupNaming.folder(base: "/Camera", subfolders: .yearMonthDay, date: date, calendar: calendar) == "/Camera/2026/09/21")
    }
}
