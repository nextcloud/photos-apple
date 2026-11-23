// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

// MARK: - Fakes

/// A photo library without PhotoKit.
final class FakeLibrary: BackupLibrary {
    struct Asset {
        var id: String
        var modifiedAt: Date?
        var resources: [BackupResource]
    }

    struct State {
        var assets: [Asset] = []
        /// Assets whose resources were read, per scan.
        var scans: [[String]] = []
        var exports: [String] = []
        var exportErrors: [String: any Error] = [:]
        /// Names of resources whose data is only in iCloud.
        var cloudOnly: Set<String> = []
        /// Whether each export was allowed to use the network.
        var networkAllowed: [Bool] = []
        var isLimited = false
        /// Size of the file an export writes, when it is not what the resource says.
        var exportedSizes: [String: Int] = [:]
    }

    let state = Mutex(State())
    var isAuthorized: Bool { true }
    var isLimited: Bool { state.withLock { $0.isLimited } }

    var lastScan: [String] { state.withLock { $0.scans.last ?? [] } }
    var exports: [String] { state.withLock { $0.exports } }

    func scan(_ settings: BackupSettings, needsScan: (String, Date?) -> Bool) -> [BackupResource] {
        let assets = state.withLock { $0.assets }
        let wanted = assets.filter { needsScan($0.id, $0.modifiedAt) }
        state.withLock { $0.scans.append(wanted.map(\.id)) }
        return wanted.flatMap(\.resources)
    }

    func export(_ resource: BackupResource, settings: BackupSettings, allowNetwork: Bool) async throws -> URL {
        let (error, size) = state.withLock { state -> ((any Error)?, Int?) in
            state.exports.append(resource.originalName)
            state.networkAllowed.append(allowNetwork)
            if state.cloudOnly.contains(resource.originalName), !allowNetwork { return (BackupDeviceError.needsICloudDownload, nil) }
            return (state.exportErrors[resource.originalName], state.exportedSizes[resource.originalName])
        }
        if let error { throw error }
        let directory = FileManager.default.temporaryDirectory.appending(path: "BackupTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: resource.originalName)
        try Data(repeating: 7, count: size ?? Int(resource.byteSize ?? 10)).write(to: file)
        return file
    }
}

/// A server that keeps what was uploaded and finds it again in the reconciliation.
final class FakeRemote: BackupRemote {
    struct Link: Equatable {
        var imagePath: String
        var videoPath: String
    }

    struct State {
        var files: [RemoteCandidate] = []
        var uploads: [String] = []
        var attempts: [String] = []
        var links: [Link] = []
        /// Error for every upload, or per file name.
        var uploadError: NetworkError?
        var uploadErrors: [String: NetworkError] = [:]
        var searchErrors: [NetworkError] = []
        var nextFileId: Int64 = 100
        var cleanups = 0
        /// Uploads prepared for the system and not reported yet: size and capture time by path.
        var prepared: [String: (size: Int64, capturedAt: Date)] = [:]
    }

    let state = Mutex(State())
    /// Runs before an upload is answered, e.g. to change the network in the middle of a run.
    let beforeUpload = Mutex<(@Sendable (String) async -> Void)?>(nil)
    /// Runs before the reconciliation is answered.
    let beforeCandidates = Mutex<(@Sendable () async -> Void)?>(nil)

    var uploads: [String] { state.withLock { $0.uploads } }
    var attempts: [String] { state.withLock { $0.attempts } }
    var links: [Link] { state.withLock { $0.links } }

    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
        if let hook = beforeCandidates.withLock({ $0 }) { await hook() }
        return try state.withLock { state in
            if !state.searchErrors.isEmpty { throw state.searchErrors.removeFirst() }
            return state.files
        }
    }

    func upload(file: URL, fileName: String, folder: String, capturedAt: Date) async throws -> UploadedFile {
        if let hook = beforeUpload.withLock({ $0 }) { await hook(fileName) }
        let size = Int64((try? Data(contentsOf: file).count) ?? 0)
        return try state.withLock { state in
            state.attempts.append(fileName)
            if let error = state.uploadErrors[fileName] ?? state.uploadError { throw error }
            state.nextFileId += 1
            let path = "\(folder)/\(fileName)"
            state.uploads.append(fileName)
            state.files.append(
                RemoteCandidate(
                    fileId: state.nextFileId, path: path, kind: fileName.hasSuffix("mov") ? .video : .image, size: size,
                    capturedAt: capturedAt, modifiedAt: capturedAt))
            return UploadedFile(fileId: state.nextFileId, path: path, etag: nil)
        }
    }

    func removeStaleUploads() async {
        state.withLock { $0.cleanups += 1 }
    }

    func prepareUpload(file: URL, fileName: String, folder: String, capturedAt: Date, reserved: Set<String>) async throws
        -> Uploader.Prepared
    {
        if let hook = beforeUpload.withLock({ $0 }) { await hook(fileName) }
        let size = Int64((try? Data(contentsOf: file).count) ?? 0)
        return try state.withLock { state in
            state.attempts.append(fileName)
            if let error = state.uploadErrors[fileName] ?? state.uploadError { throw error }
            let base = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            var name = fileName
            var counter = 2
            while true {
                let path = "\(folder)/\(name)"
                if !reserved.contains(path) {
                    guard let existing = state.files.first(where: { $0.path == path }) else {
                        state.prepared[path] = (size, capturedAt)
                        return .put(
                            path: path, request: HTTPRequest(method: "PUT", url: URL(string: "https://fake.test")!.appending(path: path)))
                    }
                    if existing.size == size { return .existing(UploadedFile(fileId: existing.fileId, path: path, etag: nil)) }
                }
                name = "\(base) (\(counter)).\(ext)"
                counter += 1
            }
        }
    }

    func finishUpload(path: String, response: HTTPResponse) async throws -> UploadedFile {
        if let error = NetworkError.from(status: response.status, data: response.data) { throw error }
        return state.withLock { state in
            state.nextFileId += 1
            let name = (path as NSString).lastPathComponent
            let prepared = state.prepared.removeValue(forKey: path)
            state.uploads.append(name)
            state.files.append(
                RemoteCandidate(
                    fileId: state.nextFileId, path: path, kind: name.hasSuffix("mov") ? .video : .image, size: prepared?.size ?? 0,
                    capturedAt: prepared?.capturedAt, modifiedAt: prepared?.capturedAt ?? Date()))
            return UploadedFile(fileId: state.nextFileId, path: path, etag: nil)
        }
    }

    func linkLivePhoto(imagePath: String, imageFileId: FileID, videoPath: String, videoFileId: FileID) async throws {
        state.withLock { $0.links.append(Link(imagePath: imagePath, videoPath: videoPath)) }
    }

    func didUpload(_ uploaded: UploadedFile, resource: BackupResource, metadataEditing: Bool) async {}
}

final class Clock: Sendable {
    let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

final class StatusLog: Sendable {
    let values = Mutex<[BackupStatus]>([])
    var last: BackupStatus { values.withLock { $0.last ?? BackupStatus() } }
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1))) struct BackupEngineTests {
    let library = FakeLibrary()
    let remote = FakeRemote()
    let clock = Clock()
    let statuses = StatusLog()
    let engine: BackupEngine
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        let clock = clock
        engine = BackupEngine(
            library: library, remote: remote, database: try .temporary(), accountId: AccountID(rawValue: "test"),
            now: { clock.now })
        let statuses = statuses
        await engine.setStatusHandler { status in statuses.values.withLock { $0.append(status) } }
    }

    var status: BackupStatus { statuses.last }

    var settings: BackupSettings {
        var settings = BackupSettings()
        settings.isEnabled = true
        return settings
    }

    func resource(
        _ id: String, _ kind: BackupResourceKind = .photo, name: String? = nil, at offset: TimeInterval = 0, modified: TimeInterval = 0,
        size: Int64? = 10
    ) -> BackupResource {
        let isVideo = [.video, .editedVideo, .pairedVideo].contains(kind)
        return BackupResource(
            localIdentifier: id, kind: kind, mediaKind: isVideo ? .video : .image,
            originalName: name ?? "IMG_\(id).\(isVideo ? "MOV" : "HEIC")", createdAt: t0 + offset, modifiedAt: t0 + modified, pixelWidth: 0,
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

    func entry(_ id: String, _ kind: BackupResourceKind = .photo) async throws -> BackupLedgerEntry? {
        try await engine.ledgerEntries(of: id).first { $0.resourceKind == kind.rawValue }
    }

    /// Waits for work the engine starts by itself (a resumed run).
    func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func leftoversOfInterruptedUploadsAreCleanedUpWhenThereIsSomethingToUpload() async throws {
        addPhotos(["0001"])
        await engine.run(settings)
        #expect(remote.state.withLock { $0.cleanups } == 1)
        // Nothing to upload: no extra request.
        await engine.run(settings)
        #expect(remote.state.withLock { $0.cleanups } == 1)
    }

    // MARK: Skip complete assets (review point 18)

    @Test func completeAssetsAreNotScannedAgain() async throws {
        addPhotos(["0001", "0002", "0003"])
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic"])
        #expect(status.phase == .upToDate)
        #expect(library.lastScan == ["0001", "0002", "0003"])

        await engine.run(settings)
        #expect(library.lastScan == [])
        #expect(library.exports.count == 3)
        #expect(status.phase == .upToDate)

        // A changed asset (favourite, new edit…) is looked at again, once.
        library.state.withLock {
            $0.assets[1].modifiedAt = t0 + 500; $0.assets[1].resources[0].modifiedAt = t0 + 500
        }
        await engine.run(settings)
        #expect(library.lastScan == ["0002"])
        #expect(library.exports.count == 3)
        await engine.run(settings)
        #expect(library.lastScan == [])

        // A new asset is the only one read.
        addPhotos(["0004"])
        await engine.run(settings)
        #expect(library.lastScan == ["0004"])
        #expect(remote.uploads.count == 4)
    }

    @Test func otherResourceOptionsScanEverythingAgain() async throws {
        addPhotos(["0001", "0002"])
        await engine.run(settings)
        var changed = settings
        changed.livePhotos = false
        await engine.run(changed)
        #expect(library.lastScan == ["0001", "0002"])
        await engine.run(changed)
        #expect(library.lastScan == [])
    }

    @Test func assetsWithResourcesStillWaitingAreScannedAgain() async throws {
        // The photo uploads, the video waits for Wi-Fi: the asset is not "complete".
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic"])
        #expect(try await entry("0001", .pairedVideo)?.state == BackupItemState.pending.rawValue)
        await engine.cancel()
        await engine.run(settings)
        #expect(library.lastScan == ["0001"])
    }

    // MARK: Pause and resume (review point 3)

    @Test func waitingForWiFiKeepsItsStatusAndResumes() async throws {
        addPhotos(["0001", "0002"])
        var wifiOnly = settings
        wifiOnly.wifiOnly = true
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(wifiOnly)
        #expect(status.phase == .paused(BackupPause.wifi.message))
        #expect(remote.uploads.isEmpty)
        #expect(await engine.isWaitingToResume)

        await engine.setNetwork(BackupNetwork(isExpensive: false))
        #expect(await eventually { remote.uploads.count == 2 && status.phase == .upToDate })
        #expect(await !engine.isWaitingToResume)
    }

    @Test func pauseInTheMiddleOfARunIsNotOverwrittenWithIdle() async throws {
        addPhotos(["0001", "0002", "0003"])
        var wifiOnly = settings
        wifiOnly.wifiOnly = true
        let engine = engine
        remote.beforeUpload.withLock {
            $0 = { name in if name == "IMG_0001.heic" { await engine.setNetwork(BackupNetwork(isExpensive: true)) } }
        }
        await engine.run(wifiOnly)
        #expect(remote.uploads == ["IMG_0001.heic"])
        #expect(status.phase == .paused(BackupPause.wifi.message))
        #expect(status.pending == 2)

        remote.beforeUpload.withLock { $0 = nil }
        await engine.setNetwork(BackupNetwork())
        #expect(await eventually { remote.uploads.count == 3 && status.phase == .upToDate })
    }

    @Test func lowPowerModePausesAndResumes() async throws {
        addPhotos(["0001"])
        await engine.setLowPower(true)
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.lowPower.message))
        #expect(remote.uploads.isEmpty)
        // An unrelated change does not start anything.
        await engine.setNetwork(BackupNetwork())
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.uploads.isEmpty)

        await engine.setLowPower(false)
        #expect(await eventually { remote.uploads.count == 1 && status.phase == .upToDate })
    }

    @Test func videosWaitForWiFiWhilePhotosUpload() async throws {
        library.state.withLock {
            $0.assets = [
                .init(id: "0001", modifiedAt: t0, resources: [resource("0001", .video)]),
                .init(id: "0002", modifiedAt: t0, resources: [resource("0002", at: 3600)]),
            ]
        }
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0002.heic"])
        #expect(status.phase == .paused(BackupPause.wifi.message))
        #expect(status.pending == 1)

        await engine.setNetwork(BackupNetwork())
        #expect(await eventually { remote.uploads == ["IMG_0002.heic", "IMG_0001.mov"] && status.phase == .upToDate })
    }

    @Test func theUsersPauseDoesNotResumeAndIsNotAFailure() async throws {
        addPhotos(["0001", "0002"])
        let engine = engine
        remote.beforeUpload.withLock { $0 = { _ in await engine.cancel() } }
        remote.state.withLock { $0.uploadError = .cancelled }
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.user.message))
        #expect(try await entry("0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry("0001")?.attempts == 0)
        #expect(await !engine.isWaitingToResume)

        remote.state.withLock { $0.uploadError = nil }
        await engine.setNetwork(BackupNetwork())
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.uploads.isEmpty)
    }

    // MARK: Interrupted by the system (review point 8)

    @Test func aPassTheSystemInterruptsIsNotPausedAndStaysDue() async throws {
        addPhotos(["0001", "0002", "0003"])
        let engine = engine
        // The background time runs out while the second file is on its way.
        remote.beforeUpload.withLock { $0 = { name in if name == "IMG_0002.heic" { await engine.interrupt() } } }
        remote.state.withLock { $0.uploadErrors["IMG_0002.heic"] = .cancelled }
        await engine.run(settings)
        #expect(status.phase == .idle)
        #expect(status.isInterrupted)
        #expect(!status.isRunning)
        #expect(status.uploadedThisPass == 1)
        #expect(status.pending == 2)
        // Not a failure of the file, and nothing waits for a network change.
        #expect(try await entry("0002")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry("0002")?.attempts == 0)
        #expect(await !engine.isWaitingToResume)

        // The next pass takes it up.
        remote.beforeUpload.withLock { $0 = nil }
        remote.state.withLock { $0.uploadErrors = [:] }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic"])
        #expect(status.phase == .upToDate)
        #expect(!status.isInterrupted)
        #expect(status.uploadedThisPass == 2)
        #expect(status.uploaded == 3)
    }

    @Test func interruptingWithoutARunningPassChangesNothing() async throws {
        addPhotos(["0001"])
        await engine.interrupt()
        await engine.run(settings)
        #expect(status.phase == .upToDate)
        #expect(!status.isInterrupted)
    }

    @Test func aPauseWhileTheServerIsAskedIsNotAFailure() async throws {
        addPhotos(["0001"])
        // A request cancelled in the middle reports it as a network error.
        remote.state.withLock { $0.searchErrors = [.cancelled] }
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.user.message))
        #expect(status.blocker == nil)
    }

    @Test func thePassCountsWhatItUploadedItself() async throws {
        addPhotos(["0001", "0002"])
        await engine.run(settings)
        #expect(status.uploadedThisPass == 2)
        addPhotos(["0003"])
        await engine.run(settings)
        #expect(status.uploadedThisPass == 1)
        #expect(status.uploaded == 3)
    }

    @Test func aLostConnectionWaitsForTheNextNetworkChange() async throws {
        addPhotos(["0001"])
        await engine.setNetwork(BackupNetwork())
        remote.state.withLock { $0.searchErrors = [.offline] }
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.offline.message))
        // The path still looks fine, so nothing is retried in a loop…
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.uploads.isEmpty)
        #expect(await engine.isWaitingToResume)
        // …until the network changes.
        await engine.setNetwork(BackupNetwork(isConstrained: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.uploads.isEmpty)
        await engine.setNetwork(BackupNetwork())
        #expect(await eventually { remote.uploads.count == 1 && status.phase == .upToDate })
    }

    @Test func shutdownForgetsAWaitingRun() async throws {
        addPhotos(["0001"])
        var wifiOnly = settings
        wifiOnly.wifiOnly = true
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(wifiOnly)
        #expect(await engine.isWaitingToResume)

        // The account is removed: Wi-Fi coming back or a new run must not start uploads into its closed database.
        await engine.shutdown()
        #expect(await !engine.isWaitingToResume)
        await engine.setNetwork(BackupNetwork(isExpensive: false))
        await engine.run(settings)
        try await Task.sleep(for: .milliseconds(100))
        #expect(remote.uploads.isEmpty)
    }

    @Test func changedSettingsLiftAPause() async throws {
        addPhotos(["0001"])
        var wifiOnly = settings
        wifiOnly.wifiOnly = true
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(wifiOnly)
        #expect(remote.uploads.isEmpty)
        await engine.settingsChanged(settings)
        #expect(await eventually { remote.uploads.count == 1 })
    }

    // MARK: Errors that stop the run (review point 4)

    @Test func aFullQuotaStopsTheRun() async throws {
        addPhotos(["0001", "0002", "0003"])
        remote.state.withLock { $0.uploadError = .insufficientStorage }
        await engine.run(settings)
        #expect(library.exports == ["IMG_0001.HEIC"])
        #expect(status.blocker == .insufficientStorage)
        #expect(status.phase == .failed(NetworkError.insufficientStorage.localizedDescription))
        #expect(status.failed == 1)
        #expect(try await entry("0002")?.state == BackupItemState.pending.rawValue)

        // The next run tries one other file, not the same one and not all of them.
        await engine.run(settings)
        #expect(library.exports == ["IMG_0001.HEIC", "IMG_0002.HEIC"])
        #expect(status.blocker == .insufficientStorage)

        // Space again: the blocker is gone and the rest uploads; the two that failed wait for their retry time.
        remote.state.withLock { $0.uploadError = nil }
        await engine.run(settings)
        #expect(status.blocker == nil)
        #expect(remote.uploads == ["IMG_0003.heic"])
        clock.advance(16 * 60)
        await engine.run(settings)
        #expect(remote.uploads.count == 3)
        #expect(status.phase == .upToDate)
        #expect(status.failed == 0)
    }

    @Test func anInvalidLoginStopsTheRunWithoutBlamingTheFile() async throws {
        addPhotos(["0001", "0002"])
        remote.state.withLock { $0.uploadError = .unauthorized }
        await engine.run(settings)
        #expect(library.exports.count == 1)
        #expect(status.blocker == .unauthorized)
        #expect(status.failed == 0)
        #expect(try await entry("0001")?.state == BackupItemState.pending.rawValue)

        remote.state.withLock { $0.uploadError = nil }
        await engine.run(settings)
        #expect(remote.uploads.count == 2)
        #expect(status.blocker == nil)
    }

    @Test func aRefusedUploadStopsTheRun() async throws {
        addPhotos(["0001", "0002"])
        remote.state.withLock { $0.uploadError = .forbidden(message: "Read-only folder") }
        await engine.run(settings)
        #expect(library.exports.count == 1)
        #expect(status.blocker == .forbidden)
        #expect(status.phase == .failed("Read-only folder"))
    }

    @Test func aRejectedReconciliationIsABlockerToo() async throws {
        addPhotos(["0001"])
        remote.state.withLock { $0.searchErrors = [.unauthorized] }
        await engine.run(settings)
        #expect(status.blocker == .unauthorized)
        #expect(library.exports.isEmpty)
    }

    // MARK: Backoff (review point 4)

    @Test func aFailingFileBacksOffAndTheOthersGoOn() async throws {
        addPhotos(["0001", "0002"])
        library.state.withLock { $0.exportErrors["IMG_0001.HEIC"] = CocoaError(.fileReadCorruptFile) }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0002.heic"])
        #expect(status.blocker == nil)
        #expect(status.failed == 1)
        #expect(try await entry("0001")?.attempts == 1)
        #expect(library.exports.count == 2)

        // Not exported again on the next runs…
        await engine.run(settings)
        await engine.run(settings)
        #expect(library.exports.count == 2)
        #expect(library.lastScan == [])

        // …until the first delay (15 min) is over; then the second one (1 h) applies.
        clock.advance(16 * 60)
        await engine.run(settings)
        #expect(library.exports.count == 3)
        #expect(try await entry("0001")?.attempts == 2)
        clock.advance(16 * 60)
        await engine.run(settings)
        #expect(library.exports.count == 3)
        clock.advance(60 * 60)
        await engine.run(settings)
        #expect(library.exports.count == 4)
        #expect(try await entry("0001")?.attempts == 3)

        // "Retry now" and a change of the asset both skip the wait.
        await engine.run(settings, retryFailed: true)
        #expect(library.exports.count == 5)
        library.state.withLock {
            $0.assets[0].modifiedAt = t0 + 900; $0.assets[0].resources[0].modifiedAt = t0 + 900
        }
        await engine.run(settings)
        #expect(library.exports.count == 6)

        // Success starts the count again.
        library.state.withLock { $0.exportErrors = [:] }
        await engine.run(settings, retryFailed: true)
        #expect(try await entry("0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry("0001")?.attempts == 0)
    }

    // MARK: Edits, RAW, forced uploads, Live Photos

    @Test func anEditOfAPhotoThatIsOnTheServerIsUploaded() async throws {
        addPhotos(["0001"])
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic"])

        // The user edits the photo; a RAW shows up as well. The server has IMG_0001.heic at the same second.
        library.state.withLock {
            $0.assets[0].modifiedAt = t0 + 100
            $0.assets[0].resources = [
                resource("0001", modified: 100), resource("0001", .edited, name: "IMG_E0001.HEIC", modified: 100, size: 20),
                resource("0001", .raw, name: "IMG_0001.DNG", modified: 100, size: 30),
            ]
        }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_E0001.heic", "IMG_0001.dng"])

        // Favouriting changes the modification date, not the edit: nothing is exported.
        library.state.withLock { state in
            state.assets[0].modifiedAt = t0 + 200
            for index in state.assets[0].resources.indices { state.assets[0].resources[index].modifiedAt = t0 + 200 }
        }
        await engine.run(settings)
        #expect(library.exports.count == 3)

        // A new edit (other data) is uploaded although the server has a file named IMG_E0001 from that second.
        library.state.withLock { state in
            state.assets[0].modifiedAt = t0 + 300
            for index in state.assets[0].resources.indices { state.assets[0].resources[index].modifiedAt = t0 + 300 }
            state.assets[0].resources[1].byteSize = 25
        }
        await engine.run(settings)
        #expect(remote.attempts.suffix(1) == ["IMG_E0001.heic"])
        #expect(library.exports.count == 4)
    }

    @Test func aLedgerResetFindsEveryRenditionAgain() async throws {
        library.state.withLock {
            $0.assets = [
                .init(
                    id: "0001", modifiedAt: t0,
                    resources: [
                        resource("0001"), resource("0001", .edited, name: "IMG_E0001.HEIC", size: 20),
                        resource("0001", .raw, name: "IMG_0001.DNG", size: 30),
                    ])
            ]
        }
        await engine.run(settings)
        #expect(remote.uploads.count == 3)
        try await engine.reset()
        await engine.run(settings)
        #expect(remote.uploads.count == 3)
        #expect(status.matched == 3)
        #expect(try await entry("0001", .edited)?.serverPath?.hasSuffix("IMG_E0001.heic") == true)
        #expect(try await entry("0001", .raw)?.serverPath?.hasSuffix("IMG_0001.dng") == true)
        #expect(try await entry("0001", .photo)?.serverPath?.hasSuffix("IMG_0001.heic") == true)
    }

    @Test func wrongMatchesOfEarlierVersionsAreRepaired() async throws {
        // What the old matcher left behind: the edit and the RAW "matched" with the original's file.
        let photo = resource("0001")
        let edit = resource("0001", .edited, name: "IMG_E0001.HEIC", size: 20)
        let raw = resource("0001", .raw, name: "IMG_0001.DNG", size: 30)
        library.state.withLock { $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [photo, edit, raw])] }
        remote.state.withLock {
            $0.files = [RemoteCandidate(fileId: 5, path: "/Photos/IMG_0001.heic", kind: .image, size: 10, capturedAt: t0, modifiedAt: t0)]
        }
        for resource in [photo, edit, raw] {
            try await engine.record(
                resource, state: .matched, matchedBy: .serverTimeName, serverPath: "/Photos/IMG_0001.heic", serverFileId: 5)
        }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_E0001.heic", "IMG_0001.dng"])
        #expect(try await entry("0001")?.state == BackupItemState.matched.rawValue)
        #expect(try await entry("0001", .edited)?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func uploadAnywayIsNotMatchedAgain() async throws {
        addPhotos(["0001"])
        remote.state.withLock {
            $0.files = [RemoteCandidate(fileId: 5, path: "/Other/IMG_0001.jpg", kind: .image, size: 999, capturedAt: t0, modifiedAt: t0)]
        }
        await engine.run(settings)
        #expect(remote.uploads.isEmpty)
        #expect(try await entry("0001")?.state == BackupItemState.matched.rawValue)

        try await engine.forgetMatch(localIdentifier: "0001", kind: BackupResourceKind.photo.rawValue)
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic"])
        #expect(try await entry("0001")?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func livePhotoHalvesAreLinkedAcrossRuns() async throws {
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        remote.state.withLock { $0.uploadErrors["IMG_0001.mov"] = .locked }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic"])
        #expect(remote.links.isEmpty)

        remote.state.withLock { $0.uploadErrors = [:] }
        clock.advance(16 * 60)
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0001.mov"])
        #expect(remote.links == [.init(imagePath: "/Photos/2026/09/IMG_0001.heic", videoPath: "/Photos/2026/09/IMG_0001.mov")])
    }

    @Test func livePhotoHalvesOfOneRunAreLinkedOnce() async throws {
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        await engine.run(settings)
        #expect(remote.links.count == 1)
    }
}

// MARK: - Policy

@Suite struct BackupUploadFoldersTests {
    @Test func foldersAreRememberedInTheAccountDatabase() throws {
        let database = try AccountDatabase.temporary()
        let folders = BackupUploadFolders(database: database)
        #expect(folders.entries().isEmpty)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        folders.touch("photos-a", at: date)
        folders.touch("photos-b", at: date + 10)
        folders.touch("photos-a", at: date + 20)
        // Another instance on the same database sees them.
        #expect(BackupUploadFolders(database: database).entries() == ["photos-a": date + 20, "photos-b": date + 10])
        folders.remove("photos-a")
        #expect(folders.entries() == ["photos-b": date + 10])
    }
}

@Suite struct BackupPolicyTests {
    func entry(_ state: BackupItemState, attempts: Int = 0, modified: Double? = 100, updated: Double = 1000, fingerprint: String? = nil)
        -> BackupLedgerEntry
    {
        BackupLedgerEntry(
            localIdentifier: "a", resourceKind: "photo", fingerprint: fingerprint, state: state.rawValue, serverPath: nil,
            serverFileId: nil,
            serverEtag: nil, matchedBy: nil, attempts: attempts, lastError: nil, assetCreatedAt: 0, assetModifiedAt: modified,
            updatedAt: updated)
    }

    @Test func pauseReasons() {
        var settings = BackupSettings()
        let wifi = BackupNetwork()
        let cellular = BackupNetwork(isExpensive: true)
        #expect(BackupPolicy.pauseReason(settings, network: nil, lowPower: false, isVideo: true) == nil)
        #expect(BackupPolicy.pauseReason(settings, network: wifi, lowPower: false, isVideo: true) == nil)
        #expect(BackupPolicy.pauseReason(settings, network: BackupNetwork(isConnected: false), lowPower: false, isVideo: false) == .offline)
        // Defaults: videos wait for Wi-Fi, photos don't.
        #expect(BackupPolicy.pauseReason(settings, network: cellular, lowPower: false, isVideo: true) == .wifi)
        #expect(BackupPolicy.pauseReason(settings, network: cellular, lowPower: false, isVideo: false) == nil)
        #expect(
            BackupPolicy.pauseReason(settings, network: BackupNetwork(isConstrained: true), lowPower: false, isVideo: false) == .lowData)
        #expect(BackupPolicy.pauseReason(settings, network: nil, lowPower: true, isVideo: false) == .lowPower)
        settings.wifiOnly = true
        settings.allowLowDataMode = true
        settings.pauseInLowPowerMode = false
        #expect(BackupPolicy.pauseReason(settings, network: cellular, lowPower: false, isVideo: false) == .wifi)
        #expect(BackupPolicy.pauseReason(settings, network: BackupNetwork(isConstrained: true), lowPower: true, isVideo: false) == nil)
    }

    @Test func retryDelaysGrowUpToADay() {
        #expect(BackupPolicy.retryDelay(attempts: 0) == 0)
        #expect(BackupPolicy.retryDelay(attempts: 1) == 15 * 60)
        #expect(BackupPolicy.retryDelay(attempts: 2) == 3600)
        #expect(BackupPolicy.retryDelay(attempts: 4) == 16 * 3600)
        #expect(BackupPolicy.retryDelay(attempts: 5) == 24 * 3600)
        #expect(BackupPolicy.retryDelay(attempts: 500) == 24 * 3600)
        let failed = entry(.failed, attempts: 2, updated: 1000)
        #expect(BackupPolicy.isBackingOff(failed, now: Date(timeIntervalSince1970: 1000 + 3599)))
        #expect(!BackupPolicy.isBackingOff(failed, now: Date(timeIntervalSince1970: 1000 + 3600)))
        #expect(!BackupPolicy.isBackingOff(entry(.uploaded, attempts: 2), now: Date(timeIntervalSince1970: 1001)))
    }

    @Test func blockers() {
        #expect(BackupPolicy.blocker(for: NetworkError.insufficientStorage) == .insufficientStorage)
        #expect(BackupPolicy.blocker(for: NetworkError.unauthorized) == .unauthorized)
        #expect(BackupPolicy.blocker(for: NetworkError.forbidden(message: nil)) == .forbidden)
        #expect(BackupPolicy.blocker(for: NetworkError.untrustedCertificate(host: "h", certificate: nil)) == .serverTrust)
        #expect(BackupPolicy.blocker(for: NetworkError.locked) == nil)
        #expect(BackupPolicy.blocker(for: NetworkError.notFound) == nil)
        #expect(BackupPolicy.blocker(for: CocoaError(.fileNoSuchFile)) == nil)
    }

    @Test func whichAssetsNeedAScan() {
        let now = Date(timeIntervalSince1970: 1010)
        let unchanged = Date(timeIntervalSince1970: 100.4)
        #expect(BackupPolicy.needsScan(entries: [], modifiedAt: unchanged, now: now))
        #expect(!BackupPolicy.needsScan(entries: [entry(.uploaded), entry(.matched)], modifiedAt: unchanged, now: now))
        #expect(BackupPolicy.needsScan(entries: [entry(.uploaded), entry(.pending)], modifiedAt: unchanged, now: now))
        #expect(BackupPolicy.needsScan(entries: [entry(.uploaded)], modifiedAt: Date(timeIntervalSince1970: 200), now: now))
        #expect(BackupPolicy.needsScan(entries: [entry(.uploaded)], modifiedAt: nil, now: now))
        #expect(!BackupPolicy.needsScan(entries: [entry(.uploaded, modified: nil)], modifiedAt: nil, now: now))
        // Failed: only when the retry is due.
        #expect(!BackupPolicy.needsScan(entries: [entry(.failed, attempts: 1)], modifiedAt: unchanged, now: now))
        #expect(BackupPolicy.needsScan(entries: [entry(.failed, attempts: 1)], modifiedAt: unchanged, now: now + 900))
    }
}
