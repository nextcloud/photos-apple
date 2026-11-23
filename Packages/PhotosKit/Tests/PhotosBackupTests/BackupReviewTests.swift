// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Photos
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// The second review of the backup: what "up to date" means, device-side failures, iCloud originals, the Files app's
/// record, leftovers of exports.
@Suite struct BackupReviewTests {
    let library = FakeLibrary()
    let remote = FakeRemote()
    let clock = Clock()
    let statuses = StatusLog()
    let database: AccountDatabase
    let exports = FileManager.default.temporaryDirectory.appending(path: "BackupReviewTests-\(UUID().uuidString)")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        database = try .temporary()
    }

    var status: BackupStatus { statuses.last }

    var settings: BackupSettings {
        var settings = BackupSettings()
        settings.isEnabled = true
        return settings
    }

    func makeEngine(filesLedger: Set<String> = [], exports: URL? = nil) async -> BackupEngine {
        let clock = clock
        let engine = BackupEngine(
            library: library, remote: remote, database: database, accountId: AccountID(rawValue: "test"), exportDirectory: exports,
            filesLedger: { _ in filesLedger }, now: { clock.now })
        let statuses = statuses
        await engine.setStatusHandler { status in statuses.values.withLock { $0.append(status) } }
        return engine
    }

    func resource(_ id: String, _ kind: BackupResourceKind = .photo, name: String? = nil, at offset: TimeInterval = 0, size: Int64? = 10)
        -> BackupResource
    {
        let isVideo = [.video, .editedVideo, .pairedVideo].contains(kind)
        return BackupResource(
            localIdentifier: id, kind: kind, mediaKind: isVideo ? .video : .image,
            originalName: name ?? "IMG_\(id).\(isVideo ? "MOV" : "HEIC")", createdAt: t0 + offset, modifiedAt: t0, pixelWidth: 0,
            pixelHeight: 0, byteSize: size)
    }

    /// Photos one hour apart, so nothing shares a second.
    func addPhotos(_ ids: [String]) {
        library.state.withLock { state in
            for id in ids {
                let offset = TimeInterval(state.assets.count) * 3600
                state.assets.append(.init(id: id, modifiedAt: t0, resources: [resource(id, at: offset)]))
            }
        }
    }

    func entry(_ engine: BackupEngine, _ id: String, _ kind: BackupResourceKind = .photo) async throws -> BackupLedgerEntry? {
        try await engine.ledgerEntries(of: id).first { $0.resourceKind == kind.rawValue }
    }

    func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: Item 1 — "up to date" only when nothing failed and nothing waits

    @Test func aPassWithAFailedFileIsNotUpToDate() async throws {
        addPhotos(["0001", "0002"])
        remote.state.withLock { $0.uploadErrors["IMG_0001.heic"] = .http(status: 415, message: nil) }
        let engine = await makeEngine()
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0002.heic"])
        #expect(status.phase == .incomplete(failed: 1))
        #expect(status.failed == 1)
        #expect(status.pending == 0)
        #expect(status.lastFailure?.contains("415") == true)

        // The next pass has nothing to do (the file waits for its next attempt), and it still is not "up to date".
        await engine.run(settings)
        #expect(remote.attempts.count == 2)
        #expect(status.phase == .incomplete(failed: 1))

        // The user's retry gets it through.
        remote.state.withLock { $0.uploadErrors = [:] }
        await engine.run(settings, retryFailed: true)
        #expect(status.phase == .upToDate)
        #expect(status.failed == 0)
        #expect(status.lastFailure == nil)
    }

    @Test func whatThePassLeavesBehind() {
        #expect(BackupPolicy.finalPhase(failed: 0, pending: 0) == .upToDate)
        #expect(BackupPolicy.finalPhase(failed: 2, pending: 0) == .incomplete(failed: 2))
        #expect(BackupPolicy.finalPhase(failed: 2, pending: 5) == .incomplete(failed: 2))
        #expect(BackupPolicy.finalPhase(failed: 0, pending: 5) == .idle)
        var status = BackupStatus()
        status.phase = .incomplete(failed: 1)
        #expect(!status.isRunning)
    }

    @Test func waitingItemsAreCountedFromTheLedger() async throws {
        // The photo uploads, the video waits for Wi-Fi.
        library.state.withLock {
            $0.assets = [
                .init(id: "0001", modifiedAt: t0, resources: [resource("0001")]),
                .init(id: "0002", modifiedAt: t0, resources: [resource("0002", .video, at: 3600)]),
            ]
        }
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.wifi.message))
        #expect(status.pending == 1)
        #expect(status.uploaded == 1)
    }

    @Test func aPhotoDeletedOnTheDeviceNoLongerWaits() async throws {
        library.state.withLock {
            $0.assets = [
                .init(id: "0001", modifiedAt: t0, resources: [resource("0001")]),
                .init(id: "0002", modifiedAt: t0, resources: [resource("0002", .video, at: 3600)]),
                .init(id: "0003", modifiedAt: t0, resources: [resource("0003", at: 7200)]),
            ]
        }
        remote.state.withLock { $0.uploadErrors["IMG_0003.heic"] = .http(status: 415, message: nil) }
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(try await entry(engine, "0002", .video)?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0003")?.state == BackupItemState.failed.rawValue)
        await engine.cancel()

        // The user deletes the video and the photo that failed. Nothing is left to upload.
        library.state.withLock { $0.assets.removeLast(2) }
        await engine.setNetwork(BackupNetwork())
        // The failed one is only looked at when its waiting time is over (or the user asks).
        await engine.run(settings)
        #expect(try await entry(engine, "0002", .video) == nil)
        #expect(status.phase == .incomplete(failed: 1))
        clock.advance(BackupPolicy.retryBase + 1)
        await engine.run(settings)
        #expect(try await entry(engine, "0003") == nil)
        #expect(status.phase == .upToDate)
        #expect(status.pending == 0)
        #expect(status.failed == 0)
        // What was uploaded stays known although the scan leaves it out.
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
    }

    // MARK: Item 4 — the Files app's record stands for the photo itself only

    @Test func theFilesAppsRecordDoesNotCoverTheOtherResources() async throws {
        library.state.withLock {
            $0.assets = [
                .init(
                    id: "0001", modifiedAt: t0,
                    resources: [
                        resource("0001"), resource("0001", .raw, name: "IMG_0001.DNG"), resource("0001", .pairedVideo),
                    ])
            ]
        }
        var switched = settings
        switched.filesAppMode = .switchedFromFiles
        let engine = await makeEngine(filesLedger: ["0001"])
        await engine.run(switched)
        #expect(try await entry(engine, "0001")?.matchedBy == MatchReason.filesLedger.rawValue)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.matched.rawValue)
        // Files never said it uploaded the RAW file or the motion part: they are not on the server, so they are uploaded.
        #expect(remote.uploads.sorted() == ["IMG_0001.dng", "IMG_0001.mov"])
        #expect(try await entry(engine, "0001", .raw)?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001", .pairedVideo)?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func whichResourceTheFilesAppsRecordStandsFor() {
        typealias Key = BackupEngine.LedgerKey
        let both = [resource("a"), resource("a", .edited), resource("a", .raw), resource("a", .pairedVideo)]
        #expect(BackupPolicy.filesAppPrimary(both) == [Key(localIdentifier: "a", kind: "photo")])
        // "Edited only": the edit is what stands for the photo.
        let editedOnly = [resource("b", .edited), resource("b", .pairedVideo)]
        #expect(BackupPolicy.filesAppPrimary(editedOnly) == [Key(localIdentifier: "b", kind: "edited")])
        let video = [resource("c", .video), resource("c", .editedVideo)]
        #expect(BackupPolicy.filesAppPrimary(video) == [Key(localIdentifier: "c", kind: "video")])
        // Nothing that could stand for it (only the motion part is left to scan).
        #expect(BackupPolicy.filesAppPrimary([resource("d", .pairedVideo)]).isEmpty)
    }

    // MARK: Item 7 — failures of this device

    @Test func aFullDeviceStopsThePassBeforeAnythingIsExported() async throws {
        addPhotos(["0001", "0002"])
        let engine = await makeEngine()
        await engine.setFreeSpace { 1_000_000 }
        await engine.run(settings)
        #expect(status.blocker == .deviceStorageFull)
        #expect(library.exports.isEmpty)
        #expect(remote.attempts.isEmpty)
        // Not this file's fault: it does not count as failed and does not back off.
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        #expect(status.failed == 0)

        await engine.setFreeSpace { 10_000_000_000 }
        await engine.run(settings)
        #expect(status.blocker == nil)
        #expect(status.phase == .upToDate)
    }

    @Test func runningOutOfSpaceWhileWritingIsABlockerToo() async throws {
        addPhotos(["0001", "0002"])
        library.state.withLock { $0.exportErrors["IMG_0001.HEIC"] = CocoaError(.fileWriteOutOfSpace) }
        let engine = await makeEngine()
        await engine.run(settings)
        #expect(status.blocker == .deviceStorageFull)
        #expect(library.exports == ["IMG_0001.HEIC"])
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
    }

    @Test func deviceSpace() {
        let reserve = BackupPolicy.deviceSpaceReserve
        #expect(BackupPolicy.hasRoom(free: nil, size: 1_000_000_000))
        #expect(BackupPolicy.hasRoom(free: reserve + 100, size: 100))
        #expect(!BackupPolicy.hasRoom(free: reserve + 99, size: 100))
        #expect(!BackupPolicy.hasRoom(free: reserve - 1, size: nil))
        #expect(BackupPolicy.blocker(for: BackupDeviceError.outOfSpace) == .deviceStorageFull)
        #expect(BackupPolicy.blocker(for: CocoaError(.fileWriteOutOfSpace)) == .deviceStorageFull)
        #expect(BackupPolicy.blocker(for: POSIXError(.ENOSPC)) == .deviceStorageFull)
        let wrapped = NSError(domain: "PHPhotosErrorDomain", code: -1, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC) as NSError])
        #expect(BackupPolicy.blocker(for: wrapped) == .deviceStorageFull)
        #expect(BackupPolicy.blocker(for: BackupDeviceError.needsICloudDownload) == nil)
        #expect(BackupPolicy.blocker(for: CocoaError(.fileReadNoPermission)) == nil)
        #expect(BackupEngine.freeDeviceSpace(at: FileManager.default.temporaryDirectory.appending(path: "not/there/yet")) ?? 0 > 0)
    }

    @Test func originalsOnlyInICloudAreSkippedWhenDownloadsAreOff() async throws {
        addPhotos(["0001", "0002"])
        library.state.withLock { $0.cloudOnly = ["IMG_0001.HEIC"] }
        var local = settings
        local.downloadFromICloud = false
        let engine = await makeEngine()
        await engine.run(local)
        #expect(library.state.withLock { $0.networkAllowed } == [false, false])
        #expect(remote.uploads == ["IMG_0002.heic"])
        let skipped = try #require(try await entry(engine, "0001"))
        #expect(skipped.state == BackupItemState.skipped.rawValue)
        #expect(skipped.lastError == BackupDeviceError.needsICloudDownload.localizedDescription)
        #expect(skipped.attempts == 0)
        #expect(status.skipped == 1)
        #expect(status.failed == 0)
        // Everything that may be uploaded is.
        #expect(status.phase == .upToDate)

        // No attempt until the setting changes, however much time passes.
        clock.advance(30 * 86_400)
        await engine.run(local)
        #expect(library.exports.count == 2)
        #expect(library.lastScan == [])

        // The setting changes: it is taken up again.
        await engine.run(settings)
        #expect(library.state.withLock { $0.networkAllowed.last } == true)
        #expect(remote.uploads == ["IMG_0002.heic", "IMG_0001.heic"])
        #expect(status.skipped == 0)
        #expect(status.phase == .upToDate)
    }

    @Test func theUsersRetryAlsoLooksAtSkippedItems() async throws {
        addPhotos(["0001"])
        library.state.withLock { $0.cloudOnly = ["IMG_0001.HEIC"] }
        var local = settings
        local.downloadFromICloud = false
        let engine = await makeEngine()
        await engine.run(local)
        #expect(status.skipped == 1)
        // The original was downloaded meanwhile (the user turned "Optimise Storage" off).
        library.state.withLock { $0.cloudOnly = [] }
        await engine.run(local, retryFailed: true)
        #expect(remote.uploads == ["IMG_0001.heic"])
        #expect(status.skipped == 0)
    }

    // MARK: Item 8 — iCloud originals only on Wi-Fi

    @Test func iCloudOriginalsWaitForWiFiAndDoNotFail() async throws {
        addPhotos(["0001", "0002"])
        library.state.withLock { $0.cloudOnly = ["IMG_0001.HEIC"] }
        let engine = await makeEngine()
        // Cellular: uploads are allowed (Wi-Fi only is off), downloads from iCloud are not.
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(library.state.withLock { $0.networkAllowed } == [false, false])
        #expect(remote.uploads == ["IMG_0002.heic"])
        #expect(status.phase == .paused(BackupPause.iCloud.message))
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        #expect(status.failed == 0)
        #expect(status.pending == 1)
        #expect(await engine.isWaitingToResume)

        // Another cellular path changes nothing; Wi-Fi lets it go on.
        await engine.setNetwork(BackupNetwork(isExpensive: true, isConstrained: true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(library.exports.count == 2)
        await engine.setNetwork(BackupNetwork())
        #expect(await eventually { remote.uploads.count == 2 && status.phase == .upToDate })
        #expect(library.state.withLock { $0.networkAllowed.last } == true)
    }

    @Test func turningDownloadsOffEndsTheWaitForWiFi() async throws {
        addPhotos(["0001"])
        library.state.withLock { $0.cloudOnly = ["IMG_0001.HEIC"] }
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.iCloud.message))
        var local = settings
        local.downloadFromICloud = false
        await engine.settingsChanged(local)
        #expect(await eventually { status.phase == .upToDate && status.skipped == 1 })
    }

    @Test func whenICloudMayBeUsed() {
        var settings = BackupSettings()
        #expect(BackupPolicy.allowsICloudDownload(settings, network: nil))
        #expect(BackupPolicy.allowsICloudDownload(settings, network: BackupNetwork()))
        #expect(!BackupPolicy.allowsICloudDownload(settings, network: BackupNetwork(isExpensive: true)))
        #expect(!BackupPolicy.allowsICloudDownload(settings, network: BackupNetwork(isConstrained: true)))
        // "Upload in Low Data Mode" is about uploads.
        settings.allowLowDataMode = true
        #expect(!BackupPolicy.allowsICloudDownload(settings, network: BackupNetwork(isConstrained: true)))
        settings.downloadFromICloud = false
        #expect(!BackupPolicy.allowsICloudDownload(settings, network: BackupNetwork()))
        #expect(!BackupPolicy.allowsICloudDownload(settings, network: nil))
    }

    @Test func photoKitsNetworkErrorOnlyMeansICloudWhenTheNetworkWasNotAllowed() {
        let needsNetwork = PHPhotosError(.networkAccessRequired)
        #expect(PhotoLibrarySource.deviceError(for: needsNetwork, allowNetwork: false) as? BackupDeviceError == .needsICloudDownload)
        #expect(PhotoLibrarySource.deviceError(for: needsNetwork, allowNetwork: true) is PHPhotosError)
        #expect(PhotoLibrarySource.deviceError(for: CocoaError(.fileNoSuchFile), allowNetwork: false) is CocoaError)
    }

    // MARK: Item 9 — leftovers of exports

    @Test func leftoversOfExportsAreSweptBeforeTheFirstPass() async throws {
        defer { try? FileManager.default.removeItem(at: exports) }
        let files = FileManager.default
        // An export of a pass that never ended.
        let stray = exports.appending(path: "\(UUID().uuidString)/IMG_9999.MOV")
        try files.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: stray)
        // Kept exports: one of a resource nobody knows, one without its note, one that is uploaded, one that is too old,
        // and one that is still needed.
        func keep(_ name: String, _ info: BackupEngine.KeptExport?) throws -> URL {
            let directory = exports.appending(path: "\(BackupEngine.keptFolder)/\(name)")
            try files.createDirectory(at: directory.appending(path: "data"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: directory.appending(path: "data/file.mov"))
            if let info { try JSONEncoder().encode(info).write(to: directory.appending(path: BackupEngine.keptInfoFile)) }
            return directory
        }
        addPhotos(["0001", "0002", "0003"])
        let engine = await makeEngine(exports: exports)
        try await engine.record(resource("0001"), state: .uploaded, matchedBy: .ownUpload)
        try await engine.prepareLedger(pending: [resource("0002"), resource("0003")], touched: [])
        let unknown = try keep("unknown", .init(localIdentifier: "gone", kind: "photo", keptAt: clock.now))
        let noNote = try keep("no-note", nil)
        let done = try keep("done", .init(localIdentifier: "0001", kind: "photo", keptAt: clock.now))
        let old = try keep("old", .init(localIdentifier: "0002", kind: "photo", keptAt: clock.now - BackupPolicy.keptExportAge - 1))
        let needed = try keep("needed", .init(localIdentifier: "0003", kind: "photo", keptAt: clock.now - 3600))

        await engine.sweepExports()
        func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path(percentEncoded: false)) }
        #expect(!exists(stray.deletingLastPathComponent()))
        #expect(!exists(unknown))
        #expect(!exists(noNote))
        #expect(!exists(done))
        #expect(!exists(old))
        #expect(exists(needed))

        // Only once per engine: what a running pass exports is not taken away under it.
        try files.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        await engine.run(settings)
        #expect(exists(stray.deletingLastPathComponent()))
    }

    @Test func aPassSweepsBeforeItExports() async throws {
        defer { try? FileManager.default.removeItem(at: exports) }
        let stray = exports.appending(path: "\(UUID().uuidString)/IMG_9999.MOV")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: stray)
        addPhotos(["0001"])
        let engine = await makeEngine(exports: exports)
        await engine.run(settings)
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
        #expect(status.phase == .upToDate)
    }

    // MARK: Item 10 — limited access

    @Test func limitedAccessIsPartOfTheStatus() async throws {
        addPhotos(["0001"])
        library.state.withLock { $0.isLimited = true }
        let engine = await makeEngine()
        await engine.run(settings)
        #expect(status.phase == .upToDate)
        #expect(status.isLimitedAccess)
        library.state.withLock { $0.isLimited = false }
        await engine.run(settings)
        #expect(!status.isLimitedAccess)
    }

    // MARK: Item 3 — options

    @Test func optionsWrittenByAnEarlierVersionAreKept() throws {
        // Without "includeHidden", with the option that no longer exists.
        let stored = """
            {"isEnabled":true,"accountId":"alice https://cloud.example","folder":"/Bilder","subfolders":"year",
             "naming":{"original":{}},"format":"original","edits":"editedOnly","livePhotos":false,"photos":true,"videos":false,
             "albumIdentifiers":["a"],"includeSharedLibrary":true,"wifiOnlyForVideos":false,"wifiOnly":true,
             "allowLowDataMode":true,"pauseInLowPowerMode":false,"downloadFromICloud":false,"filesAppMode":"switchedFromFiles"}
            """
        let settings = try JSONDecoder().decode(BackupSettings.self, from: Data(stored.utf8))
        #expect(settings.isEnabled)
        #expect(settings.accountId == AccountID(rawValue: "alice https://cloud.example"))
        #expect(settings.folder == "/Bilder")
        #expect(settings.subfolders == .year)
        #expect(settings.edits == .editedOnly)
        #expect(!settings.livePhotos)
        #expect(!settings.videos)
        #expect(settings.albumIdentifiers == ["a"])
        #expect(settings.wifiOnly)
        #expect(!settings.downloadFromICloud)
        #expect(settings.filesAppMode == .switchedFromFiles)
        // Hidden photos stay out unless the user asks for them.
        #expect(!settings.includeHidden)
        #expect(!BackupSettings().includeHidden)

        var changed = settings
        changed.includeHidden = true
        let again = try JSONDecoder().decode(BackupSettings.self, from: JSONEncoder().encode(changed))
        #expect(again == changed)
        // A file with nothing in it that this version knows still gives usable options.
        #expect(try JSONDecoder().decode(BackupSettings.self, from: Data("{}".utf8)) == BackupSettings())
    }

    @Test func switchingICloudDownloadsLooksAtEverythingAgain() {
        var settings = BackupSettings()
        let on = BackupPolicy.scanSignature(settings)
        settings.downloadFromICloud = false
        #expect(BackupPolicy.scanSignature(settings) != on)
        // Hidden photos are new assets when they are included; nothing else has to be read again.
        settings.downloadFromICloud = true
        settings.includeHidden = true
        #expect(BackupPolicy.scanSignature(settings) == on)
    }

    // MARK: Item 2 — order

    @Test func largeFilesComeLast() {
        let work = [
            resource("1", .video, size: 500), resource("2", size: 10), resource("3", .video, size: 101), resource("4", size: nil),
            resource("5", size: 100),
        ]
        let order = BackupPolicy.uploadOrder(work, backgroundLimit: 100)
        #expect(order.first.map(\.localIdentifier) == ["2", "4", "5"])
        #expect(order.last.map(\.localIdentifier) == ["1", "3"])
        // Without the system's help everything is sent by the app anyway: oldest first.
        let plain = BackupPolicy.uploadOrder(work, backgroundLimit: nil)
        #expect(plain.first == work)
        #expect(plain.last.isEmpty)
    }
}

// MARK: - Item 12: which resources of an asset are uploaded

@Suite struct BackupResourceSelectionTests {
    typealias Resource = BackupAssetInfo.Resource
    let created = Date(timeIntervalSince1970: 1_790_000_000)

    func asset(video: Bool = false, live: Bool = false) -> BackupAssetInfo {
        BackupAssetInfo(
            localIdentifier: "ABCDEFGH-1234/L0/001", isVideo: video, isLivePhoto: live, createdAt: created,
            modifiedAt: created + 60, pixelWidth: 4032, pixelHeight: 3024, latitude: 48.1, longitude: 11.5)
    }

    func settings(_ edits: BackupSettings.Edits = .originalAndEdited, livePhotos: Bool = true) -> BackupSettings {
        var settings = BackupSettings()
        settings.edits = edits
        settings.livePhotos = livePhotos
        return settings
    }

    func select(_ asset: BackupAssetInfo, _ resources: [Resource], _ settings: BackupSettings) -> [String] {
        PhotoLibrarySource.select(asset, resources: resources, settings: settings).map {
            "\($0.resource.kind.rawValue):\($0.resource.originalName):\($0.index)"
        }
    }

    let photo = Resource(type: .photo, name: "IMG_1234.HEIC", uniformTypeIdentifier: "public.heic", byteSize: 2_000)
    let editedPhoto = Resource(type: .fullSizePhoto, name: "FullSizeRender.jpg", uniformTypeIdentifier: "public.jpeg", byteSize: 1_500)
    let adjustment = Resource(type: .adjustmentData, name: "Adjustments.plist", uniformTypeIdentifier: "com.apple.property-list")
    let motion = Resource(type: .pairedVideo, name: "IMG_1234.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie", byteSize: 3_000)
    let editedMotion = Resource(
        type: .fullSizePairedVideo, name: "FullSizeRender.mov", uniformTypeIdentifier: "com.apple.quicktime-movie", byteSize: 2_500)
    let raw = Resource(type: .alternatePhoto, name: "IMG_1234.DNG", uniformTypeIdentifier: "com.adobe.raw-image", byteSize: 25_000)
    let video = Resource(type: .video, name: "IMG_2000.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie", byteSize: 90_000)
    let editedVideo = Resource(
        type: .fullSizeVideo, name: "FullSizeRender.mov", uniformTypeIdentifier: "com.apple.quicktime-movie", byteSize: 80_000)

    @Test func aPlainPhoto() {
        let result = PhotoLibrarySource.select(asset(), resources: [photo], settings: settings())
        #expect(result.count == 1)
        let resource = result.first?.resource
        #expect(resource?.kind == .photo)
        #expect(resource?.mediaKind == .image)
        #expect(resource?.originalName == "IMG_1234.HEIC")
        #expect(resource?.byteSize == 2_000)
        #expect(resource?.createdAt == created)
        #expect(resource?.modifiedAt == created + 60)
        #expect(resource?.pixelWidth == 4032)
        #expect(resource?.latitude == 48.1)
        // Whatever the options say about edits: without an edit there is the original.
        #expect(select(asset(), [photo], settings(.editedOnly)) == ["photo:IMG_1234.HEIC:0"])
        #expect(select(asset(), [photo], settings(.originalOnly)) == ["photo:IMG_1234.HEIC:0"])
    }

    @Test func anEditedPhoto() {
        let all = [adjustment, photo, editedPhoto]
        // The edit gets Apple's name for it and the extension of its own data.
        #expect(select(asset(), all, settings()) == ["photo:IMG_1234.HEIC:1", "edited:IMG_E1234.jpg:2"])
        #expect(select(asset(), all, settings(.editedOnly)) == ["edited:IMG_E1234.jpg:2"])
        #expect(select(asset(), all, settings(.originalOnly)) == ["photo:IMG_1234.HEIC:1"])
        // A name without Apple's pattern gets the suffix.
        let imported = Resource(type: .photo, name: "holiday.jpeg", uniformTypeIdentifier: "public.jpeg")
        #expect(select(asset(), [imported, editedPhoto], settings(.editedOnly)) == ["edited:holiday (edited).jpg:1"])
        #expect(PhotoLibrarySource.select(asset(), resources: [imported, editedPhoto], settings: settings()).last?.resource.byteSize == 1_500)
    }

    @Test func rawNextToAPhoto() {
        // The RAW file is uploaded whatever the edit option says; it is its own resource kind.
        #expect(select(asset(), [photo, raw], settings()) == ["photo:IMG_1234.HEIC:0", "raw:IMG_1234.DNG:1"])
        #expect(select(asset(), [photo, editedPhoto, raw], settings(.editedOnly)) == ["edited:IMG_E1234.jpg:1", "raw:IMG_1234.DNG:2"])
        // An alternate photo that is no RAW (e.g. the JPEG of a RAW+JPEG pair imported the other way round) is left out.
        let alternateJPEG = Resource(type: .alternatePhoto, name: "IMG_1234.JPG", uniformTypeIdentifier: "public.jpeg")
        #expect(select(asset(), [photo, alternateJPEG], settings()) == ["photo:IMG_1234.HEIC:0"])
        // A ProRAW photo is the original itself.
        let proRAW = Resource(type: .photo, name: "IMG_1234.DNG", uniformTypeIdentifier: "com.adobe.raw-image")
        #expect(select(asset(), [proRAW], settings()) == ["photo:IMG_1234.DNG:0"])
    }

    @Test func aLivePhoto() {
        let live = asset(live: true)
        #expect(select(live, [photo, motion], settings()) == ["photo:IMG_1234.HEIC:0", "pairedVideo:IMG_1234.MOV:1"])
        // Without "Live Photos" only the still.
        #expect(select(live, [photo, motion], settings(livePhotos: false)) == ["photo:IMG_1234.HEIC:0"])
        // A paired video on an asset that is no Live Photo any more (turned off in Photos) is left out.
        #expect(select(asset(), [photo, motion], settings()) == ["photo:IMG_1234.HEIC:0"])

        // Edited: the original motion part goes with the original, the edited one only with "Edited only".
        let all = [photo, motion, editedPhoto, editedMotion]
        #expect(
            select(live, all, settings()) == ["photo:IMG_1234.HEIC:0", "edited:IMG_E1234.jpg:2", "pairedVideo:IMG_1234.MOV:1"])
        #expect(select(live, all, settings(.editedOnly)) == ["edited:IMG_E1234.jpg:2", "pairedVideo:IMG_1234.MOV:3"])
        #expect(select(live, all, settings(.originalOnly)) == ["photo:IMG_1234.HEIC:0", "pairedVideo:IMG_1234.MOV:1"])
        // "Edited only" without an edited motion part falls back to the original one.
        #expect(
            select(live, [photo, motion, editedPhoto], settings(.editedOnly)) == ["edited:IMG_E1234.jpg:2", "pairedVideo:IMG_1234.MOV:1"])
        let paired = PhotoLibrarySource.select(live, resources: [photo, motion], settings: settings()).last?.resource
        #expect(paired?.mediaKind == .video)
        #expect(paired?.byteSize == 3_000)
    }

    @Test func aVideo() {
        let clip = asset(video: true)
        #expect(select(clip, [video], settings()) == ["video:IMG_2000.MOV:0"])
        #expect(select(clip, [video], settings(.editedOnly)) == ["video:IMG_2000.MOV:0"])
        #expect(select(clip, [video, editedVideo], settings()) == ["video:IMG_2000.MOV:0", "editedVideo:IMG_E2000.mov:1"])
        #expect(select(clip, [video, editedVideo], settings(.editedOnly)) == ["editedVideo:IMG_E2000.mov:1"])
        #expect(select(clip, [video, editedVideo], settings(.originalOnly)) == ["video:IMG_2000.MOV:0"])
        // A photo's resources on a video asset mean nothing.
        #expect(select(clip, [video, raw, motion], settings()) == ["video:IMG_2000.MOV:0"])
        #expect(PhotoLibrarySource.select(clip, resources: [video], settings: settings()).first?.resource.mediaKind == .video)
    }

    @Test func anAssetWithoutItsOriginal() {
        // Nothing to upload, and no crash.
        #expect(select(asset(), [adjustment], settings()).isEmpty)
        #expect(select(asset(video: true), [], settings()).isEmpty)
        // Only the edit is there: it is named after the asset.
        #expect(select(asset(), [editedPhoto], settings()) == ["edited:ABCDEFGH (edited).jpg:0"])
    }
}
