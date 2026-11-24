// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking

/// Importing from a memory card or camera (SPEC §15.2): pairing, folders, "new only", verification, deletion.
@Suite(.timeLimit(.minutes(5))) struct CardImportTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let day = Date(timeIntervalSince1970: 1_764_000_000)  // 2025-11-24 16:00 UTC

    static func item(_ name: String, folder: String = "DCIM/100CANON", size: Int64 = 100, at offset: TimeInterval = 0) -> CardItem {
        CardItem(
            id: folder + "/" + name, name: name, folder: folder, size: size, capturedAt: day.addingTimeInterval(offset),
            kind: CardItem.kind(ofName: name))
    }

    // MARK: Plan

    @Test func rawAndJpegOfAShotAreOneGroup() {
        let groups = CardGroup.groups([
            Self.item("IMG_0001.CR3", at: 0), Self.item("IMG_0001.JPG", at: 0), Self.item("IMG_0002.JPG", at: 5),
            // Same name in another folder (the camera started a new folder): another shot.
            Self.item("IMG_0001.JPG", folder: "DCIM/101CANON", at: 10),
        ])
        #expect(groups.count == 3)
        let pair = groups.first { $0.items.count == 2 }
        #expect(pair?.items.map(\.name) == ["IMG_0001.JPG", "IMG_0001.CR3"])
        #expect(pair?.leader.name == "IMG_0001.JPG")
        #expect(pair?.hasRaw == true)
        #expect(pair?.size == 200)
        // Newest first.
        #expect(groups.first?.items.first?.folder == "DCIM/101CANON")
    }

    @Test func mediaFilesOnly() {
        #expect(CardItem.isMedia(name: "IMG_1.CR3"))
        #expect(CardItem.isMedia(name: "MVI_1.MP4"))
        #expect(CardItem.isMedia(name: "DSC_1.NEF"))
        #expect(!CardItem.isMedia(name: "IMG_1.THM"))
        #expect(!CardItem.isMedia(name: "IMG_1.XMP"))
        #expect(!CardItem.isMedia(name: "._IMG_1.JPG"))
        #expect(CardItem.kind(ofName: "C0001.MP4") == .video)
    }

    @Test func destinationPatterns() {
        let date = Self.day
        #expect(DestinationPattern.default.folder(for: date, timeZone: Self.utc) == "/Photos/2025/2025-11-24")
        #expect(DestinationPattern("Photos/{yyyy}/{MM}").folder(for: date, timeZone: Self.utc) == "/Photos/2025/11")
        #expect(
            DestinationPattern("/Photos/{yyyy}/{yyyy-MM-dd} {camera}").folder(for: date, camera: "EOS R5", timeZone: Self.utc)
                == "/Photos/2025/2025-11-24 EOS R5")
        // A slash in a camera name cannot make a folder; ".." cannot leave the folder.
        #expect(DestinationPattern("/A/{camera}/../{dd}").folder(for: date, camera: "X/Y", timeZone: Self.utc) == "/A/X-Y/24")
        #expect(DestinationPattern("/Photos/{yyyy}").folder(for: nil, timeZone: Self.utc) == "/Photos/Unknown date")
        // Unknown parts stay visible, and make the pattern invalid.
        #expect(DestinationPattern("/Photos/{hour}").isValid == false)
        #expect(DestinationPattern("/").isValid == false)
        #expect(DestinationPattern.default.isValid)
        // Time zone: a shot just before midnight goes into that day.
        let lateEvening = Date(timeIntervalSince1970: 1_764_028_700)  // 2025-11-24 23:58 UTC
        #expect(DestinationPattern("/{yyyy-MM-dd}").folder(for: lateEvening, timeZone: Self.utc) == "/2025-11-24")
    }

    @Test func ledgerRemembersByNameSizeAndSecond() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var ledger = CardImportLedger()
        ledger.record(Self.item("IMG_0001.JPG"), path: "/Photos/a.jpg")
        try ledger.save(to: url)
        let loaded = CardImportLedger.load(from: url)
        #expect(loaded.contains(Self.item("img_0001.jpg")))
        #expect(!loaded.contains(Self.item("IMG_0001.JPG", size: 101)))
        #expect(!loaded.contains(Self.item("IMG_0001.JPG", at: 2)))
    }

    @Test func checksumVerification() {
        let node = PhotosNetworking.XMLNode(
            name: QName(XMLNamespace.oc, "checksums"), attributes: [:], text: "",
            children: [
                PhotosNetworking.XMLNode(
                    name: QName(XMLNamespace.oc, "checksum"), attributes: [:], text: "SHA1:aa MD5:bb SHA256:ABCD", children: [])
            ])
        #expect(PhotosCardImportRemote.verification(checksums: node, sha256: "abcd") == .checksum)
        #expect(PhotosCardImportRemote.verification(checksums: node, sha256: "ffff") == .mismatch)
        #expect(PhotosCardImportRemote.verification(checksums: nil, sha256: "abcd") == .size)
    }

    // MARK: Import

    final class FakeRemote: CardImportRemote, Sendable {
        let uploads = Mutex<[String]>([])
        let candidatesOnServer: [RemoteCandidate]
        /// File names the server "stores" with other bytes.
        let corrupt: Set<String>
        let failing: Set<String>
        let stopAfter: Int?

        init(candidates: [RemoteCandidate] = [], corrupt: Set<String> = [], failing: Set<String> = [], stopAfter: Int? = nil) {
            candidatesOnServer = candidates
            self.corrupt = corrupt
            self.failing = failing
            self.stopAfter = stopAfter
        }

        func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
            // As the real search: capture times 14 h around, for EXIF times read without their offset.
            candidatesOnServer.filter {
                ($0.capturedAt ?? .distantPast) >= start.addingTimeInterval(-14 * 3600)
                    && ($0.capturedAt ?? .distantPast) <= end.addingTimeInterval(14 * 3600)
            }
        }

        func upload(file: URL, fileName: String, folder: String, capturedAt: Date?, progress: (@Sendable (Double) -> Void)?) async throws
            -> UploadedFile
        {
            if let stopAfter, uploads.withLock({ $0.count }) >= stopAfter { throw NetworkError.insufficientStorage }
            if failing.contains(fileName) { throw NetworkError.http(status: 500, message: nil) }
            let path = folder + "/" + fileName
            let count = uploads.withLock { list in
                list.append(path)
                return list.count
            }
            progress?(1)
            return UploadedFile(fileId: FileID(count), path: path, etag: "e")
        }

        func verify(_ uploaded: UploadedFile, size: Int64, sha256: String?) async throws -> CardVerification {
            corrupt.contains((uploaded.path as NSString).lastPathComponent) ? .mismatch : (sha256 == nil ? .size : .checksum)
        }

        func didUpload(_ uploaded: UploadedFile) async {}
    }

    final class FakeSource: CardImportSource, Sendable {
        let folder: URL
        let deleted = Mutex<[String]>([])

        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "card-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func localFile(for item: CardItem, in temporary: URL) async throws -> (url: URL, isTemporary: Bool) {
            let url = temporary.appending(path: UUID().uuidString)
            try Data(repeating: 7, count: Int(item.size)).write(to: url)
            return (url, true)
        }

        func delete(_ items: [CardItem]) async throws {
            deleted.withLock { $0.append(contentsOf: items.map(\.name)) }
        }
    }

    func importer(_ remote: FakeRemote, _ source: FakeSource, delete: Bool = false, ledger: URL) -> CardImporter {
        CardImporter(
            remote: remote, source: source,
            options: CardImportOptions(destination: DestinationPattern("/Photos/{yyyy}/{yyyy-MM-dd}"), deleteAfterVerifiedUpload: delete),
            ledgerURL: ledger)
    }

    @Test func importsIntoDateFoldersAndDeletesOnlyVerifiedFiles() async throws {
        let ledger = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let remote = FakeRemote(corrupt: ["IMG_0002.JPG"], failing: ["IMG_0003.JPG"])
        let source = try FakeSource()
        let items = [
            Self.item("IMG_0001.JPG"), Self.item("IMG_0001.CR3"), Self.item("IMG_0002.JPG", at: 60), Self.item("IMG_0003.JPG", at: 90),
        ]
        let result = await importer(remote, source, delete: true, ledger: ledger).run(CardGroup.groups(items)) { _ in }
        #expect(result.phase == .finished)
        #expect(result.verified == 2)
        #expect(result.failed == 2)
        #expect(result.deleted == 2)
        #expect(result.keptOnCard == 2)
        #expect(result.processedBytes == result.totalBytes)
        // The pair went into one folder, in its local date.
        let folder = DestinationPattern("/Photos/{yyyy}/{yyyy-MM-dd}").folder(for: Self.day)
        #expect(remote.uploads.withLock { $0 }.contains(folder + "/IMG_0001.CR3"))
        // Only what is verified on the server leaves the card.
        #expect(Set(source.deleted.withLock { $0 }) == ["IMG_0001.JPG", "IMG_0001.CR3"])
        // And is remembered: "new only" knows it next time without asking the server.
        let again = importer(FakeRemote(), source, ledger: ledger)
        #expect(await again.alreadyImported(items) == Set(items.prefix(2).map(\.id)))
    }

    @Test func aStopKeepsTheCardAsItIs() async throws {
        let ledger = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let remote = FakeRemote(stopAfter: 1)
        let source = try FakeSource()
        let items = [Self.item("A.JPG"), Self.item("B.JPG", at: 10)]
        let result = await importer(remote, source, delete: true, ledger: ledger).run(CardGroup.groups(items)) { _ in }
        #expect(result.phase == .stopped(NetworkError.insufficientStorage.localizedDescription))
        #expect(source.deleted.withLock { $0 }.isEmpty)
    }

    @Test func filesOnTheServerAreFoundByTheBackupRules() async throws {
        let ledger = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        // The same JPEG, uploaded by another app under another name; the RAW of the shot is not there.
        let onServer = RemoteCandidate(
            fileId: 9, path: "/Photos/Old/renamed.jpg", kind: .image, size: 100, capturedAt: Self.day, modifiedAt: Self.day)
        let items = [Self.item("IMG_0001.JPG"), Self.item("IMG_0001.CR3", size: 300), Self.item("IMG_0002.JPG", size: 120, at: 4000)]
        let found = await importer(FakeRemote(candidates: [onServer]), try FakeSource(), ledger: ledger).alreadyImported(items)
        #expect(found == [items[0].id])
    }

    /// The server read the camera's local time as UTC: the same bytes are found by size and minutes and seconds.
    @Test func filesWhoseTimeWasReadInAnotherZoneAreFound() async throws {
        let ledger = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let onServer = RemoteCandidate(
            fileId: 9, path: "/Photos/x.jpg", kind: .image, size: 100, capturedAt: Self.day.addingTimeInterval(3600),
            modifiedAt: Self.day.addingTimeInterval(7200))
        let items = [Self.item("A.JPG"), Self.item("B.JPG", size: 100, at: 1), Self.item("C.JPG", size: 101)]
        let found = await importer(FakeRemote(candidates: [onServer]), try FakeSource(), ledger: ledger).alreadyImported(items)
        #expect(found == [items[0].id])
    }

    @Test func importWindowsSpanADayAtMost() {
        let items = (0..<5).map { Self.item("I\($0).JPG", at: Double($0) * 10 * 3600) }
        let windows = CardImporter.windows(items)
        #expect(windows.map(\.count) == [3, 2])
    }
}
