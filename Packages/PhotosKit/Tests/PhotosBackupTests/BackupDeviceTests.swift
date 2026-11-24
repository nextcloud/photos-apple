// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Round 3, items 33/34/36/37: the backup folder against the timeline folders, the first-run counts, the list of photos
/// that are not backed up, and which device photos may be removed.
@Suite struct BackupDeviceTests {
    func entry(
        _ id: String, _ kind: BackupResourceKind = .photo, state: BackupItemState, path: String? = nil, fileId: Int64? = nil,
        error: String? = nil
    ) -> BackupLedgerEntry {
        BackupLedgerEntry(
            localIdentifier: id, resourceKind: kind.rawValue, fingerprint: nil, state: state.rawValue, serverPath: path,
            serverFileId: fileId, serverEtag: nil, matchedBy: nil, attempts: 0, lastError: error, assetCreatedAt: nil,
            assetModifiedAt: nil, updatedAt: 0)
    }

    // MARK: Item 34 — backup folder and timeline folders

    @Test func folderPathsAreNormalised() {
        #expect(BackupFolder.normalized("Photos/") == "/Photos")
        #expect(BackupFolder.normalized("//Photos//Camera/./") == "/Photos/Camera")
        #expect(BackupFolder.normalized("") == "/")
        #expect(BackupFolder.normalized("/") == "/")
    }

    @Test func aFolderIsShownWhenItIsATimelineFolderOrBelowOne() {
        let timeline = ["/Photos", "/InstantUpload/"]
        #expect(BackupFolder.isShown("/Photos", inTimelineFolders: timeline))
        #expect(BackupFolder.isShown("/Photos/Camera Roll", inTimelineFolders: timeline))
        #expect(BackupFolder.isShown("InstantUpload/Camera/", inTimelineFolders: timeline))
        // Whole path components, case-sensitive like the server.
        #expect(!BackupFolder.isShown("/Photos2", inTimelineFolders: timeline))
        #expect(!BackupFolder.isShown("/photos", inTimelineFolders: timeline))
        #expect(!BackupFolder.isShown("/Camera", inTimelineFolders: timeline))
        #expect(!BackupFolder.isShown("/", inTimelineFolders: timeline))
        // The root shows everything; no timeline folder shows nothing.
        #expect(BackupFolder.isShown("/Camera", inTimelineFolders: ["/"]))
        #expect(!BackupFolder.isShown("/Photos", inTimelineFolders: []))
    }

    @Test func theSuggestionIsAFolderTheTimelineShows() {
        #expect(BackupFolder.suggestion(photosLocation: "/Photos", timelineFolders: ["/Photos"]) == "/Photos")
        #expect(BackupFolder.suggestion(photosLocation: "/Photos/Uploads", timelineFolders: ["/Photos"]) == "/Photos/Uploads")
        #expect(BackupFolder.suggestion(photosLocation: "/Uploads", timelineFolders: ["/Pictures", "/Photos"]) == "/Pictures")
        #expect(BackupFolder.suggestion(photosLocation: "/Uploads", timelineFolders: ["/"]) == "/Uploads")
        #expect(BackupFolder.suggestion(photosLocation: "/Uploads", timelineFolders: []) == nil)
    }

    // MARK: Item 33 — counts for "X already on your server, Y to upload"

    @Test func countsArePerPhotoNotPerFile() async throws {
        let database = try AccountDatabase.temporary()
        let engine = BackupEngine(
            library: FakeLibrary(), remote: FakeRemote(), database: database, accountId: AccountID(rawValue: "test"),
            filesLedger: { _ in [] })
        try await database.writer.write { db in
            // A Live Photo found on the server (both halves), one uploaded photo, one with its motion part still waiting,
            // one that failed, and one only in iCloud.
            try entry("live", .photo, state: .matched).insert(db)
            try entry("live", .pairedVideo, state: .matched).insert(db)
            try entry("done", state: .uploaded).insert(db)
            try entry("half", .photo, state: .matched).insert(db)
            try entry("half", .pairedVideo, state: .pending).insert(db)
            try entry("failed", state: .failed).insert(db)
            try entry("cloud", state: .skipped).insert(db)
        }
        let counts = try await engine.assetCounts()
        #expect(counts == BackupAssetCounts(onServer: 2, toUpload: 2))
        #expect(try await engine.ledgerByAsset()["half"]?.count == 2)
    }

    @Test func anEmptyLedgerCountsNothing() async throws {
        let engine = BackupEngine(
            library: FakeLibrary(), remote: FakeRemote(), database: try AccountDatabase.temporary(), accountId: AccountID(rawValue: "test"),
            filesLedger: { _ in [] })
        #expect(try await engine.assetCounts() == BackupAssetCounts())
    }

    // MARK: Item 37 — photos that are not backed up

    @Test func notBackedUpListsEverythingThatIsNotCompletelyOnTheServer() {
        let ledger: [String: [BackupLedgerEntry]] = [
            "done": [entry("done", state: .uploaded)],
            "matched": [entry("matched", state: .matched), entry("matched", .pairedVideo, state: .matched)],
            "half": [entry("half", state: .matched), entry("half", .pairedVideo, state: .pending)],
            "failed": [entry("failed", state: .failed, error: "Server error"), entry("failed", .raw, state: .uploaded)],
            "cloud": [entry("cloud", state: .skipped)],
        ]
        let result = BackupDeviceState.notBackedUp(["new", "done", "half", "failed", "matched", "cloud"], ledger: ledger)
        #expect(
            result == [
                NotBackedUpAsset(localIdentifier: "new", reason: .waiting),
                NotBackedUpAsset(localIdentifier: "half", reason: .waiting),
                NotBackedUpAsset(localIdentifier: "failed", reason: .failed("Server error")),
                NotBackedUpAsset(localIdentifier: "cloud", reason: .onlyInICloud),
            ])
    }

    // MARK: Item 36 — free up space only for verified photos

    typealias Local = DeviceCleanup.LocalAsset

    func local(_ id: String, _ resources: [(BackupResourceKind, Int64?)], created: Date? = Date(timeIntervalSince1970: 0)) -> Local {
        Local(
            localIdentifier: id, createdAt: created, required: resources.map { Local.Resource(kind: $0.0, byteSize: $0.1) },
            totalSize: resources.reduce(0) { $0 + ($1.1 ?? 0) })
    }

    @Test func onlyAssetsWithEveryFileOnTheServerWithTheSameSizeAreVerified() {
        let server: [String: ServerFileInfo] = [
            "/Photos/2024/05/IMG_1.HEIC": ServerFileInfo(fileId: 1, size: 100),
            "/Photos/2024/05/IMG_1.MOV": ServerFileInfo(fileId: 2, size: 300),
            "/Photos/2024/05/IMG_2.jpg": ServerFileInfo(fileId: 3, size: 80),
        ]
        let livePhoto = [
            entry("a", .photo, state: .uploaded, path: "/Photos/2024/05/IMG_1.HEIC", fileId: 1),
            entry("a", .pairedVideo, state: .matched, path: "Photos/2024/05//IMG_1.MOV"),
        ]
        #expect(DeviceCleanup.isVerified(local("a", [(.photo, 100), (.pairedVideo, 300)]), entries: livePhoto, server: server))
        // The motion part is missing on the server side of the ledger.
        #expect(!DeviceCleanup.isVerified(local("a", [(.photo, 100), (.pairedVideo, 300)]), entries: [livePhoto[0]], server: server))
        // Another size: converted to JPEG for the backup, or another file.
        #expect(!DeviceCleanup.isVerified(local("a", [(.photo, 101), (.pairedVideo, 300)]), entries: livePhoto, server: server))
        // The device doesn't know the size.
        #expect(!DeviceCleanup.isVerified(local("a", [(.photo, nil), (.pairedVideo, 300)]), entries: livePhoto, server: server))
        // The server file was replaced by another one (another id).
        let replaced = [entry("a", .photo, state: .uploaded, path: "/Photos/2024/05/IMG_1.HEIC", fileId: 9), livePhoto[1]]
        #expect(!DeviceCleanup.isVerified(local("a", [(.photo, 100), (.pairedVideo, 300)]), entries: replaced, server: server))
        // Gone from the server.
        let gone = [entry("b", .photo, state: .uploaded, path: "/Photos/2024/05/IMG_9.HEIC")]
        #expect(!DeviceCleanup.isVerified(local("b", [(.photo, 100)]), entries: gone, server: server))
        // Not complete in the ledger.
        let waiting = [entry("c", .photo, state: .pending, path: "/Photos/2024/05/IMG_2.jpg")]
        #expect(!DeviceCleanup.isVerified(local("c", [(.photo, 80)]), entries: waiting, server: server))
        // Nothing required, or something the backup never uploads.
        #expect(!DeviceCleanup.isVerified(local("d", []), entries: [], server: server))
        var editedMotion = local("e", [(.photo, 80)])
        editedMotion.hasUnbackedResource = true
        let edited = [entry("e", .photo, state: .uploaded, path: "/Photos/2024/05/IMG_2.jpg")]
        #expect(DeviceCleanup.isVerified(local("e", [(.photo, 80)]), entries: edited, server: server))
        #expect(!DeviceCleanup.isVerified(editedMotion, entries: edited, server: server))
    }

    @Test func onlyCompleteLedgerAssetsWithServerPathsAreLookedAt() {
        let ledger: [String: [BackupLedgerEntry]] = [
            "a": [entry("a", state: .uploaded, path: "/Photos/a.jpg")],
            // The Files app's record has no server path: it cannot be verified.
            "b": [entry("b", state: .matched)],
            "c": [entry("c", state: .uploaded, path: "/Photos/c.jpg"), entry("c", .pairedVideo, state: .failed, path: "/Photos/c.mov")],
            "d": [entry("d", state: .matched, path: "/Other/d.jpg")],
        ]
        #expect(DeviceCleanup.ledgerCandidates(ledger) == ["a", "d"])
        #expect(DeviceCleanup.folders(of: ledger.values.flatMap { $0 }) == ["/Photos", "/Other"])
    }

    @Test func recentPhotosNeedTheUsersChoice() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        #expect(DeviceCleanup.isOldEnough(now.addingTimeInterval(-31 * 86_400), now: now))
        #expect(!DeviceCleanup.isOldEnough(now.addingTimeInterval(-29 * 86_400), now: now))
        #expect(!DeviceCleanup.isOldEnough(nil, now: now))
    }

    final class FakeListing: ServerFileListing {
        let files: [String: [String: ServerFileInfo]]
        let asked = Mutex<[String]>([])

        init(_ files: [String: [String: ServerFileInfo]]) {
            self.files = files
        }

        func files(in folder: String) async throws -> [String: ServerFileInfo] {
            asked.withLock { $0.append(folder) }
            return files[folder] ?? [:]
        }
    }

    @Test func verificationListsEachFolderOnceAndKeepsOnlyVerifiedAssets() async throws {
        let ledger: [String: [BackupLedgerEntry]] = [
            "a": [entry("a", state: .uploaded, path: "/Photos/2024/05/a.jpg")],
            "b": [entry("b", state: .uploaded, path: "/Photos/2024/05/b.jpg")],
            "c": [entry("c", state: .matched, path: "/Photos/2023/01/c.jpg")],
        ]
        let listing = FakeListing([
            "/Photos/2024/05": [
                "/Photos/2024/05/a.jpg": ServerFileInfo(fileId: nil, size: 10),
                "/Photos/2024/05/b.jpg": ServerFileInfo(fileId: nil, size: 11),
            ],
            "/Photos/2023/01": ["/Photos/2023/01/c.jpg": ServerFileInfo(fileId: nil, size: 30)],
        ])
        let progress = Mutex<[Int]>([])
        let result = try await DeviceCleanup.verify(
            [local("a", [(.photo, 10)]), local("b", [(.photo, 10)]), local("c", [(.photo, 30)])], ledger: ledger, listing: listing,
            progress: { checked, _ in progress.withLock { $0.append(checked) } })
        #expect(result.map(\.localIdentifier) == ["a", "c"])
        #expect(result.map(\.byteSize) == [10, 30])
        #expect(listing.asked.withLock { $0 }.sorted() == ["/Photos/2023/01", "/Photos/2024/05"])
        #expect(progress.withLock { $0 } == [1, 2])
    }
}
