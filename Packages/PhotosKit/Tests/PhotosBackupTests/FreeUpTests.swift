// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking

/// Free up space on this device (SPEC §22.1): every rule that keeps a photo on the device, the server check with
/// checksums, the estimate, and the options.
@Suite struct FreeUpTests {
    typealias Local = DeviceCleanup.LocalAsset

    let now = Date(timeIntervalSince1970: 1_000 * 86_400)
    var old: Date { now.addingTimeInterval(-400 * 86_400) }

    func entry(
        _ id: String, _ kind: BackupResourceKind = .photo, state: BackupItemState = .uploaded, path: String? = nil, fileId: Int64? = nil,
        size: Int64? = nil, updatedAt: Double = 0
    ) -> BackupLedgerEntry {
        BackupLedgerEntry(
            localIdentifier: id, resourceKind: kind.rawValue, fingerprint: size.map { "size:\($0)" }, state: state.rawValue,
            serverPath: path ?? "/Photos/\(id).\(kind.rawValue)", serverFileId: fileId, serverEtag: nil, matchedBy: nil, attempts: 0,
            lastError: nil, assetCreatedAt: nil, assetModifiedAt: nil, updatedAt: updatedAt)
    }

    func local(_ id: String, _ kinds: [BackupResourceKind] = [.photo], size: Int64 = 100, created: Date? = nil) -> Local {
        Local(
            localIdentifier: id, createdAt: created ?? old,
            required: kinds.enumerated().map { Local.Resource(kind: $1, byteSize: size, index: $0) },
            totalSize: size * Int64(kinds.count))
    }

    func ledger(_ assets: [Local]) -> [String: [BackupLedgerEntry]] {
        Dictionary(
            uniqueKeysWithValues: assets.map { asset in
                (asset.localIdentifier, asset.required.map { entry(asset.localIdentifier, $0.kind, size: $0.byteSize) })
            })
    }

    /// The server has each file of the assets with the device's size (and optional checksums).
    func server(_ assets: [Local], checksums: [String: [ChecksumAlgorithm: String]] = [:]) -> FakeListing {
        var files: [String: ServerFileInfo] = [:]
        for asset in assets {
            for resource in asset.required {
                files["/Photos/\(asset.localIdentifier).\(resource.kind.rawValue)"] = ServerFileInfo(
                    fileId: nil, size: resource.byteSize ?? 0, checksums: checksums[asset.localIdentifier] ?? [:])
            }
        }
        return FakeListing(["/Photos": files])
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

    /// Device digests per asset id; nil: the data is not on the device.
    final class FakeDigester: ResourceDigesting {
        let digests: [String: String?]
        let asked = Mutex<[String]>([])

        init(_ digests: [String: String?]) {
            self.digests = digests
        }

        func digest(of resource: DeviceResourceReference, algorithm: ChecksumAlgorithm) async throws -> String? {
            asked.withLock { $0.append("\(resource.localIdentifier) \(algorithm.rawValue)") }
            return digests[resource.localIdentifier] ?? nil
        }
    }

    // MARK: Keep options

    @Test func favouritesHiddenAndRecentPhotosStayAsTheUserChooses() {
        var favorite = local("fav")
        favorite.isFavorite = true
        var hidden = local("hidden")
        hidden.isHidden = true
        let recent = local("recent", created: now.addingTimeInterval(-3 * 86_400))
        let entries = ledger([favorite, hidden, recent])
        let keepAll = FreeUpOptions(keepRecent: .week, keepFavorites: true, keepHidden: true)
        #expect(DeviceCleanup.keepReason(favorite, entries: entries["fav"]!, options: keepAll, now: now) == .favorite)
        #expect(DeviceCleanup.keepReason(hidden, entries: entries["hidden"]!, options: keepAll, now: now) == .hidden)
        #expect(DeviceCleanup.keepReason(recent, entries: entries["recent"]!, options: keepAll, now: now) == .recent)
        let keepNothing = FreeUpOptions(keepRecent: .none, keepFavorites: false, keepHidden: false)
        for asset in [favorite, hidden, recent] {
            #expect(DeviceCleanup.keepReason(asset, entries: entries[asset.localIdentifier]!, options: keepNothing, now: now) == nil)
        }
        // A photo of three days is not kept by "last 7 days" once it is older than that.
        #expect(
            DeviceCleanup.keepReason(recent, entries: entries["recent"]!, options: keepAll, now: now.addingTimeInterval(5 * 86_400)) == nil)
        // One reason per photo, the first that holds: a hidden favourite counts as hidden.
        var both = hidden
        both.isFavorite = true
        #expect(DeviceCleanup.keepReason(both, entries: entries["hidden"]!, options: keepAll, now: now) == .hidden)
    }

    @Test func sharedAlbumAndSyncedItemsAlwaysStay() {
        var shared = local("shared")
        shared.isInUserLibrary = false
        let keepNothing = FreeUpOptions(keepRecent: .none, keepFavorites: false, keepHidden: false)
        #expect(DeviceCleanup.keepReason(shared, entries: ledger([shared])["shared"]!, options: keepNothing, now: now) == .notInLibrary)
    }

    @Test func keepPeriodsCountBackFromNow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(FreeUpKeepPeriod.none.cutoff(now: now, calendar: calendar) == nil)
        #expect(FreeUpKeepPeriod.week.cutoff(now: now, calendar: calendar) == now.addingTimeInterval(-7 * 86_400))
        #expect(FreeUpKeepPeriod.month.cutoff(now: now, calendar: calendar) == now.addingTimeInterval(-30 * 86_400))
        #expect(FreeUpKeepPeriod.threeMonths.cutoff(now: now, calendar: calendar) == calendar.date(byAdding: .month, value: -3, to: now))
        #expect(FreeUpKeepPeriod.sixMonths.cutoff(now: now, calendar: calendar) == calendar.date(byAdding: .month, value: -6, to: now))
        #expect(FreeUpKeepPeriod.year.cutoff(now: now, calendar: calendar) == calendar.date(byAdding: .year, value: -1, to: now))
    }

    // MARK: Edits

    @Test func editedOriginalsStayUnlessTheirEditIsBackedUp() {
        let options = FreeUpOptions(keepRecent: .none)
        let editedAt = now.addingTimeInterval(-10 * 86_400)
        // Edited, edit backed up after the edit: only the server decides.
        var edited = local("e", [.photo, .edited])
        edited.isUserEdited = true
        edited.editedAt = editedAt
        let backedUp = [
            entry("e", .photo, updatedAt: editedAt.timeIntervalSince1970 - 100),
            entry("e", .edited, updatedAt: editedAt.timeIntervalSince1970 + 60),
        ]
        #expect(DeviceCleanup.keepReason(edited, entries: backedUp, options: options, now: now) == nil)
        // Edited again after its edit was backed up.
        let stale = [backedUp[0], entry("e", .edited, updatedAt: editedAt.timeIntervalSince1970 - 3_600)]
        #expect(DeviceCleanup.keepReason(edited, entries: stale, options: options, now: now) == .editNotBackedUp)
        // The backup keeps originals only: the ledger has no edited version.
        #expect(DeviceCleanup.keepReason(edited, entries: [backedUp[0]], options: options, now: now) == .editNotBackedUp)
        // The edited version waits for its upload.
        let waiting = [backedUp[0], entry("e", .edited, state: .pending, updatedAt: editedAt.timeIntervalSince1970 + 60)]
        #expect(DeviceCleanup.keepReason(edited, entries: waiting, options: options, now: now) == .editNotBackedUp)
        // Edited but PhotoKit has no rendered version of the edit.
        var unrendered = local("u", [.photo])
        unrendered.isUserEdited = true
        #expect(DeviceCleanup.keepReason(unrendered, entries: [entry("u")], options: options, now: now) == .editNotBackedUp)
        // Not edited by the user (no rule; an automatic camera adjustment needs its version on the server like any file).
        #expect(DeviceCleanup.keepReason(local("p"), entries: [entry("p")], options: options, now: now) == nil)
        let videoEdit = Local(
            localIdentifier: "v", createdAt: old,
            required: [Local.Resource(kind: .video, byteSize: 5), Local.Resource(kind: .editedVideo, byteSize: 6)], totalSize: 11,
            isUserEdited: true, editedAt: editedAt)
        let video = [entry("v", .video), entry("v", .editedVideo, updatedAt: editedAt.timeIntervalSince1970)]
        #expect(DeviceCleanup.keepReason(videoEdit, entries: video, options: options, now: now) == nil)
    }

    @Test func aPhotoWithAFileTheServerDoesNotHaveStays() {
        let options = FreeUpOptions(keepRecent: .none)
        // A Live Photo whose motion the backup left out (Live Photos off).
        let live = local("l", [.photo, .pairedVideo])
        #expect(DeviceCleanup.keepReason(live, entries: [entry("l")], options: options, now: now) == .incomplete)
        // A RAW file that was matched without a server path.
        let raw = local("r", [.photo, .raw])
        let noPath = BackupLedgerEntry(
            localIdentifier: "r", resourceKind: "raw", fingerprint: nil, state: "matched", serverPath: nil, serverFileId: nil,
            serverEtag: nil, matchedBy: nil, attempts: 0, lastError: nil, assetCreatedAt: nil, assetModifiedAt: nil, updatedAt: 0)
        #expect(DeviceCleanup.keepReason(raw, entries: [entry("r"), noPath], options: options, now: now) == .incomplete)
        // The edited motion of a Live Photo is never uploaded.
        var editedMotion = local("m")
        editedMotion.hasUnbackedResource = true
        #expect(DeviceCleanup.keepReason(editedMotion, entries: [entry("m")], options: options, now: now) == .incomplete)
        // Nothing PhotoKit would give the backup.
        #expect(DeviceCleanup.keepReason(local("n", []), entries: [], options: options, now: now) == .incomplete)
    }

    // MARK: The plan

    @Test func thePlanCountsEveryPhotoOnceAndListsOnlyTheFoldersItNeeds() async throws {
        var favorite = local("1-fav", size: 1_000)
        favorite.isFavorite = true
        let recent = local("2-recent", size: 2_000, created: now.addingTimeInterval(-86_400))
        let gone = local("3-gone", size: 300)
        let changed = local("4-changed", size: 400)
        let first = local("5-ok", size: 500, created: old.addingTimeInterval(86_400))
        let second = local("6-ok", [.photo, .pairedVideo], size: 600, created: old)
        let assets = [favorite, recent, gone, changed, first, second]
        var entries = ledger(assets)
        // The favourite's file is in a folder of its own: it stays anyway, so that folder is not listed.
        entries["1-fav"] = [entry("1-fav", path: "/Favorites/1-fav.photo")]
        var listing = server([recent, changed, first, second]).files["/Photos"]!
        listing["/Photos/4-changed.photo"]?.size = 401
        let fake = FakeListing(["/Photos": listing])
        let plan = try await DeviceCleanup.plan(
            assets, ledger: entries, options: FreeUpOptions(keepRecent: .month), listing: fake, now: now)
        // Oldest first.
        #expect(plan.candidates.map(\.localIdentifier) == ["6-ok", "5-ok"])
        #expect(plan.bytes == 1_200 + 500)
        #expect(plan.kept[.favorite] == FreeUpTally(count: 1, bytes: 1_000))
        #expect(plan.kept[.recent] == FreeUpTally(count: 1, bytes: 2_000))
        #expect(plan.kept[.notVerified] == FreeUpTally(count: 2, bytes: 700))
        #expect(plan.keptCount == 4)
        #expect(fake.asked.withLock { $0 } == ["/Photos"])
    }

    @Test func aFileReplacedOnTheServerIsNotTheOneThatWasBackedUp() async throws {
        let asset = local("a")
        let entries = ["a": [entry("a", fileId: 7)]]
        let replaced = FakeListing(["/Photos": ["/Photos/a.photo": ServerFileInfo(fileId: 8, size: 100)]])
        let plan = try await DeviceCleanup.plan(
            [asset], ledger: entries, options: FreeUpOptions(keepRecent: .none), listing: replaced, now: now)
        #expect(plan.candidates.isEmpty)
        #expect(plan.kept[.notVerified]?.count == 1)
    }

    // MARK: Checksums

    @Test func theServersChecksumsAreRead() {
        let parsed = ServerFileInfo.parseChecksums(["SHA1:AbC123 MD5:ff00 ADLER32:0a0b", "sha256:00ff", "SHA3:12", "MD5:", "SHA1:zz"])
        #expect(parsed == [.sha1: "abc123", .md5: "ff00", .sha256: "00ff"])
        #expect(ServerFileInfo(fileId: nil, size: 1, checksums: parsed).preferredChecksum?.algorithm == .sha256)
        #expect(ServerFileInfo(fileId: nil, size: 1, checksums: [.md5: "ff00"]).preferredChecksum?.digest == "ff00")
        #expect(ServerFileInfo(fileId: nil, size: 1).preferredChecksum == nil)
        #expect(ServerFileInfo.parseChecksums([""]).isEmpty)
    }

    @Test func streamingDigestsMatchKnownValues() {
        // `printf 'hello free up' | shasum -a 256`, and the classic "abc" vectors.
        #expect(
            StreamingDigest.digest(Data("hello free up".utf8), .sha256)
                == "7b064b221c8f9c0474d9604f5891e32d5bf9c431e60c25d5ea4a8055d5a7d972")
        #expect(StreamingDigest.digest(Data("abc".utf8), .sha1) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(StreamingDigest.digest(Data("abc".utf8), .md5) == "900150983cd24fb0d6963f7d28e17f72")
        // Fed in parts like PhotoKit does.
        let parts = StreamingDigest(.sha256)
        parts.update(Data("hello ".utf8))
        parts.update(Data("free up".utf8))
        #expect(parts.finish() == StreamingDigest.digest(Data("hello free up".utf8), .sha256))
    }

    @Test func theCheckRightBeforeTheRemovalComparesChecksums() async throws {
        let same = local("same")
        let differs = local("differs")
        let onlyInICloud = local("cloud")
        let noChecksum = local("plain")
        let assets = [same, differs, onlyInICloud, noChecksum]
        let listing = server(
            assets, checksums: ["same": [.sha256: "aa"], "differs": [.sha256: "aa"], "cloud": [.sha1: "bb"]])
        let digests: [String: String?] = ["same": "AA", "differs": "ab", "cloud": String?.none]
        let digester = FakeDigester(digests)
        let progress = Mutex<[FreeUpProgress]>([])
        let plan = try await DeviceCleanup.plan(
            assets, ledger: ledger(assets), options: FreeUpOptions(keepRecent: .none), listing: listing, digester: digester, now: now,
            progress: { value in progress.withLock { $0.append(value) } })
        // Same checksum, or the data is not on the device (checked by size), or the server keeps no checksum.
        #expect(Set(plan.candidates.map(\.localIdentifier)) == ["same", "cloud", "plain"])
        #expect(plan.kept[.notVerified]?.count == 1)
        // The digester is only asked where the server has a checksum, with the server's algorithm.
        #expect(Set(digester.asked.withLock { $0 }) == ["same SHA256", "differs SHA256", "cloud SHA1"])
        #expect(progress.withLock { $0 }.last == .hashing(done: 4, total: 4))
        // Without a digester (the first check) nothing is hashed.
        let quick = try await DeviceCleanup.plan(
            assets, ledger: ledger(assets), options: FreeUpOptions(keepRecent: .none), listing: listing, now: now)
        #expect(quick.candidates.count == 4)
    }

    // MARK: Estimate and options

    @Test func theEstimateUsesTheSizesTheLedgerRecorded() {
        #expect(DeviceCleanup.recordedSize(entry("a", size: 1234)) == 1234)
        #expect(DeviceCleanup.recordedSize(entry("a")) == nil)
        var favorite = local("fav", size: 5_000)
        favorite.isFavorite = true
        let assets = [favorite, local("a", size: 60_000_000), local("b", [.photo, .pairedVideo], size: 30_000_000)]
        let estimate = DeviceCleanup.estimate(assets, ledger: ledger(assets), options: FreeUpOptions(), now: now)
        #expect(estimate == FreeUpEstimate(count: 2, bytes: 120_000_000))
        #expect(estimate.isWorthOffering)
        #expect(!FreeUpEstimate(count: 3, bytes: 99_000_000).isWorthOffering)
        #expect(!FreeUpEstimate(count: 0, bytes: 0).isWorthOffering)
    }

    @Test func storedOptionsKeepTheirDefaults() throws {
        let empty = try JSONDecoder().decode(FreeUpOptions.self, from: Data("{}".utf8))
        #expect(empty == FreeUpOptions())
        #expect(empty.keepRecent == .month && empty.keepFavorites && empty.keepHidden)
        let unknown = try JSONDecoder().decode(FreeUpOptions.self, from: Data(#"{"keepRecent":"decade","keepHidden":false}"#.utf8))
        #expect(unknown == FreeUpOptions(keepRecent: .month, keepFavorites: true, keepHidden: false))
        let options = FreeUpOptions(keepRecent: .sixMonths, keepFavorites: false, keepHidden: true)
        #expect(try JSONDecoder().decode(FreeUpOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test func keepReasonsAreInTheOrderTheRulesApply() {
        #expect(FreeUpKeepReason.allCases.sorted() == FreeUpKeepReason.allCases)
        #expect(FreeUpKeepReason.notInLibrary < .notVerified)
    }
}
