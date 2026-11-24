// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup
import PhotosStore
import Testing
import simd

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

// SPEC §15.4: photo frame and desktop picture rotation, the backup's Live Activity and widget, the memory room's layout.

@Suite struct AmbientRotationTests {
    @Test func seedIsStableAndDependsOnTheText() {
        #expect(AmbientRotation.seed("favorites") == AmbientRotation.seed("favorites"))
        #expect(AmbientRotation.seed("favorites") != AmbientRotation.seed("album:own:Holidays"))
        // FNV-1a of the empty text is its offset basis: the same in every process (unlike `Hasher`).
        #expect(AmbientRotation.seed("") == 0xcbf2_9ce4_8422_2325)
    }

    @Test func shuffledOrderIsAStablePermutation() {
        let order = AmbientRotation.shuffledOrder(count: 30, seed: 42)
        #expect(order.sorted() == Array(0..<30))
        #expect(order == AmbientRotation.shuffledOrder(count: 30, seed: 42))
        #expect(order != Array(0..<30))
        #expect(order != AmbientRotation.shuffledOrder(count: 30, seed: 43))
        #expect(AmbientRotation.shuffledOrder(count: 1, seed: 1) == [0])
        #expect(AmbientRotation.shuffledOrder(count: 0, seed: 1).isEmpty)
    }

    @Test func everyPhotoComesOnceBeforeAnyComesAgain() {
        let count = 7
        let seen = (100..<(100 + count)).compactMap { AmbientRotation.index(slot: $0, count: count, shuffledWith: 9) }
        #expect(Set(seen).count == count)
        // Slots before 1970 (negative) still map into the list.
        #expect(AmbientRotation.index(slot: -3, count: count, shuffledWith: nil) == 4)
        #expect(AmbientRotation.index(slot: 5, count: 0, shuffledWith: nil) == nil)
    }

    @Test func timelineStartsNowAndContinuesAtSlotStarts() {
        let interval: TimeInterval = 3600
        let now = Date(timeIntervalSince1970: 10 * 3600 + 1234)
        let entries = AmbientRotation.timeline(now: now, interval: interval, count: 4, itemCount: 10, seed: nil)
        #expect(entries.count == 4)
        #expect(entries[0].date == now)
        #expect(entries[1].date == Date(timeIntervalSince1970: 11 * 3600))
        #expect(entries[3].date == Date(timeIntervalSince1970: 13 * 3600))
        #expect(entries.map(\.index) == [0, 1, 2, 3])
        // The next timeline, an hour later, goes on with the photo after.
        let later = AmbientRotation.timeline(now: entries[1].date, interval: interval, count: 2, itemCount: 10, seed: nil)
        #expect(later.map(\.index) == [1, 2])
        #expect(AmbientRotation.timeline(now: now, interval: interval, count: 4, itemCount: 0, seed: nil).isEmpty)
    }

    @Test func orientationAndFit() {
        typealias O = AmbientRotation.Orientation
        #expect(O(width: 4000, height: 3000) == .landscape)
        #expect(O(width: 3000, height: 4000) == .portrait)
        #expect(O(width: 1000, height: 1050) == .square)
        #expect(O(width: nil, height: 10) == .square)
        #expect(O.landscape.fits(.landscape))
        #expect(!O.portrait.fits(.landscape))
        #expect(O.square.fits(.landscape))
        #expect(O.portrait.fits(.square))
    }

    @Test func nextPrefersThePhotosThatSuitTheScreen() {
        let orientations: [AmbientRotation.Orientation] = [.portrait, .portrait, .landscape, .portrait]
        let order = [0, 1, 2, 3]
        #expect(AmbientRotation.next(from: 0, order: order, orientations: orientations, screen: .landscape) == 2)
        #expect(AmbientRotation.next(from: 3, order: order, orientations: orientations, screen: .landscape) == 2)
        #expect(AmbientRotation.next(from: 1, order: order, orientations: orientations, screen: .portrait) == 1)
        // Nothing suits: the photo at the position.
        let allPortrait: [AmbientRotation.Orientation] = [.portrait, .portrait]
        #expect(AmbientRotation.next(from: 1, order: [0, 1], orientations: allPortrait, screen: .landscape) == 1)
        #expect(AmbientRotation.next(from: 0, order: [], orientations: [], screen: .landscape) == nil)
    }
}

@Suite struct BackupActivityTests {
    func status(_ phase: BackupStatus.Phase, pending: Int = 0, bytes: Int64 = 0, uploaded: Int = 0, failed: Int = 0) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.pending = pending
        status.pendingBytes = bytes
        status.uploadedThisPass = uploaded
        status.failed = failed
        return status
    }

    @Test func uploadingCountsWhatIsLeftInThePass() throws {
        let state = try #require(
            BackupActivityState(status: status(.uploading(done: 3, total: 20, current: "IMG_1.HEIC"), bytes: 5_000_000)))
        #expect(state.phase == .uploading)
        #expect(state.remaining == 17)
        #expect(state.total == 20)
        #expect(state.remainingBytes == 5_000_000)
        #expect(state.fraction == 0.15)
        #expect(!state.isFinal)
        // No file name on the Lock Screen.
        #expect(state.detail?.contains("IMG") != true)
    }

    @Test func phasesMapToTheActivity() throws {
        #expect(BackupActivityState(status: status(.scanning))?.phase == .preparing)
        #expect(BackupActivityState(status: status(.reconciling(checked: 1, total: 9)))?.phase == .preparing)
        #expect(BackupActivityState(status: status(.reconciling(checked: 1, total: 9)))?.total == 9)
        let paused = try #require(BackupActivityState(status: status(.paused("Waiting for Wi-Fi"), pending: 4, uploaded: 2)))
        #expect(paused.phase == .paused)
        #expect(paused.message == "Waiting for Wi-Fi")
        #expect(paused.detail == "Waiting for Wi-Fi")
        #expect(paused.remaining == 4)
        let done = try #require(BackupActivityState(status: status(.upToDate, uploaded: 12)))
        #expect(done.phase == .done)
        #expect(done.isFinal)
        #expect(done.fraction == 1)
        let incomplete = try #require(BackupActivityState(status: status(.incomplete(failed: 2), uploaded: 5, failed: 2)))
        #expect(incomplete.phase == .done)
        #expect(incomplete.failed == 2)
        var blocked = status(.failed("HTTP 507"))
        blocked.blocker = .insufficientStorage
        let stopped = try #require(BackupActivityState(status: blocked))
        #expect(stopped.phase == .stopped)
        #expect(stopped.message == BackupOutcome.blocked(.insufficientStorage).message)
        #expect(BackupActivityState(status: status(.notAuthorized))?.phase == .stopped)
        var interrupted = status(.idle, pending: 3)
        interrupted.isInterrupted = true
        #expect(BackupActivityState(status: interrupted)?.phase == .paused)
        #expect(BackupActivityState(status: status(.idle)) == nil)
    }

    @Test func activityStartsOnlyForLargerPassesUnlessTheUserAsked() {
        let small = BackupActivityState(phase: .uploading, total: 3, remaining: 3)
        let many = BackupActivityState(phase: .uploading, total: 40, remaining: BackupActivityPolicy.minimumItems)
        let large = BackupActivityState(phase: .uploading, total: 2, remaining: 2, remainingBytes: 400 * 1024 * 1024)
        #expect(!BackupActivityPolicy.shouldStart(small, userRequested: false))
        #expect(BackupActivityPolicy.shouldStart(small, userRequested: true))
        #expect(BackupActivityPolicy.shouldStart(many, userRequested: false))
        #expect(BackupActivityPolicy.shouldStart(large, userRequested: false))
        // While many photos are still compared with the server (the user may leave the app before the uploads start).
        #expect(BackupActivityPolicy.shouldStart(BackupActivityState(phase: .preparing, total: 21), userRequested: false))
        #expect(!BackupActivityPolicy.shouldStart(BackupActivityState(phase: .preparing, total: 3), userRequested: false))
        #expect(!BackupActivityPolicy.shouldStart(BackupActivityState(phase: .paused, remaining: 50), userRequested: true))
        #expect(!BackupActivityPolicy.shouldStart(BackupActivityState(phase: .uploading, total: 5, remaining: 0), userRequested: true))
    }

    @Test func updatesAreThrottledWithinAPhase() {
        let now = Date()
        let a = BackupActivityState(phase: .uploading, done: 1, total: 20, remaining: 19)
        let b = BackupActivityState(phase: .uploading, done: 2, total: 20, remaining: 18)
        let paused = BackupActivityState(phase: .paused, message: "Waiting for Wi-Fi")
        #expect(BackupActivityPolicy.shouldUpdate(from: nil, to: a, last: nil, now: now))
        #expect(!BackupActivityPolicy.shouldUpdate(from: a, to: a, last: now.addingTimeInterval(-60), now: now))
        #expect(!BackupActivityPolicy.shouldUpdate(from: a, to: b, last: now.addingTimeInterval(-0.5), now: now))
        #expect(BackupActivityPolicy.shouldUpdate(from: a, to: b, last: now.addingTimeInterval(-3), now: now))
        // A new phase goes out at once.
        #expect(BackupActivityPolicy.shouldUpdate(from: a, to: paused, last: now, now: now))
    }

    @Test func aDoneBackupLeavesTheLockScreenAndAStoppedOneStays() {
        #expect(BackupActivityPolicy.dismissalDelay(BackupActivityState(phase: .done, done: 3, total: 3)) == TimeInterval(15 * 60))
        #expect(BackupActivityPolicy.dismissalDelay(BackupActivityState(phase: .done, failed: 1)) == nil)
        // Nothing was uploaded: gone at once.
        #expect(BackupActivityPolicy.dismissalDelay(BackupActivityState(phase: .done)) == 0)
        #expect(BackupActivityPolicy.dismissalDelay(BackupActivityState(phase: .stopped, message: "Full")) == nil)
    }
}

@Suite struct BackupWidgetSnapshotTests {
    @Test func savesAndLoads() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let file = BackupWidgetSnapshot.file(sandbox.layout)
        #expect(file.lastPathComponent == "backup-status.json")
        #expect(BackupWidgetSnapshot.load(from: file) == nil)
        let snapshot = BackupWidgetSnapshot(
            isEnabled: true, isSetUp: true, state: BackupActivityState(phase: .uploading, done: 1, total: 4, remaining: 3), pending: 3,
            lastRun: Date(timeIntervalSince1970: 1000), written: Date(timeIntervalSince1970: 2000))
        try snapshot.save(to: file)
        #expect(BackupWidgetSnapshot.load(from: file) == snapshot)
    }

    @Test func fromSettingsAndStatus() {
        var settings = BackupSettings()
        settings.isEnabled = true
        var status = BackupStatus()
        status.pending = 7
        let off = BackupWidgetSnapshot(settings: BackupSettings(), status: status)
        #expect(!off.isEnabled)
        #expect(!off.isSetUp)
        #expect(off.state == nil)
        settings.accountId = AccountID(rawValue: "alice https://cloud.example")
        let on = BackupWidgetSnapshot(settings: settings, status: status)
        #expect(on.isEnabled)
        #expect(on.isSetUp)
        #expect(on.pending == 7)
    }

    @MainActor @Test func presenceWritesWhatChangedAndReloadsSparingly() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let file = BackupWidgetSnapshot.file(sandbox.layout)
        let presence = BackupPresence(snapshotFile: file)
        var reloads: [Bool] = []
        presence.reload = { reloads.append($0) }
        let t0 = Date(timeIntervalSince1970: 100_000)
        func snapshot(_ state: BackupActivityState?, enabled: Bool = true, at offset: TimeInterval) -> BackupWidgetSnapshot {
            BackupWidgetSnapshot(
                isEnabled: enabled, isSetUp: true, state: state, pending: state?.remaining ?? 0, lastRun: nil, written: t0 + offset)
        }
        let uploading = { (done: Int) in BackupActivityState(phase: .uploading, done: done, total: 50, remaining: 50 - done) }

        presence.writeSnapshot(snapshot(uploading(1), at: 0), now: t0)
        #expect(BackupWidgetSnapshot.load(from: file)?.state?.done == 1)
        #expect(reloads == [true])
        // Progress within the phase: not written again within 30 seconds…
        presence.writeSnapshot(snapshot(uploading(2), at: 5), now: t0 + 5)
        #expect(BackupWidgetSnapshot.load(from: file)?.state?.done == 1)
        // … then written, but the widget is reloaded at most once a minute.
        presence.writeSnapshot(snapshot(uploading(9), at: 40), now: t0 + 40)
        #expect(BackupWidgetSnapshot.load(from: file)?.state?.done == 9)
        #expect(reloads.count == 1)
        presence.writeSnapshot(snapshot(uploading(20), at: 75), now: t0 + 75)
        #expect(reloads.count == 2)
        // A new phase at once; switching backup off reloads the control too.
        presence.writeSnapshot(snapshot(BackupActivityState(phase: .done, done: 50, total: 50), at: 76), now: t0 + 76)
        #expect(BackupWidgetSnapshot.load(from: file)?.state?.phase == .done)
        #expect(reloads == [true, false, false])
        presence.writeSnapshot(snapshot(nil, enabled: false, at: 77), now: t0 + 77)
        #expect(reloads.last == true)
        #expect(BackupWidgetSnapshot.load(from: file)?.isEnabled == false)
    }
}

@Suite struct AmbientPhotosTests {
    func item(
        _ id: FileID, kind: MediaKind = .image, favorite: Bool = false, archived: Bool = false, livePhotoVideo: Bool = false,
        at day: Int = 0, place: String? = nil
    ) -> MediaItem {
        MediaItem(
            fileId: id, path: "/Photos/\(id).jpg", mimeType: kind == .video ? "video/mp4" : "image/jpeg", kind: kind,
            etag: "e\(id)", capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400), place: place,
            isFavorite: favorite, isLivePhotoVideo: livePhotoVideo, isArchived: archived)
    }

    @Test func sourcesGiveStillPhotosOnly() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let database = try AccountDatabase(url: sandbox.root.appending(path: "db.sqlite"))
        let library = LibraryStore(database: database)
        let collections = CollectionStore(database: database)
        try library.upsert([
            item(1, favorite: true, at: 1), item(2, kind: .video, favorite: true, at: 2), item(3, favorite: true, archived: true, at: 3),
            item(4, livePhotoVideo: true, at: 4), item(5, at: 5), item(6, favorite: true, at: 6),
        ])
        let favorites = try await AmbientPhotos.items(.favorites, library: library, collections: collections)
        #expect(favorites.map(\.fileId) == [6, 1])
        let all = try await AmbientPhotos.items(.library, library: library, collections: collections)
        #expect(all.map(\.fileId) == [6, 5, 1])

        // An album keeps its own order, and a photo only the album knows (shared with the user) is in it too.
        let album = Album(kind: .own, name: "Trip")
        try collections.upsertAlbum(album)
        let outside = item(99, at: 9)
        try collections.replaceAlbumContent(
            albumId: album.id,
            children: [5, 2, 1].map { id in
                MediaParser.CollectionChild(item: item(id), childName: "\(id)-x.jpg", origin: "user", ownerPath: nil)
            }
                + [MediaParser.CollectionChild(item: outside, childName: "99-x.jpg", origin: "user", ownerPath: nil)])
        let inAlbum = try await AmbientPhotos.items(.album(id: album.id, title: "Trip"), library: library, collections: collections)
        #expect(inAlbum.map(\.fileId) == [5, 1, 99])
    }

    @Test func memoriesFallBackFromOnThisDay() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let database = try AccountDatabase(url: sandbox.root.appending(path: "db.sqlite"))
        let library = LibraryStore(database: database)
        let collections = CollectionStore(database: database)
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
        try library.upsert([
            MediaItem(fileId: 1, path: "/a.jpg", mimeType: "image/jpeg", etag: "a", capturedAt: yearAgo),
            MediaItem(fileId: 2, path: "/b.jpg", mimeType: "image/jpeg", etag: "b", capturedAt: now.addingTimeInterval(-40 * 86400)),
        ])
        let today = try await AmbientPhotos.items(.memories, library: library, collections: collections, now: now, calendar: calendar)
        #expect(today.map(\.fileId) == [1])
        // A day without: no memory either, nothing (and no crash).
        let other = now.addingTimeInterval(100 * 86400)
        let none = try await AmbientPhotos.items(.memories, library: library, collections: collections, now: other, calendar: calendar)
        #expect(none.allSatisfy { $0.kind == .image })
    }

    @Test func captionIsThePlaceElseTheDay() {
        #expect(AmbientPhotos.caption(item(1, place: "Lisbon")) == "Lisbon")
        #expect(!AmbientPhotos.caption(item(1)).isEmpty)
    }
}

@Suite struct MemoryRoomLayoutTests {
    @Test func pickKeepsFavouritesAndOrder() {
        let items = Array(0..<100)
        let picked = MemoryRoomLayout.pick(items, isFavorite: { $0 == 50 || $0 == 99 }, limit: 10)
        #expect(picked.count == 10)
        #expect(picked.contains(50))
        #expect(picked.contains(99))
        #expect(picked == picked.sorted())
        #expect(MemoryRoomLayout.pick([1, 2, 3], isFavorite: { _ in false }) == [1, 2, 3])
    }

    @Test func framesHangOnARingFacingTheViewer() {
        for count in [1, 5, 12, 13, 24] {
            let placements = MemoryRoomLayout.placements(count: count)
            #expect(placements.count == count)
            let radii = placements.map { simd_length(SIMD2($0.position.x, $0.position.z)) }
            #expect(radii.allSatisfy { abs($0 - radii[0]) < 0.001 })
            #expect(radii[0] >= 2.0)
            for placement in placements {
                // The frame's front (+z turned by yaw) points at the centre.
                let front = SIMD2<Float>(sin(placement.yaw), cos(placement.yaw))
                let toCentre = simd_normalize(SIMD2(-placement.position.x, -placement.position.z))
                #expect(simd_dot(front, toCentre) > 0.999)
                #expect(placement.position.y > 0.9 && placement.position.y < 2.1)
            }
        }
        // Nothing hangs right in front, where the window and the title are.
        for placement in MemoryRoomLayout.placements(count: 24) {
            let angle = atan2(placement.position.x, -placement.position.z)
            #expect(abs(angle) >= MemoryRoomLayout.frontGap / 2 - 0.001)
        }
        // Two rows from 13 frames on.
        #expect(Set(MemoryRoomLayout.placements(count: 24).map { ($0.position.y * 10).rounded() }).count > 2)
        #expect(MemoryRoomLayout.placements(count: 0).isEmpty)
    }

    @Test func photoExtentKeepsTheAspect() {
        let wide = MemoryRoomLayout.photoExtent(width: 4000, height: 3000)
        #expect(abs(wide.x - 0.6) < 0.0001 && abs(wide.y - 0.45) < 0.0001)
        let tall = MemoryRoomLayout.photoExtent(width: 3000, height: 6000)
        #expect(abs(tall.x - 0.3) < 0.0001 && abs(tall.y - 0.6) < 0.0001)
        #expect(MemoryRoomLayout.photoExtent(width: nil, height: nil).x == 0.6)
    }
}

#if os(macOS)
    @Suite struct DesktopPictureTests {
        let account = AccountID(rawValue: "alice https://cloud.example")

        func photo(_ id: FileID, width: Int, height: Int) -> MediaItem {
            MediaItem(fileId: id, path: "/\(id).jpg", mimeType: "image/jpeg", size: 1000, etag: "e\(id)", width: width, height: height)
        }

        @Test func eachDisplayGetsAPhotoOfItsShape() {
            let items = [photo(1, width: 3000, height: 4000), photo(2, width: 4000, height: 3000), photo(3, width: 3000, height: 4000)]
            let wide = DesktopScreen(id: 1, name: "Studio Display", width: 5120, height: 2880)
            let tall = DesktopScreen(id: 2, name: "Portrait", width: 1440, height: 2560)
            var settings = DesktopPictureSettings(accountId: account, source: .favorites, shuffle: false)
            let plan = DesktopPicturePlan.assign(items, to: [wide, tall], settings: settings)
            #expect(plan.assignments.map(\.item.fileId) == [2, 3])
            #expect(plan.assignments.map(\.screen.id) == [1, 2])
            // On from the photo after the last one taken (the third: back to the first).
            #expect(plan.position == 0)
            settings.position = 2
            // The only landscape photo comes again for the wide display; the portrait one in between waits.
            let next = DesktopPicturePlan.assign(items, to: [wide], settings: settings)
            #expect(next.assignments.map(\.item.fileId) == [2])
            #expect(next.position == 2)
        }

        @Test func oneDisplayOnly() {
            let items = (1...4).map { photo(FileID($0), width: 4000, height: 3000) }
            let screens = [
                DesktopScreen(id: 7, name: "A", width: 3000, height: 2000), DesktopScreen(id: 8, name: "B", width: 3000, height: 2000),
            ]
            let settings = DesktopPictureSettings(accountId: account, source: .library, displays: .display(id: 8, name: "B"), shuffle: true)
            let plan = DesktopPicturePlan.assign(items, to: screens, settings: settings)
            #expect(plan.assignments.map(\.screen.id) == [8])
            #expect(DesktopPicturePlan.assign([], to: screens, settings: settings).assignments.isEmpty)
            // A display that is not connected gets nothing.
            let gone = DesktopPictureSettings(accountId: account, source: .library, displays: .display(id: 9, name: "C"))
            #expect(DesktopPicturePlan.assign(items, to: screens, settings: gone).assignments.isEmpty)
        }

        @Test func shuffledRotationIsStablePerSource() {
            let a = DesktopPictureSettings(accountId: account, source: .album(id: "own:A", title: "A"))
            let b = DesktopPictureSettings(accountId: account, source: .album(id: "own:B", title: "B"))
            #expect(a.seed == DesktopPictureSettings(accountId: account, source: .album(id: "own:A", title: "Renamed")).seed)
            #expect(a.seed != b.seed)
            var plain = a
            plain.shuffle = false
            #expect(plain.seed == nil)
        }

        @Test func scheduleAndFiles() {
            let now = Date(timeIntervalSince1970: 50_000)
            var settings = DesktopPictureSettings(accountId: account, source: .favorites, interval: .fifteenMinutes)
            #expect(settings.nextChange(now: now) == now)
            settings.lastChange = now
            #expect(settings.nextChange(now: now) == now.addingTimeInterval(900))
            let item = photo(5, width: 10, height: 10)
            var edited = item
            edited.etag = "other"
            #expect(DesktopPicturePlan.fileName(item, fileExtension: "jpg").hasPrefix("5-"))
            #expect(DesktopPicturePlan.fileName(item, fileExtension: "jpg") != DesktopPicturePlan.fileName(edited, fileExtension: "jpg"))
            #expect(DesktopPicturePlan.usesOriginal(item))
            var raw = item
            raw.mimeType = "image/x-dcraw"
            #expect(!DesktopPicturePlan.usesOriginal(raw))
            var huge = item
            huge.size = 200 * 1024 * 1024
            #expect(!DesktopPicturePlan.usesOriginal(huge))
        }

        @MainActor @Test func rotationIsRememberedAndUnusedPicturesAreRemoved() throws {
            let sandbox = Sandbox()
            defer { sandbox.remove() }
            let suite = "desktop-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let folder = sandbox.root.appending(path: "DesktopPictures")
            let pictures = DesktopPictures(defaults: defaults, folder: folder)
            pictures.screens = { [] }
            pictures.apply = { _, _ in }
            #expect(pictures.settings == nil)
            pictures.start(DesktopPictureSettings(accountId: account, source: .favorites, interval: .day))
            #expect(DesktopPictures(defaults: defaults, folder: folder).settings?.source == .favorites)
            pictures.stop()
            #expect(DesktopPictures(defaults: defaults, folder: folder).settings == nil)

            try sandbox.write(to: folder.appending(path: "1-a.jpg"))
            try sandbox.write(to: folder.appending(path: "2-b.jpg"))
            pictures.assignedFiles = ["1": "2-b.jpg"]
            pictures.removeUnusedFiles()
            #expect(Sandbox.files(in: folder) == ["2-b.jpg"])
        }
    }
#endif
