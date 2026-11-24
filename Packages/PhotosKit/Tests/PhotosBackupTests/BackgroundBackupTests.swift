// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// A background transfer session that uploads nothing: tests decide what "the system" reports and when.
final class FakeTransport: BackgroundUploading {
    struct Started: Sendable {
        var jobId: String
        var request: HTTPRequest
        var file: URL
        /// The file was where the request said when the upload started.
        var fileExisted: Bool
    }

    struct State: Sendable {
        var started: [Started] = []
        var active: Set<String> = []
        var cancelled: Set<String> = []
        var startError: NetworkError?
        var handled = 0
    }

    let identifier = "tests.backup"
    let state = Mutex(State())
    let signals: AsyncStream<BackgroundUploadSignal>
    let continuation: AsyncStream<BackgroundUploadSignal>.Continuation

    init() {
        (signals, continuation) = AsyncStream.makeStream(of: BackgroundUploadSignal.self)
    }

    var started: [Started] { state.withLock { $0.started } }
    var active: Set<String> { state.withLock { $0.active } }
    var cancelled: Set<String> { state.withLock { $0.cancelled } }

    func start(jobId: String, request: HTTPRequest, file: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        try state.withLock { state in
            if let error = state.startError { throw error }
            state.started.append(Started(jobId: jobId, request: request, file: file, fileExisted: exists))
            state.active.insert(jobId)
        }
    }

    func activeJobIds() async -> Set<String> { active }

    func cancel(jobIds: Set<String>) async {
        state.withLock { $0.cancelled.formUnion(jobIds.intersection($0.active)) }
    }

    func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void) {}

    func eventsHandled() { state.withLock { $0.handled += 1 } }

    /// The system no longer works on an upload (it finished, or it lost it).
    func deactivate(_ jobId: String) { state.withLock { _ = $0.active.remove(jobId) } }
}

@Suite(.timeLimit(.minutes(1))) struct BackgroundBackupTests {
    let library = FakeLibrary()
    let remote = FakeRemote()
    let transport = FakeTransport()
    let statuses = StatusLog()
    let database: AccountDatabase
    let directory = FileManager.default.temporaryDirectory.appending(path: "BackgroundBackupTests-\(UUID().uuidString)")
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

    func makeEngine(maxJobs: Int = 16, maxFileSize: Int64 = 1000, maxStagedBytes: Int64 = 100_000, exports: URL? = nil) async
        -> BackupEngine
    {
        var background = BackgroundUploads(transport: transport, directory: directory)
        background.maxJobs = maxJobs
        background.maxFileSize = maxFileSize
        background.maxStagedBytes = maxStagedBytes
        let engine = BackupEngine(
            library: library, remote: remote, database: database, accountId: AccountID(rawValue: "test"), background: background,
            exportDirectory: exports)
        let statuses = statuses
        await engine.setStatusHandler { status in statuses.values.withLock { $0.append(status) } }
        return engine
    }

    func resource(_ id: String, _ kind: BackupResourceKind = .photo, name: String? = nil, at offset: TimeInterval = 0, size: Int64 = 10)
        -> BackupResource
    {
        let isVideo = [.video, .editedVideo, .pairedVideo].contains(kind)
        return BackupResource(
            localIdentifier: id, kind: kind, mediaKind: isVideo ? .video : .image,
            originalName: name ?? "IMG_\(id).\(isVideo ? "MOV" : "HEIC")", createdAt: t0 + offset, modifiedAt: t0, pixelWidth: 0,
            pixelHeight: 0, byteSize: size)
    }

    func add(_ resources: BackupResource...) {
        library.state.withLock { state in
            for resource in resources {
                state.assets.append(.init(id: resource.localIdentifier, modifiedAt: t0, resources: [resource]))
            }
        }
    }

    func addPhotos(_ ids: [String]) {
        for (index, id) in ids.enumerated() { add(resource(id, at: TimeInterval(index) * 3600)) }
    }

    func entry(_ engine: BackupEngine, _ id: String) async throws -> BackupLedgerEntry? {
        try await engine.ledgerEntries(of: id).first
    }

    func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// The id of the upload of a file name.
    func job(_ name: String) -> String? {
        transport.started.last { $0.request.url.lastPathComponent == name }?.jobId
    }

    /// "The system" reports an upload: the server's answer, or an error.
    func report(_ engine: BackupEngine, _ name: String, status code: Int = 201, error: NetworkError? = nil) async {
        guard let id = job(name) else {
            Issue.record("no upload of \(name) was started")
            return
        }
        transport.deactivate(id)
        let response = error == nil ? HTTPResponse(status: code) : nil
        await engine.backgroundUploadFinished(BackgroundUploadEvent(jobId: id, response: response, error: error))
    }

    var stagedFiles: [String] { Sandbox.files(in: directory).filter { !$0.hasSuffix("journal.json") } }

    /// "The system" sends the chunks and the MOVE of every chunked upload as the engine hands them over, until none is left.
    func completeChunked(_ engine: BackupEngine, status code: Int = 201) async {
        for _ in 0..<1000 {
            let pending = transport.started.filter { $0.request.url.path().contains("/uploads/") && transport.active.contains($0.jobId) }
            if pending.isEmpty {
                if await engine.chunkedJobs.isEmpty { return }
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            for job in pending {
                transport.deactivate(job.jobId)
                await engine.backgroundUploadFinished(BackgroundUploadEvent(jobId: job.jobId, response: HTTPResponse(status: code)))
            }
        }
        Issue.record("the chunked uploads did not end")
    }

    enum Sandbox {
        static func files(in directory: URL) -> [String] {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
                return []
            }
            var result: [String] = []
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url.lastPathComponent)
            }
            return result.sorted()
        }
    }

    // MARK: Review r2

    /// Item 2: one big video at the head of the queue must not hold back what the system could already be uploading.
    @Test func filesTheSystemCanTakeGoBeforeALargeOneAndAnInterruptedLargeExportIsKept() async throws {
        let exports = FileManager.default.temporaryDirectory.appending(path: "BackgroundBackupTests-exports-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: exports)
        }
        // The oldest item is larger than what the system takes.
        add(resource("0001", .video, at: 0, size: 5000), resource("0002", at: 3600), resource("0003", at: 7200))
        let engine = await makeEngine(exports: exports)
        await engine.setKeptExportMinimumSize(2000)
        let remote = remote
        // The app's own upload of the large file never gets through: the background time runs out first.
        remote.beforeUpload.withLock {
            $0 = { name in
                guard name == "IMG_0001.mov" else { return }
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { remote.state.withLock { $0.uploadErrors[name] = .cancelled } }
            }
        }
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { library.exports.contains("IMG_0001.MOV") })
        // Both small files were with the system before the large one was even read.
        #expect(transport.started.map(\.request.url.lastPathComponent) == ["IMG_0002.heic", "IMG_0003.heic"])
        #expect(library.exports == ["IMG_0002.HEIC", "IMG_0003.HEIC", "IMG_0001.MOV"])
        await engine.interrupt()
        await pass.value
        #expect(status.isInterrupted)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        // The small ones go on without the app, and the large export waits for the next attempt.
        #expect(await engine.backgroundJobs.count == 2)
        #expect(Sandbox.files(in: exports).contains("IMG_0001.MOV"))

        // The next launch: the export is still needed, so it is not swept, and it is not read again.
        remote.beforeUpload.withLock { $0 = nil }
        remote.state.withLock { $0.uploadErrors = [:] }
        let later = await makeEngine(exports: exports)
        let next = Task { await later.run(settings) }
        #expect(await eventually { await !later.chunkedJobs.isEmpty })
        await completeChunked(later)
        #expect(remote.uploads == ["IMG_0001.mov"])
        await report(later, "IMG_0002.heic")
        await report(later, "IMG_0003.heic")
        await next.value
        #expect(library.exports.filter { $0 == "IMG_0001.MOV" }.count == 1)
        #expect(status.phase == .upToDate)
        #expect(Sandbox.files(in: exports).isEmpty)
    }

    /// Item 2: a file PhotoKit gave no size for, which turns out too large for the system, waits for the small ones too.
    @Test func aFileOfUnknownSizeThatTurnsOutLargeIsPostponed() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var unknown = resource("0001", .video, at: 0)
        unknown.byteSize = nil
        add(unknown, resource("0002", at: 3600))
        library.state.withLock { $0.exportedSizes["IMG_0001.MOV"] = 5000 }
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { await !engine.chunkedJobs.isEmpty })
        // The small one was handed over before the large one was prepared for its chunks; it was exported once.
        #expect(remote.attempts == ["IMG_0002.heic", "IMG_0001.mov"])
        #expect(library.exports == ["IMG_0001.MOV", "IMG_0002.HEIC"])
        await completeChunked(engine)
        #expect(remote.uploads == ["IMG_0001.mov"])
        await report(engine, "IMG_0002.heic")
        await pass.value
        #expect(status.phase == .upToDate)
    }

    /// Item 6: the system's PUT was refused because the name was taken after the name check.
    @Test func aNameThatWasTakenMeanwhileIsPreparedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        let path = try #require(await engine.backgroundJobs.values.first?.path)
        // Another client put another file there; the server answers 412 to `If-None-Match: *`.
        remote.state.withLock {
            $0.files.append(RemoteCandidate(fileId: 7, path: path, kind: .image, size: 999, capturedAt: nil, modifiedAt: t0))
        }
        await report(engine, "IMG_0001.heic", status: 412)
        // Not a failure: the same pass prepares it again and gets the next free name.
        #expect(await eventually { transport.started.count == 2 })
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        #expect(transport.started.last?.request.url.lastPathComponent == "IMG_0001 (2).heic")
        await report(engine, "IMG_0001 (2).heic")
        await pass.value
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverPath?.hasSuffix("/IMG_0001 (2).heic") == true)
        #expect(status.phase == .upToDate)
        #expect(stagedFiles.isEmpty)
    }

    /// Item 6: the file that took the name is this very file (the first answer got lost): found, not uploaded twice.
    @Test func aNameTakenByTheSameFileCountsAsUploaded() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        let path = try #require(await engine.backgroundJobs.values.first?.path)
        remote.state.withLock {
            $0.files.append(RemoteCandidate(fileId: 7, path: path, kind: .image, size: 10, capturedAt: nil, modifiedAt: t0))
        }
        await report(engine, "IMG_0001.heic", status: 412)
        await pass.value
        #expect(transport.started.count == 1)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 7)
        #expect(status.phase == .upToDate)
    }

    // MARK: Handing over and recording

    @Test func filesAreHandedToTheSystemAndRecordedWhenItReports() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002", "0003"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 3 })
        // All three are with the system, each with its file in place; nothing counts as uploaded yet.
        #expect(transport.started.filter(\.fileExisted).count == 3)
        #expect(transport.started.map(\.request.method) == ["PUT", "PUT", "PUT"])
        #expect(stagedFiles == ["IMG_0001.HEIC", "IMG_0002.HEIC", "IMG_0003.HEIC"])
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(status.phase == .uploading(done: 0, total: 3, current: "IMG_0003.HEIC"))
        #expect(remote.uploads.isEmpty)
        #expect(await engine.backgroundJobs.count == 3)

        await report(engine, "IMG_0002.heic")
        #expect(try await entry(engine, "0002")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0002")?.serverPath?.hasSuffix("/IMG_0002.heic") == true)
        #expect(status.phase == .uploading(done: 1, total: 3, current: "IMG_0003.HEIC"))
        #expect(stagedFiles == ["IMG_0001.HEIC", "IMG_0003.HEIC"])

        await report(engine, "IMG_0001.heic")
        await report(engine, "IMG_0003.heic")
        await pass.value
        #expect(status.phase == .upToDate)
        #expect(status.uploaded == 3)
        #expect(status.uploadedThisPass == 3)
        #expect(status.pending == 0)
        #expect(stagedFiles.isEmpty)
        #expect(await engine.backgroundJobs.isEmpty)
        // The app itself sent nothing.
        #expect(remote.attempts.count == 3)
        #expect(remote.uploads.sorted() == ["IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic"])
    }

    @Test func onlyAFewUploadsAreHandedOverAhead() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002", "0003", "0004"])
        let engine = await makeEngine(maxJobs: 2)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.started.count == 2)
        #expect(library.exports.count == 2)  // nothing is copied out of the library before there is room

        await report(engine, "IMG_0001.heic")
        #expect(await eventually { transport.started.count == 3 })
        await report(engine, "IMG_0002.heic")
        await report(engine, "IMG_0003.heic")
        #expect(await eventually { transport.started.count == 4 })
        await report(engine, "IMG_0004.heic")
        await pass.value
        #expect(status.phase == .upToDate)
    }

    @Test func theSizeOfWhatWaitsIsLimitedToo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", size: 60), resource("0002", at: 3600, size: 60), resource("0003", at: 7200, size: 10))
        let engine = await makeEngine(maxStagedBytes: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.started.count == 1)
        await report(engine, "IMG_0001.heic")
        #expect(await eventually { transport.started.count == 3 })
        await report(engine, "IMG_0002.heic")
        await report(engine, "IMG_0003.heic")
        await pass.value
        #expect(status.phase == .upToDate)
    }

    @Test func largeFilesGoInChunksThroughTheSystemToo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", size: 10), resource("0002", .video, at: 3600, size: 500))
        let engine = await makeEngine(maxFileSize: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { await !engine.chunkedJobs.isEmpty })
        #expect(transport.started.first?.request.url.lastPathComponent == "IMG_0001.heic")
        await completeChunked(engine)
        // The app itself sent nothing.
        #expect(remote.uploads == ["IMG_0002.mov"])
        await report(engine, "IMG_0001.heic")
        await pass.value
        #expect(status.phase == .upToDate)
        #expect(try await entry(engine, "0002")?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func aFileThatIsOnTheServerAlreadyIsNotSent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        // Same name and size in the destination folder, at another time (so the matcher does not find it): layer 5.
        let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: t0)
        remote.state.withLock {
            $0.files = [
                RemoteCandidate(
                    fileId: 7, path: "\(folder)/IMG_0001.heic", kind: .image, size: 10, capturedAt: nil, modifiedAt: t0 - 99_999)
            ]
        }
        await engine.run(settings)
        #expect(transport.started.isEmpty)
        #expect(try await entry(engine, "0001")?.serverFileId == 7)
        #expect(status.phase == .upToDate)
    }

    @Test func twoFilesOnTheirWayNeverShareAName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Same name, same folder, different photos.
        add(resource("a", name: "IMG_0001.HEIC", size: 10), resource("b", name: "IMG_0001.HEIC", at: 60, size: 20))
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        let names = transport.started.map { $0.request.url.lastPathComponent }
        #expect(names == ["IMG_0001.heic", "IMG_0001 (2).heic"])
        await report(engine, "IMG_0001.heic")
        await report(engine, "IMG_0001 (2).heic")
        await pass.value
        #expect(try await entry(engine, "a")?.serverPath != (try await entry(engine, "b")?.serverPath))
        #expect(status.uploaded == 2)
    }

    @Test func theRequestSaysWhichNetworksItMayUse() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"), resource("0002", .video, at: 3600))
        var settings = settings
        settings.wifiOnly = false
        settings.wifiOnlyForVideos = true
        settings.allowLowDataMode = false
        let engine = await makeEngine()
        let pass = Task { [settings] in await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        let photo = try #require(transport.started.first { $0.request.url.lastPathComponent == "IMG_0001.heic" })
        let video = try #require(transport.started.first { $0.request.url.lastPathComponent == "IMG_0002.mov" })
        #expect(photo.request.allowsExpensiveNetwork)
        #expect(!video.request.allowsExpensiveNetwork)
        #expect(!photo.request.allowsConstrainedNetwork)
        await report(engine, "IMG_0001.heic")
        await report(engine, "IMG_0002.mov")
        await pass.value
    }

    // MARK: Interrupted, relaunched

    @Test func anInterruptedPassLeavesItsUploadsToTheSystem() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await engine.interrupt()
        await pass.value
        #expect(status.phase == .idle)
        #expect(status.isInterrupted)
        #expect(transport.cancelled.isEmpty)
        #expect(await engine.backgroundJobs.count == 2)
        #expect(stagedFiles.count == 2)

        // The system reports them later, with no pass running.
        await report(engine, "IMG_0001.heic")
        await report(engine, "IMG_0002.heic")
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0002")?.state == BackupItemState.uploaded.rawValue)
        #expect(status.uploaded == 2)
        #expect(status.pending == 0)
        #expect(stagedFiles.isEmpty)

        await engine.run(settings)
        #expect(status.phase == .upToDate)
        #expect(transport.started.count == 2)
    }

    @Test func aLaterLaunchRecordsWhatAnEarlierOneHandedOver() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002", "0003"])
        let first = await makeEngine(maxJobs: 2)
        let pass = Task { await first.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await first.interrupt()
        await pass.value

        // The app was ended. The next launch has the record of the two uploads; one has finished meanwhile.
        let second = await makeEngine(maxJobs: 2)
        #expect(await second.backgroundJobs.count == 2)
        await report(second, "IMG_0001.heic")
        #expect(try await entry(second, "0001")?.state == BackupItemState.uploaded.rawValue)

        // Its pass does not send the one that is still on its way again; it hands over the third and waits for both.
        let next = Task { await second.run(settings) }
        #expect(await eventually { transport.started.count == 3 })
        #expect(transport.started.map { $0.request.url.lastPathComponent } == ["IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic"])
        await report(second, "IMG_0002.heic")
        await report(second, "IMG_0003.heic")
        await next.value
        #expect(status.phase == .upToDate)
        #expect(status.uploaded == 3)
        #expect(library.exports.count == 3)
    }

    @Test func aReportDuringTheScanIsNotUploadedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await engine.interrupt()
        await pass.value
        // The next pass is asking the server when the system reports the first upload.
        let reported = Mutex(false)
        let test = self
        remote.beforeCandidates.withLock {
            $0 = {
                guard !reported.withLock({ $0 }) else { return }
                reported.withLock { $0 = true }
                await test.report(engine, "IMG_0001.heic")
            }
        }
        // The user's "Back up now" asks the server again about what waits.
        let next = Task { await engine.run(settings, retryFailed: true) }
        // Only the second one is left for this pass, and it is with the system already.
        #expect(await eventually { status.phase == .uploading(done: 0, total: 1, current: "") })
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.matchedBy == MatchReason.ownUpload.rawValue)
        await report(engine, "IMG_0002.heic")
        await next.value
        #expect(status.phase == .upToDate)
        #expect(status.uploaded == 2)
        #expect(transport.started.count == 2)
        #expect(library.exports.count == 2)
    }

    // MARK: Pause, failures

    @Test func theUsersPauseTakesTheUploadsBack() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await engine.cancel()
        await pass.value
        #expect(status.phase == .paused(BackupPause.user.message))
        #expect(await eventually { transport.cancelled.count == 2 })
        // The system reports them as cancelled: still to do, not failed, files gone.
        await report(engine, "IMG_0001.heic", error: .cancelled)
        await report(engine, "IMG_0002.heic", error: .cancelled)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        #expect(stagedFiles.isEmpty)
        #expect(status.failed == 0)
        #expect(status.phase == .paused(BackupPause.user.message))
    }

    @Test func aFileTheServerRejectsBacksOffAndTheOthersGoOn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await report(engine, "IMG_0001.heic", status: 415)
        await report(engine, "IMG_0002.heic")
        await pass.value
        #expect(try await entry(engine, "0001")?.state == BackupItemState.failed.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 1)
        #expect(try await entry(engine, "0002")?.state == BackupItemState.uploaded.rawValue)
        #expect(status.failed == 1)
        // Not "up to date": one item is not on the server.
        #expect(status.phase == .incomplete(failed: 1))
        #expect(status.lastFailure != nil)
        #expect(status.pending == 0)
        #expect(stagedFiles.isEmpty)
    }

    @Test func aFullQuotaReportedByTheSystemStopsThePass() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002", "0003"])
        let engine = await makeEngine(maxJobs: 1)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        await report(engine, "IMG_0001.heic", status: 507)
        await pass.value
        #expect(status.blocker == .insufficientStorage)
        #expect(transport.started.count == 1)
        #expect(library.exports.count == 1)
    }

    @Test func aLostConnectionReportedByTheSystemWaitsForTheNetwork() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork())
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        await report(engine, "IMG_0001.heic", error: .offline)
        await pass.value
        #expect(status.phase == .paused(BackupPause.offline.message))
        #expect(await engine.isWaitingToResume)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        #expect(stagedFiles.isEmpty)
    }

    @Test func handingOverFailsLikeAnUpload() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        transport.state.withLock { $0.startError = .offline }
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork())
        await engine.run(settings)
        #expect(status.phase == .paused(BackupPause.offline.message))
        #expect(await engine.backgroundJobs.isEmpty)
        #expect(stagedFiles.isEmpty)
    }

    @Test func videosAreTakenBackWhenWiFiIsLost() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video), resource("0002", at: 3600))
        var settings = settings
        settings.wifiOnlyForVideos = true
        let engine = await makeEngine()
        await engine.setNetwork(BackupNetwork())
        let pass = Task { [settings] in await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        let video = try #require(job("IMG_0001.mov"))
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        #expect(await eventually { transport.cancelled == [video] })
        await report(engine, "IMG_0001.mov", error: .cancelled)
        await report(engine, "IMG_0002.heic")
        await pass.value
        #expect(status.phase == .paused(BackupPause.wifi.message))
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(try await entry(engine, "0002")?.state == BackupItemState.uploaded.rawValue)

        // Back on Wi-Fi the video is handed over again.
        await engine.setNetwork(BackupNetwork())
        #expect(await eventually { transport.started.count == 3 })
        await report(engine, "IMG_0001.mov")
        #expect(await eventually { status.phase == .upToDate })
    }

    // MARK: Lost uploads

    @Test func anUploadTheSystemLostIsGivenUpAndDoneAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        await engine.setMissingCheckInterval(0.05)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        // The system forgets the upload without a word.
        transport.deactivate(try #require(job("IMG_0001.heic")))
        await pass.value
        #expect(status.phase == .idle)
        #expect(status.pending == 1)
        #expect(await engine.backgroundJobs.isEmpty)
        #expect(stagedFiles.isEmpty)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)

        // The next pass hands it over again.
        let next = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 2 })
        await report(engine, "IMG_0001.heic")
        await next.value
        #expect(status.phase == .upToDate)
    }

    @Test func aReportThatIsOnItsWayIsNotOvertaken() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        await engine.setMissingCheckInterval(0.2)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        // The system has finished the upload; its report arrives a moment after the engine asked what is still active.
        let id = try #require(job("IMG_0001.heic"))
        transport.deactivate(id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await engine.backgroundJobs.count == 1)
        await engine.backgroundUploadFinished(BackgroundUploadEvent(jobId: id, response: HTTPResponse(status: 201)))
        await pass.value
        #expect(status.phase == .upToDate)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func removingTheAccountTakesTheUploadsBack() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001"])
        let engine = await makeEngine()
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        await engine.shutdown()
        await pass.value
        #expect(transport.cancelled.count == 1)
        // The report that follows touches nothing any more (the database is about to be deleted).
        await report(engine, "IMG_0001.heic", error: .cancelled)
        #expect(stagedFiles.isEmpty)
    }
}

@Suite struct BackgroundUploadJournalTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "JournalTests-\(UUID().uuidString)")

    func job(_ id: String, path: String, size: Int64 = 5) -> BackgroundUploadJob {
        let resource = BackupResource(
            localIdentifier: "asset-\(id)", kind: .photo, mediaKind: .image, originalName: "IMG.HEIC",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: nil, pixelWidth: 1, pixelHeight: 2, latitude: 48.1,
            longitude: 11.5, byteSize: size)
        return BackgroundUploadJob(
            id: id, resource: resource, path: path, size: size, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func makeFile(_ name: String) throws -> URL {
        let source = FileManager.default.temporaryDirectory.appending(path: "JournalTests-src-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4, 5]).write(to: source)
        return source
    }

    @Test func theRecordOutlivesTheApp() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = BackgroundUploadJournal(directory: directory)
        #expect(journal.jobs.isEmpty)
        let staged = try journal.stage(try makeFile("a.heic"), id: "1")
        try journal.add(job("1", path: "/Photos/a.heic"))
        try journal.add(job("2", path: "/Photos/b.heic", size: 7))
        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))

        var later = BackgroundUploadJournal(directory: directory)
        #expect(later.jobs == journal.jobs)
        #expect(later.reservedPaths == ["/Photos/a.heic", "/Photos/b.heic"])
        #expect(later.stagedBytes == 12)
        #expect(later.job(for: job("1", path: "").resource)?.id == "1")
        #expect(later.job(for: job("9", path: "").resource) == nil)

        #expect(later.remove("1") == job("1", path: "/Photos/a.heic"))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(later.remove("1") == nil)
        #expect(BackgroundUploadJournal(directory: directory).jobs.keys.sorted() == ["2"])
    }

    @Test func filesWithoutARecordAreRemoved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = BackgroundUploadJournal(directory: directory)
        let known = try journal.stage(try makeFile("a.heic"), id: "1")
        try journal.add(job("1", path: "/Photos/a.heic"))
        // The app ended after moving this file and before recording it.
        let unknown = try journal.stage(try makeFile("b.heic"), id: "2")
        journal.removeUnknownFiles()
        #expect(FileManager.default.fileExists(atPath: known.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: unknown.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: journal.file.path(percentEncoded: false)))
    }

    @Test func anUnreadableRecordStartsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "journal.json"))
        #expect(BackgroundUploadJournal(directory: directory).jobs.isEmpty)
    }
}
