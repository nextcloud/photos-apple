// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel

@Suite struct BackupMatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func local(
        _ name: String, at offset: TimeInterval = 0, size: Int64? = 2_000_000, w: Int? = 4032, h: Int? = 3024, kind: MediaKind = .image
    ) -> LocalResource {
        LocalResource(
            localIdentifier: name, kind: kind, createdAt: t0 + offset, originalName: name, byteSize: size, pixelWidth: w, pixelHeight: h)
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

    @Test func folders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        #expect(BackupNaming.folder(base: "/Photos/", subfolders: .yearMonth, date: date, calendar: calendar) == "/Photos/2026/09")
        #expect(BackupNaming.folder(base: "/Photos", subfolders: .none, date: date, calendar: calendar) == "/Photos")
        #expect(BackupNaming.folder(base: "/Camera", subfolders: .yearMonthDay, date: date, calendar: calendar) == "/Camera/2026/09/21")
    }
}
