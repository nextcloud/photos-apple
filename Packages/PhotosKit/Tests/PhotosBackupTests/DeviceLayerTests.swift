// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosStore

/// Round 11, items 1 and 2 (SPEC §21.1): device photos in the Library, the backup summary, "Back up now" on a selection.
@Suite struct DeviceLayerTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func entry(_ id: String, _ kind: BackupResourceKind = .photo, state: BackupItemState, error: String? = nil) -> BackupLedgerEntry {
        BackupLedgerEntry(
            localIdentifier: id, resourceKind: kind.rawValue, fingerprint: nil, state: state.rawValue, serverPath: nil,
            serverFileId: nil, serverEtag: nil, matchedBy: nil, attempts: 0, lastError: error, assetCreatedAt: nil,
            assetModifiedAt: nil, updatedAt: 0)
    }

    func item(_ id: String, at offset: TimeInterval, video: Bool = false, favorite: Bool = false) -> DeviceLibraryItem {
        DeviceLibraryItem(
            localIdentifier: id, createdAt: t0 + offset, isVideo: video, isFavorite: favorite, pixelWidth: 4032, pixelHeight: 3024,
            duration: video ? 12 : 0)
    }

    func server(_ id: FileID, at offset: TimeInterval, video: Bool = false) -> GridMedia {
        GridMedia(
            MediaItem(
                fileId: id, path: "/Photos/IMG_\(id).HEIC", mimeType: video ? "video/quicktime" : "image/heic", capturedAt: t0 + offset))
    }

    // MARK: Ids

    @Test func deviceIdsAreNegativeStableAndDistinct() {
        let a = DeviceMediaID.id(for: "4E5F6A7B-0000/L0/001")
        #expect(a < 0)
        #expect(a == DeviceMediaID.id(for: "4E5F6A7B-0000/L0/001"))
        #expect(a != DeviceMediaID.id(for: "4E5F6A7B-0001/L0/001"))
        #expect(DeviceMediaID.isDevice(a))
        #expect(!DeviceMediaID.isDevice(42))
        // FNV-1a of the empty string, with the sign bit cleared and moved below zero.
        #expect(DeviceMediaID.id(for: "") == -Int64(UInt64(0xcbf2_9ce4_8422_2325) & 0x7fff_ffff_ffff_ffff) - 1)
        var seen = Set<FileID>()
        for index in 0..<100_000 { seen.insert(DeviceMediaID.id(for: "\(UUID().uuidString)/L0/\(index)")) }
        #expect(seen.count == 100_000)
        #expect(seen.allSatisfy { $0 < 0 })
    }

    // MARK: Ledger

    @Test func onlyServerConfirmedResourcesCountAsBackedUp() throws {
        let database = try AccountDatabase.temporary()
        try database.writer.write { db in
            try entry("done", state: .uploaded).insert(db)
            try entry("live", .photo, state: .matched).insert(db)
            try entry("live", .pairedVideo, state: .matched).insert(db)
            // The still is there, its motion part is not: not backed up.
            try entry("half", .photo, state: .uploaded).insert(db)
            try entry("half", .pairedVideo, state: .pending).insert(db)
            try entry("broken", state: .failed, error: "Read-only folder").insert(db)
            try entry("cloud", state: .skipped).insert(db)
            try entry("cloudEdit", .photo, state: .uploaded).insert(db)
            try entry("cloudEdit", .edited, state: .skipped).insert(db)
        }
        let states = try DeviceLedger.load(database)
        #expect(states["done"] == .backedUp)
        #expect(states["live"] == .backedUp)
        #expect(states["half"] == .waiting)
        #expect(states["broken"] == .failed("Read-only folder"))
        #expect(states["cloud"] == .onlyInICloud)
        #expect(states["cloudEdit"] == .onlyInICloud)
        #expect(states["unknown"] == nil)
        // The SQL and the per-entry rule agree.
        #expect(DeviceLedgerState.of([entry("x", state: .uploaded), entry("x", .pairedVideo, state: .pending)]) == .waiting)
        #expect(DeviceLedgerState.of([entry("x", state: .skipped)]) == .onlyInICloud)
        #expect(DeviceLedgerState.of([]) == .waiting)
    }

    // MARK: Snapshot

    @Test func theSnapshotHoldsWhatIsNotOnTheServerNewestFirst() {
        let library = [item("old", at: 0), item("done", at: 10), item("new", at: 30), item("broken", at: 20), item("going", at: 25)]
        let ledger: [String: DeviceLedgerState] = ["done": .backedUp, "broken": .failed("No space"), "going": .waiting]
        let snapshot = DeviceLayerBuilder.build(library: library, ledger: ledger, inFlight: ["going"])
        #expect(snapshot.assets.map(\.localIdentifier) == ["new", "going", "broken", "old"])
        #expect(snapshot.covered == 5)
        #expect(snapshot.backedUp == 1)
        #expect(snapshot.notBackedUp == 4)
        #expect(snapshot.uploading == 1)
        #expect(snapshot.failed == 1)
        let going = DeviceMediaID.id(for: "going")
        #expect(snapshot[going]?.badge == .uploading)
        #expect(snapshot[DeviceMediaID.id(for: "broken")]?.failure == "No space")
        #expect(snapshot[DeviceMediaID.id(for: "done")] == nil)
        // Not in the ledger yet: the backup has not looked at it.
        #expect(snapshot[DeviceMediaID.id(for: "new")]?.isUnchecked == true)
        #expect(snapshot[going]?.isUnchecked == false)
        #expect(snapshot.localIdentifiers(of: [going, 7, DeviceMediaID.id(for: "old")]) == ["going", "old"])
    }

    @Test func theDirectoryFindsTheIdentifierOfAnId() {
        let directory = DeviceAssetDirectory()
        let snapshot = DeviceLayerBuilder.build(library: [item("a/L0/001", at: 0)], ledger: [:], inFlight: [])
        directory.register(snapshot)
        #expect(directory.localIdentifier(of: DeviceMediaID.id(for: "a/L0/001")) == "a/L0/001")
        #expect(directory.localIdentifier(of: -5) == nil)
    }

    // MARK: Timeline

    @Test func devicePhotosAreMergedByCaptureTime() {
        let device = DeviceLayerBuilder.build(
            library: [item("d1", at: 50), item("d2", at: 15), item("d3", at: -10)],
            ledger: ["d1": .waiting, "d2": .waiting, "d3": .waiting], inFlight: []
        ).assets
        let merged = DeviceTimeline.merge(server: [server(1, at: 40), server(2, at: 20), server(3, at: 0)], device: device)
        #expect(
            merged.map(\.fileId) == [
                DeviceMediaID.id(for: "d1"), 1, 2, DeviceMediaID.id(for: "d2"), 3, DeviceMediaID.id(for: "d3"),
            ])
        // Sorted for the timeline's sections: newest first.
        #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.timestamp >= $1.timestamp })
        let tile = merged[0]
        #expect(tile.deviceBadge == .waiting)
        #expect(tile.timestamp == t0 + 50)
        #expect(tile.aspectRatio == 4032.0 / 3024.0)
        #expect(tile.directory == DeviceTimeline.directory)
        #expect(merged[1].deviceBadge == nil)
    }

    @Test func aPhotoTheBackupHasNotCheckedIsNotShownTwice() {
        // "dup" was taken in the same second as server photo 1 (most likely that photo, uploaded by another app); the
        // backup has not looked at it yet. "checked" has the same second as server photo 2, but the backup asked the
        // server and did not find it: it is shown.
        let device = DeviceLayerBuilder.build(
            library: [item("dup", at: 40.3), item("checked", at: 20), item("video", at: 40, video: true)],
            ledger: ["checked": .waiting], inFlight: []
        ).assets
        let merged = DeviceTimeline.merge(server: [server(1, at: 40), server(2, at: 20)], device: device)
        #expect(merged.map(\.fileId) == [1, DeviceMediaID.id(for: "video"), 2, DeviceMediaID.id(for: "checked")])
    }

    @Test func filtersShowTheirDevicePhotos() {
        let snapshot = DeviceLayerBuilder.build(
            library: [item("p", at: 3), item("v", at: 2, video: true), item("f", at: 1, favorite: true)], ledger: [:], inFlight: [])
        #expect(DeviceTimeline.assets(snapshot, kind: .all).map(\.localIdentifier) == ["p", "v", "f"])
        #expect(DeviceTimeline.assets(snapshot, kind: .photos).map(\.localIdentifier) == ["p", "f"])
        #expect(DeviceTimeline.assets(snapshot, kind: .videos).map(\.localIdentifier) == ["v"])
        #expect(DeviceTimeline.assets(snapshot, kind: .favorites).map(\.localIdentifier) == ["f"])
        #expect(DeviceTimeline.assets(snapshot, kind: .archived).isEmpty)
        let video = DeviceTimeline.mediaItem(snapshot.assets[1])
        #expect(video.kind == .video)
        #expect(video.duration == 12)
        #expect(!video.permissions.canDelete)
        #expect(!video.isOwnStorage)
    }

    /// 100 000 server photos and 100 000 device photos: the snapshot and the merge stay well under a frame's worth of
    /// main-thread time each (they run off the main thread; this guards against an accidental quadratic step).
    @Test func aHundredThousandPhotosMergeQuickly() {
        let count = 100_000
        let library = (0..<count).map { item("device-\($0)", at: TimeInterval($0) * 60 + 30) }
        let serverItems = (0..<count).reversed().map { server(FileID($0 + 1), at: TimeInterval($0) * 60) }
        let clock = ContinuousClock()
        var snapshot = DeviceLayerSnapshot.empty
        let built = clock.measure { snapshot = DeviceLayerBuilder.build(library: library, ledger: [:], inFlight: []) }
        var merged: [GridMedia] = []
        let merging = clock.measure { merged = DeviceTimeline.merge(server: serverItems, device: snapshot.assets) }
        #expect(merged.count == 2 * count)
        #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.timestamp >= $1.timestamp })
        print("device layer: build \(built), merge \(merging) for \(count) + \(count)")
        #expect(built < timingBudget(.seconds(3)))
        #expect(merging < timingBudget(.seconds(3)))
    }

    // MARK: Summary

    @Test func theSummaryIsHonest() {
        let none = DeviceLayerSnapshot.empty
        let some = DeviceLayerBuilder.build(
            library: [item("a", at: 0), item("b", at: 1), item("c", at: 2)], ledger: ["a": .backedUp, "b": .failed(nil)], inFlight: [])
        let sending = DeviceLayerBuilder.build(library: [item("a", at: 0)], ledger: [:], inFlight: ["a"])
        #expect(BackupSummary(isEnabled: false, isLoaded: true, snapshot: none, isRunning: false) == .off)
        #expect(BackupSummary(isEnabled: true, isLoaded: false, snapshot: none, isRunning: false) == .checking)
        #expect(BackupSummary(isEnabled: true, isLoaded: true, snapshot: none, isRunning: false) == .allBackedUp)
        #expect(BackupSummary(isEnabled: true, isLoaded: true, snapshot: some, isRunning: false) == .notBackedUp(2, failed: 1))
        #expect(BackupSummary(isEnabled: true, isLoaded: true, snapshot: some, isRunning: true) == .backingUp(remaining: 2))
        // Handed to the system is not on the server.
        #expect(BackupSummary(isEnabled: true, isLoaded: true, snapshot: sending, isRunning: false) == .backingUp(remaining: 1))
        #expect(BackupSummary.notBackedUp(1, failed: 0).hasRemaining)
        #expect(!BackupSummary.allBackedUp.hasRemaining)
    }

    @Test func theNewOptionDefaultsToOnAndOldSettingsKeepIt() throws {
        #expect(BackupSettings().showsDeviceInLibrary)
        let old = try JSONDecoder().decode(BackupSettings.self, from: Data(#"{"isEnabled":true,"folder":"/Camera"}"#.utf8))
        #expect(old.showsDeviceInLibrary)
        #expect(old.folder == "/Camera")
        var off = BackupSettings()
        off.showsDeviceInLibrary = false
        let decoded = try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(off))
        #expect(!decoded.showsDeviceInLibrary)
    }
}

/// "Back up now" on a selection and the arrow of what is uploading (SPEC §21.1), with the engine's fakes.
@Suite(.timeLimit(.minutes(1))) struct BackUpNowTests {
    let library = FakeLibrary()
    let remote = FakeRemote()
    let clock = Clock()
    let statuses = StatusLog()
    let engine: BackupEngine
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        let clock = clock
        engine = BackupEngine(
            library: library, remote: remote, database: try .temporary(), accountId: AccountID(rawValue: "test"), now: { clock.now })
        let statuses = statuses
        await engine.setStatusHandler { status in statuses.values.withLock { $0.append(status) } }
    }

    var settings: BackupSettings {
        var settings = BackupSettings()
        settings.isEnabled = true
        return settings
    }

    func addPhotos(_ ids: [String]) {
        library.state.withLock { state in
            for id in ids {
                let offset = TimeInterval(state.assets.count) * 3600
                let resource = BackupResource(
                    localIdentifier: id, kind: .photo, mediaKind: .image, originalName: "IMG_\(id).HEIC", createdAt: t0 + offset,
                    modifiedAt: t0, pixelWidth: 0, pixelHeight: 0, byteSize: 10)
                state.assets.append(.init(id: id, modifiedAt: t0, resources: [resource]))
            }
        }
    }

    @Test func aSelectionGoesFirstAndAFailedOneDoesNotWait() async throws {
        addPhotos(["0001", "0002", "0003"])
        library.state.withLock { $0.exportErrors["IMG_0003.HEIC"] = CocoaError(.fileReadCorruptFile) }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0002.heic"])
        library.state.withLock { $0.exportErrors = [:] }
        addPhotos(["0004", "0005"])

        // Without the request, 0003 waits for its next attempt (15 minutes) and the others go oldest first.
        await engine.prioritize(["0005", "0003"])
        await engine.run(settings)
        #expect(Array(remote.uploads.dropFirst(2)) == ["IMG_0003.heic", "IMG_0005.heic", "IMG_0004.heic"])
        #expect(statuses.last.phase == .upToDate)

        // The request was carried out: later passes are in the usual order again.
        addPhotos(["0006", "0007"])
        await engine.run(settings)
        #expect(Array(remote.uploads.suffix(2)) == ["IMG_0006.heic", "IMG_0007.heic"])
    }

    @Test func theStatusNamesWhatIsUploadingAndForgetsItAfterwards() async throws {
        addPhotos(["0001", "0002"])
        let seen = Mutex<[Set<String>]>([])
        let statuses = statuses
        remote.beforeUpload.withLock {
            $0 = { _ in seen.withLock { $0.append(statuses.last.uploadingIdentifiers) } }
        }
        await engine.run(settings)
        #expect(seen.withLock { $0 } == [["0001"], ["0002"]])
        #expect(statuses.last.uploadingIdentifiers.isEmpty)
        #expect(statuses.last.phase == .upToDate)
    }
}

/// Device photos and the timeline's stacks (with the best-shot package's burst stacks, SPEC §21.4).
@Suite struct DeviceLayerStackTests {
    @Test func devicePhotosAreNeverCopiesOfEachOtherAndKeepTheirBurst() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let library = [
            DeviceLibraryItem(localIdentifier: "a/L0/001", createdAt: t0, burstIdentifier: "BURST-1"),
            DeviceLibraryItem(localIdentifier: "b/L0/001", createdAt: t0 + 1),
        ]
        let merged = DeviceTimeline.merge(
            server: [], device: DeviceLayerBuilder.build(library: library, ledger: [:], inFlight: []).assets)
        // Same folder and close in time, but not the same shot.
        #expect(TimelineStacks.stacks(merged).isEmpty)
        #expect(Set(merged.map(\.name)).count == 2)
        #expect(merged.first { $0.fileId == DeviceMediaID.id(for: "a/L0/001") }?.burstIdentifier == "BURST-1")
        #expect(merged.first { $0.fileId == DeviceMediaID.id(for: "b/L0/001") }?.burstIdentifier == nil)
    }
}
