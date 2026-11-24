// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// PhotoKit's upload jobs without PhotoKit: tests decide how each job ends.
final class FakeJobService: UploadJobService {
    struct Job: Sendable {
        var info: UploadJobInfo
        var resource: BackupResource
        var request: URLRequest
        var retried = false
        var acknowledged = false
    }

    struct State: Sendable {
        var jobs: [String: Job] = [:]
        var order: [String] = []
        var limit = 20
        var createError: (any Error)?
    }

    let state = Mutex(State())

    var jobLimit: Int { state.withLock { $0.limit } }

    var open: [Job] { state.withLock { state in state.order.compactMap { state.jobs[$0] }.filter { !$0.acknowledged } } }

    func endedJobs() async -> [UploadJobInfo] { open.filter { $0.info.state != .inFlight }.map(\.info) }

    func retryableJobs() async -> [UploadJobInfo] { open.filter { $0.info.state == .failed && !$0.retried }.map(\.info) }

    func jobsInFlight() async -> [UploadJobInfo] { open.filter { $0.info.state == .inFlight }.map(\.info) }

    func create(_ resource: BackupResource, settings: BackupSettings, request: URLRequest) async throws -> String {
        try state.withLock { state in
            if let error = state.createError { throw error }
            let id = "job-\(state.order.count + 1)"
            state.jobs[id] = Job(
                info: UploadJobInfo(id: id, destination: request.url, state: .inFlight), resource: resource, request: request)
            state.order.append(id)
            return id
        }
    }

    func acknowledge(_ ids: [String]) async throws {
        state.withLock { state in for id in ids { state.jobs[id]?.acknowledged = true } }
    }

    func retry(_ id: String, request: URLRequest) async throws {
        state.withLock { state in
            state.jobs[id]?.retried = true
            state.jobs[id]?.request = request
            state.jobs[id]?.info.destination = request.url
            state.jobs[id]?.info.state = .inFlight
        }
    }

    /// "PhotoKit" ends a job.
    func end(_ id: String, _ state: UploadJobInfo.State, headers: [String: String] = [:]) {
        self.state.withLock {
            $0.jobs[id]?.info.state = state
            $0.jobs[id]?.info.responseHeaders = headers
        }
    }

    func job(named name: String) -> Job? { open.first { $0.request.url?.lastPathComponent == name } }
}

@Suite(.timeLimit(.minutes(1))) struct UploadJobsTests {
    let library = FakeLibrary()
    let remote = FakeRemote()
    let service = FakeJobService()
    let clock = Clock()
    let database: AccountDatabase
    let directory = FileManager.default.temporaryDirectory.appending(path: "UploadJobsTests-\(UUID().uuidString)")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        database = try .temporary()
    }

    var journalFile: URL { directory.appending(path: "UploadJobs.json") }
    var appUploads: URL { directory.appending(path: "BackgroundUploads") }

    var settings: BackupSettings {
        var settings = BackupSettings()
        settings.isEnabled = true
        return settings
    }

    func makeEngine() -> BackupEngine {
        let clock = clock
        return BackupEngine(
            library: library, remote: remote, database: database, accountId: AccountID(rawValue: "test"), uploadJobs: journalFile,
            now: { clock.now })
    }

    func resource(_ id: String, _ kind: BackupResourceKind = .photo, at offset: TimeInterval = 0, size: Int64? = 10) -> BackupResource {
        let isVideo = [.video, .editedVideo, .pairedVideo].contains(kind)
        return BackupResource(
            localIdentifier: id, kind: kind, mediaKind: isVideo ? .video : .image, originalName: "IMG_\(id).\(isVideo ? "MOV" : "HEIC")",
            createdAt: t0 + offset, modifiedAt: t0, pixelWidth: 0, pixelHeight: 0, byteSize: size)
    }

    func add(_ resources: BackupResource...) {
        library.state.withLock { state in
            for resource in resources { state.assets.append(.init(id: resource.localIdentifier, modifiedAt: t0, resources: [resource])) }
        }
    }

    func process(_ engine: BackupEngine, settings: BackupSettings? = nil, lowPower: Bool = false) async -> UploadJobsResult {
        await engine.processUploadJobs(
            settings: settings ?? self.settings, service: service, journal: journalFile, appUploads: appUploads, lowPower: lowPower)
    }

    func entry(_ engine: BackupEngine, _ id: String) async throws -> BackupLedgerEntry? {
        try await engine.ledgerEntries(of: id).first
    }

    var journal: UploadJobJournal { UploadJobJournal(file: journalFile) }

    @Test func jobsAreCreatedForWhatIsNotOnTheServerUpToTheLimit() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"), resource("0002", at: 3600), resource("0003", at: 7200))
        service.state.withLock { $0.limit = 2 }
        let engine = makeEngine()
        #expect(await process(engine) == .processing)
        #expect(service.open.map(\.resource.localIdentifier) == ["0001", "0002"])
        // PhotoKit reads the library itself: nothing was exported.
        #expect(library.exports.isEmpty)
        let request = try #require(service.open.first?.request)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path().hasSuffix("/IMG_0001.heic") == true)
        #expect(journal.entries.count == 2)
        #expect(journal.entries.values.allSatisfy { $0.jobId != nil })
        // The ledger knows them as waiting; the server was asked about all three.
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
        #expect(remote.searches == 1)
    }

    @Test func endedJobsAreRecordedAndAcknowledgedAndMakeRoomForMore() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"), resource("0002", at: 3600), resource("0003", at: 7200))
        service.state.withLock { $0.limit = 2 }
        let engine = makeEngine()
        _ = await process(engine)
        let first = try #require(service.job(named: "IMG_0001.heic"))
        service.end(first.info.id, .succeeded, headers: ["oc-fileid": "00000077ocabc"])
        // PhotoKit says it failed, but the server's answer was there: the file arrived.
        let second = try #require(service.job(named: "IMG_0002.heic"))
        service.end(second.info.id, .failed, headers: ["oc-fileid": "00000078ocabc"])
        #expect(await process(engine) == .processing)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 77)
        #expect(try await entry(engine, "0001")?.matchedBy == MatchReason.ownUpload.rawValue)
        #expect(try await entry(engine, "0002")?.serverFileId == 78)
        // Acknowledged, and the room went to the third.
        #expect(service.open.map(\.resource.localIdentifier) == ["0003"])
        #expect(journal.entries.count == 1)
        service.end(service.open[0].info.id, .succeeded, headers: ["oc-fileid": "00000079ocabc"])
        #expect(await process(engine) == .completed)
        #expect(journal.entries.isEmpty)
        #expect(try await entry(engine, "0003")?.state == BackupItemState.uploaded.rawValue)
    }

    @Test func aFailedJobIsRetriedOnceUnderAFreeNameThenRecordedAsFailed() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        let engine = makeEngine()
        _ = await process(engine)
        let job = try #require(service.open.first)
        let path = try #require(journal.entries.keys.first)
        // Another file took the name meanwhile (the PUT got 412).
        remote.state.withLock {
            $0.files.append(RemoteCandidate(fileId: 5, path: path, kind: .image, size: 999, capturedAt: nil, modifiedAt: t0 - 99_999))
        }
        service.end(job.info.id, .failed)
        #expect(await process(engine) == .processing)
        #expect(service.open.first?.retried == true)
        #expect(service.open.first?.request.url?.lastPathComponent == "IMG_0001 (2).heic")
        #expect(journal.entries.keys.first?.hasSuffix("/IMG_0001 (2).heic") == true)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)

        service.end(job.info.id, .failed)
        #expect(await process(engine) == .completed)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.failed.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 1)
        #expect(journal.entries.isEmpty)
        // It backs off like any failed upload: no new job right away.
        #expect(service.open.isEmpty)
    }

    @Test func aFailedJobWhoseFileIsAtItsDestinationArrived() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        let engine = makeEngine()
        _ = await process(engine)
        let job = try #require(service.open.first)
        let path = try #require(journal.entries.keys.first)
        remote.state.withLock {
            $0.files.append(RemoteCandidate(fileId: 6, path: path, kind: .image, size: 10, capturedAt: nil, modifiedAt: t0))
        }
        service.end(job.info.id, .failed)
        #expect(await process(engine) == .completed)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 6)
        #expect(service.open.isEmpty)
    }

    @Test func aFailedJobDoesNotUndoWhatTheAppUploadedMeanwhile() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        let engine = makeEngine()
        _ = await process(engine)
        let job = try #require(service.open.first)
        try await engine.record(resource("0001"), state: .uploaded, matchedBy: .ownUpload, serverPath: "/Photos/x.heic", serverFileId: 3)
        service.state.withLock { $0.jobs[job.info.id]?.retried = true }
        service.end(job.info.id, .failed)
        _ = await process(engine)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 3)
    }

    @Test func aCancelledJobLeavesTheResourceWaiting() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        let engine = makeEngine()
        _ = await process(engine)
        service.end(service.open[0].info.id, .cancelled)
        _ = await process(engine)
        #expect(try await entry(engine, "0001")?.attempts == 0)
        // Taken up again with a new job.
        #expect(service.open.count == 1)
        #expect(service.open[0].info.state == .inFlight)
    }

    @Test func onlyWhatPhotoKitCanSendAsItIs() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(
            resource("0001"), resource("0002", .video, at: 3600, size: 200 * 1024 * 1024), resource("0003", at: 7200, size: nil),
            resource("0004", .raw, at: 10_800))
        let engine = makeEngine()
        _ = await process(engine)
        // Too large for PhotoKit, and of unknown size: the app sends those.
        #expect(Set(service.open.map(\.resource.localIdentifier)) == ["0001", "0004"])
        // "Most compatible" converts: only the RAW file is sent as it is.
        var compatible = settings
        compatible.format = .mostCompatible
        let other = FakeJobService()
        _ = await engine.processUploadJobs(
            settings: compatible, service: other, journal: directory.appending(path: "other.json"), appUploads: nil)
        #expect(other.open.map(\.resource.localIdentifier) == ["0004"])
    }

    @Test func noNewJobsInLowPowerModeOrWithoutICloudDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        let engine = makeEngine()
        #expect(await process(engine, lowPower: true) == .completed)
        var noICloud = settings
        noICloud.downloadFromICloud = false
        #expect(await process(engine, settings: noICloud) == .completed)
        var off = settings
        off.isEnabled = false
        #expect(await process(engine, settings: off) == .completed)
        #expect(service.open.isEmpty)
        #expect(await process(engine) == .processing)
        #expect(service.open.count == 1)
    }

    @Test func anEntryWhoseJobWasNeverCreatedIsForgottenAfterAWhile() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = UploadJobJournal(file: journalFile)
        try journal.set(UploadJobEntry(resource: resource("0009"), path: "/Photos/x.heic", size: 10, createdAt: clock.now))
        let engine = makeEngine()
        _ = await process(engine)
        #expect(self.journal.entries.count == 1)
        clock.advance(UploadJobPolicy.orphanAge + 1)
        _ = await process(engine)
        #expect(self.journal.entries.isEmpty)
    }

    @Test func photoKitsLimitEndsTheRunWithoutAFailure() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"))
        service.state.withLock { $0.createError = NSError(domain: "PHPhotosErrorDomain", code: 3307) }
        let engine = makeEngine()
        #expect(await process(engine) == .completed)
        #expect(journal.entries.isEmpty)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)
    }

    // MARK: The app and PhotoKit never send the same resource

    @Test func theAppLeavesWhatPhotoKitSendsAndKeepsItsNameFree() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"), resource("0002", at: 3600))
        service.state.withLock { $0.limit = 1 }
        _ = await process(makeEngine())
        #expect(service.open.map(\.resource.localIdentifier) == ["0001"])
        // A pass of the app meanwhile.
        let app = makeEngine()
        await app.run(settings)
        #expect(remote.uploads == ["IMG_0002.heic"])
        #expect(try await entry(app, "0001")?.state == BackupItemState.pending.rawValue)
    }

    @Test func photoKitLeavesWhatTheAppsSessionHas() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001"), resource("0002", at: 3600))
        // The app handed 0001 to its own transfer session.
        let transport = FakeTransport()
        let app = BackupEngine(
            library: library, remote: remote, database: database, accountId: AccountID(rawValue: "test"),
            background: BackgroundUploads(transport: transport, directory: appUploads))
        let pass = Task { await app.run(settings) }
        for _ in 0..<500 where transport.started.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await app.interrupt()
        await pass.value
        let appPaths = Set(await app.backgroundJobs.values.map(\.path))
        #expect(appPaths.count == 2)
        // A third photo with the same name as one the app sends, at another time.
        add(resource("0003", at: 7200))
        library.state.withLock { $0.assets[2].resources[0].originalName = "IMG_0001.HEIC" }
        _ = await process(makeEngine())
        #expect(service.open.map(\.resource.localIdentifier) == ["0003"])
        // Its name is not one the app's uploads will take.
        let path = try #require(journal.entries.keys.first)
        #expect(!appPaths.contains(path))
    }
}
