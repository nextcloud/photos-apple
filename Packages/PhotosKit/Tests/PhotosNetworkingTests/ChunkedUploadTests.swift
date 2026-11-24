// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosNetworking

/// The state machine of a chunked upload sent by a background transfer session (SPEC §7.18.6).
@Suite struct ChunkedUploadStateTests {
    func upload(size: Int64 = 35, chunkSize: Int = 10) -> ChunkedUpload {
        ChunkedUpload(
            id: "u", path: "/Photos/v.mov", size: size, chunkSize: chunkSize, folder: URL(string: "https://s.test/uploads/a/photos-x/")!,
            destination: URL(string: "https://s.test/files/a/Photos/v.mov")!, headers: ["X-OC-MTime": "1"])
    }

    @Test func chunksAreHandedOverInOrderWithinTheWindowThenTheMove() {
        var upload = upload()
        #expect(upload.chunkCount == 4)
        #expect(upload.range(of: 4) == 30..<35)
        // Nothing before the folder exists.
        #expect(upload.next(limit: 8).isEmpty)
        upload.folderReady()
        #expect(upload.phase == .sending)
        #expect(upload.next(limit: 2) == [.chunk(1), .chunk(2)])
        upload.started(.chunk(1), jobId: "j1")
        upload.started(.chunk(2), jobId: "j2")
        #expect(upload.next(limit: 2).isEmpty)
        #expect(upload.next(limit: 3) == [.chunk(3)])
        // Chunks finish in any order.
        #expect(upload.finished(jobId: "j2", status: 201, error: nil) == .continuing)
        #expect(upload.next(limit: 8) == [.chunk(3), .chunk(4)])
        upload.started(.chunk(3), jobId: "j3")
        upload.started(.chunk(4), jobId: "j4")
        for id in ["j1", "j3", "j4"] { #expect(upload.finished(jobId: id, status: 201, error: nil) == .continuing) }
        #expect(upload.phase == .assembling)
        #expect(upload.sentBytes == 35)
        #expect(upload.next(limit: 8) == [.assemble])
        upload.started(.assemble, jobId: "m")
        #expect(upload.next(limit: 8).isEmpty)
        #expect(
            upload.finished(jobId: "m", status: 201, headers: ["oc-fileid": "00000042oc"], error: nil)
                == .assembled(status: 201, headers: ["oc-fileid": "00000042oc"]))
        #expect(upload.phase == .finished)
        // A report that comes twice, or one that is not of this upload, changes nothing.
        #expect(upload.finished(jobId: "m", status: 201, error: nil) == .unknown)
        #expect(upload.finished(jobId: "other", status: 201, error: nil) == .unknown)
    }

    @Test func chunksAnEarlierAttemptLeftAreNotSentAgain() {
        var upload = upload()
        // Chunk 3 is incomplete, 9 is not a chunk of this file.
        upload.folderReady(existing: [1: 10, 2: 10, 3: 4, 9: 10])
        #expect(upload.sent == [1, 2])
        #expect(upload.next(limit: 8) == [.chunk(3), .chunk(4)])
        var complete = self.upload()
        complete.folderReady(existing: [1: 10, 2: 10, 3: 10, 4: 5])
        #expect(complete.phase == .assembling)
        #expect(complete.next(limit: 8) == [.assemble])
    }

    @Test func aVanishedUploadFolderStartsEverythingAgain() {
        var upload = upload()
        upload.folderReady()
        upload.started(.chunk(1), jobId: "j1")
        upload.started(.chunk(2), jobId: "j2")
        #expect(upload.finished(jobId: "j1", status: 201, error: nil) == .continuing)
        #expect(upload.finished(jobId: "j2", status: 404, error: nil) == .needsFolder)
        #expect(upload.phase == .needsFolder)
        #expect(upload.sent.isEmpty)
        #expect(upload.running.isEmpty)
        // The first MOVE that finds no folder means the same.
        var moving = self.upload()
        moving.folderReady(existing: [1: 10, 2: 10, 3: 10, 4: 5])
        moving.started(.assemble, jobId: "m")
        #expect(moving.finished(jobId: "m", status: 404, error: nil) == .needsFolder)
    }

    @Test func transientFailuresAreTriedAgainAFewTimesOthersEndTheUpload() {
        var upload = upload()
        upload.folderReady()
        for attempt in 1...ChunkedUpload.maxFailures {
            upload.started(.chunk(1), jobId: "j\(attempt)")
            let outcome = upload.finished(jobId: "j\(attempt)", status: nil, error: .timedOut)
            if attempt < ChunkedUpload.maxFailures {
                #expect(outcome == .continuing)
                #expect(upload.next(limit: 1) == [.chunk(1)])
            } else {
                #expect(outcome == .failed(.timedOut))
            }
        }
        #expect(upload.phase == .failed)
        #expect(upload.next(limit: 8).isEmpty)

        var refused = self.upload()
        refused.folderReady()
        refused.started(.chunk(2), jobId: "j")
        #expect(refused.finished(jobId: "j", status: 507, error: nil) == .failed(.insufficientStorage))
        var unauthorized = self.upload()
        unauthorized.folderReady()
        unauthorized.started(.chunk(2), jobId: "j")
        #expect(unauthorized.finished(jobId: "j", status: 401, error: nil) == .failed(.unauthorized))
    }

    @Test func aTakenBackOrLostRequestIsHandedOverAgain() {
        var upload = upload()
        upload.folderReady()
        upload.started(.chunk(1), jobId: "j1")
        upload.started(.chunk(2), jobId: "j2")
        #expect(upload.finished(jobId: "j1", status: nil, error: .cancelled) == .continuing)
        #expect(upload.failures.isEmpty)
        upload.lost(["j2"])
        #expect(upload.running.isEmpty)
        #expect(upload.next(limit: 2) == [.chunk(1), .chunk(2)])
    }

    @Test func aMoveWithoutAnAnswerLooksAtTheDestination() {
        var upload = upload()
        upload.folderReady(existing: [1: 10, 2: 10, 3: 10, 4: 5])
        upload.started(.assemble, jobId: "m1")
        #expect(upload.finished(jobId: "m1", status: nil, error: .timedOut) == .checkDestination(.timedOut))
        // Not there: once more.
        upload.retryAssembly()
        #expect(upload.next(limit: 8) == [.assemble])
        upload.started(.assemble, jobId: "m2")
        // After an earlier attempt a 404 means the folder was already moved.
        #expect(upload.finished(jobId: "m2", status: 404, error: nil) == .checkDestination(.notFound))
        upload.markFinished()
        #expect(upload.phase == .finished)
        // A file that appeared at the destination meanwhile.
        var taken = self.upload()
        taken.folderReady(existing: [1: 10, 2: 10, 3: 10, 4: 5])
        taken.started(.assemble, jobId: "m")
        #expect(taken.finished(jobId: "m", status: 412, error: nil) == .checkDestination(.preconditionFailed))
    }

    @Test func itSurvivesALaunch() throws {
        var upload = upload()
        upload.folderReady(existing: [1: 10])
        upload.started(.chunk(2), jobId: "j2")
        upload.started(.chunk(3), jobId: "j3")
        _ = upload.finished(jobId: "j3", status: nil, error: .offline)
        let decoded = try JSONDecoder().decode(ChunkedUpload.self, from: JSONEncoder().encode(upload))
        #expect(decoded == upload)
        #expect(decoded.running == ["j2": .chunk(2)])
        #expect(decoded.failures == ["chunk-3": 1])
    }
}

/// "The system" of the tests: keeps the requests it was given and sends them to the stub server when the test says so.
final class ManualTransport: BackgroundUploading {
    struct Job: Sendable {
        var jobId: String
        var request: HTTPRequest
        var body: Data
    }

    let identifier = "tests.chunked"
    let signals: AsyncStream<BackgroundUploadSignal>
    private let continuation: AsyncStream<BackgroundUploadSignal>.Continuation
    private let pending = Mutex<[Job]>([])
    let started = Mutex<[String]>([])

    init() {
        (signals, continuation) = AsyncStream.makeStream(of: BackgroundUploadSignal.self)
    }

    var jobs: [Job] { pending.withLock { $0 } }

    func start(jobId: String, request: HTTPRequest, file: URL) async throws {
        // Like the system: the file is read when the upload starts, and it has to be there.
        let body = try Data(contentsOf: file)
        pending.withLock { $0.append(Job(jobId: jobId, request: request, body: body)) }
        started.withLock { $0.append("\(request.method) \(request.url.lastPathComponent)") }
    }

    func activeJobIds() async -> Set<String> { Set(jobs.map(\.jobId)) }

    func cancel(jobIds: Set<String>) async {
        pending.withLock { $0.removeAll { jobIds.contains($0.jobId) } }
    }

    func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func eventsHandled() {}

    /// Sends every pending request to the server and returns what the system would report.
    func deliver(to server: UploadStubServer) -> [BackgroundUploadEvent] {
        let jobs = pending.withLock { jobs in
            defer { jobs = [] }
            return jobs
        }
        return jobs.map { job in
            switch server.handle(method: job.request.method, url: job.request.url, headers: job.request.headers, body: job.body) {
            case .response(let response):
                let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
                return BackgroundUploadEvent(jobId: job.jobId, response: HTTPResponse(status: response.status, headers: headers))
            case .failure(let code):
                return BackgroundUploadEvent(jobId: job.jobId, error: code == .timedOut ? .timedOut : .offline)
            }
        }
    }
}

/// Keeps a chunked upload the way an app keeps it between launches: as JSON.
actor UploadKeeper {
    var stored: Data?
    var upload: ChunkedUpload?

    func set(_ upload: ChunkedUpload) {
        self.upload = upload
        stored = try? JSONEncoder().encode(upload)
    }

    /// The upload as a new launch reads it.
    func reloaded() -> ChunkedUpload? {
        stored.flatMap { try? JSONDecoder().decode(ChunkedUpload.self, from: $0) }
    }

    func advance(_ driver: ChunkedUploadDriver, files: ChunkedUploadDriver.Files) async -> ChunkedUploadDriver.Progress {
        guard var upload else { return .running }
        let progress = await driver.advance(&upload, files: files) { self.set($0) }
        set(upload)
        return progress
    }

    func report(_ event: BackgroundUploadEvent, driver: ChunkedUploadDriver, files: ChunkedUploadDriver.Files) async
        -> ChunkedUploadDriver.Progress?
    {
        guard var upload else { return nil }
        let progress = await driver.report(event, upload: &upload, files: files) { self.set($0) }
        set(upload)
        return progress
    }

    func launch() { upload = reloaded() }
}

@Suite(.timeLimit(.minutes(1))) struct ChunkedUploadDriverTests {
    let server = UploadStubServer()
    let transport = ManualTransport()
    let directory = FileManager.default.temporaryDirectory.appending(path: "ChunkedUploadDriverTests-\(UUID().uuidString)")

    func makeFile(size: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "v.mov")
        try Data((0..<size).map { UInt8($0 % 251) }).write(to: file)
        return file
    }

    var files: ChunkedUploadDriver.Files {
        ChunkedUploadDriver.Files(file: directory.appending(path: "v.mov"), chunks: directory.appending(path: "chunks"))
    }

    func driver(window: Int = 2) -> ChunkedUploadDriver {
        var uploader = server.uploader
        uploader.folders = MemoryUploadFolders()
        return ChunkedUploadDriver(transport: transport, uploader: uploader, window: window)
    }

    func start(_ file: URL, keeper: UploadKeeper) async throws {
        guard
            case .chunked(let upload) = try await server.uploader.prepareChunked(
                file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        else {
            Issue.record("the destination is free")
            return
        }
        await keeper.set(upload)
    }

    /// Lets "the system" send everything until the upload ends.
    func run(_ driver: ChunkedUploadDriver, keeper: UploadKeeper, rounds: Int = 20) async -> ChunkedUploadDriver.Progress {
        var last = await keeper.advance(driver, files: files)
        for _ in 0..<rounds {
            if case .running = last {} else { return last }
            for event in transport.deliver(to: server) {
                if let progress = await keeper.report(event, driver: driver, files: files) { last = progress }
            }
        }
        return last
    }

    @Test func aLargeFileArrivesCompleteInChunksAndTheChunkFilesAreRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        let progress = await run(driver(), keeper: keeper)
        guard case .finished(let uploaded) = progress else {
            Issue.record("not finished: \(progress)")
            return
        }
        #expect(uploaded.path == "/Photos/v.mov")
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
        #expect(transport.started.withLock { $0 } == ["PUT 1", "PUT 2", "PUT 3", "PUT 4", "MOVE .file"])
        // The MOVE does not overwrite, and it carries the destination and the size.
        let move = server.requests.last { $0.method == "MOVE" }
        #expect(move?.headers["Overwrite"] == "F")
        #expect(move?.headers["OC-Total-Length"] == "35")
        #expect(move?.headers["OC-Checksum"]?.hasPrefix("SHA256:") == true)
        #expect(!FileManager.default.fileExists(atPath: files.chunks.path(percentEncoded: false)))
        #expect(server.uploads.isEmpty)
    }

    @Test func itGoesOnAfterALaunchWithWhatWasStarted() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        let driver = driver()
        _ = await keeper.advance(driver, files: files)
        // The app ends; the system goes on with the two chunks it has and reports them to the next launch.
        let events = transport.deliver(to: server)
        #expect(events.count == 2)
        await keeper.launch()
        for event in events { _ = await keeper.report(event, driver: driver, files: files) }
        #expect(await keeper.upload?.sent == [1, 2])
        let progress = await run(driver, keeper: keeper)
        guard case .finished = progress else {
            Issue.record("not finished: \(progress)")
            return
        }
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
        #expect(server.lines.filter { $0.hasPrefix("PUT /uploads/") }.count == 4)
    }

    @Test func anUploadTheAppStartedItselfIsContinued() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        // The app's own upload stopped after two chunks.
        server.fail("PUT", suffix: "/3", times: 4, with: .error(.timedOut))
        await #expect(throws: NetworkError.timedOut) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        #expect(await keeper.upload?.sent == [1, 2])
        server.clearRequests()
        guard case .finished = await run(driver(), keeper: keeper) else {
            Issue.record("not finished")
            return
        }
        #expect(server.lines.filter { $0.hasPrefix("PUT /uploads/") }.map { $0.split(separator: "/").last.map(String.init) } == ["3", "4"])
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func anExpiredUploadFolderIsCreatedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        // The server removes the folder after the first chunk.
        server.fail("PUT", suffix: "/2", with: .status(404), sideEffect: { $0.uploads = [:] })
        guard case .finished = await run(driver(window: 1), keeper: keeper) else {
            Issue.record("not finished")
            return
        }
        #expect(server.lines.filter { $0.hasPrefix("MKCOL /uploads/") }.count == 2)
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func aLostAnswerToTheMoveFindsTheFileAtItsDestination() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        server.fail("MOVE", afterHandling: true, with: .error(.timedOut))
        guard case .finished(let uploaded) = await run(driver(), keeper: keeper) else {
            Issue.record("not finished")
            return
        }
        #expect(uploaded.path == "/Photos/v.mov")
        #expect(server.lines.filter { $0.hasPrefix("MOVE") }.count == 1)
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func aFileThatTookTheNameMeanwhileIsNotOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        let other = Data(repeating: 1, count: 5)
        // Another client puts a file there before the MOVE.
        server.fail(
            "MOVE", afterHandling: false, with: .status(412),
            sideEffect: { state in
                state.files["/Photos/v.mov"] = other
                state.fileIds["/Photos/v.mov"] = 7
            })
        let progress = await run(driver(), keeper: keeper)
        guard case .failed(let error) = progress else {
            Issue.record("expected a failure, got \(progress)")
            return
        }
        #expect(error as? NetworkError == .preconditionFailed)
        #expect(server.file("/Photos/v.mov") == other)
        // The chunks of this name are of no use for another one.
        #expect(server.uploads.isEmpty)
    }

    @Test func aRefusedChunkEndsTheUploadAndRemovesItsChunks() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        server.fail("PUT", suffix: "/2", with: .status(507))
        let progress = await run(driver(), keeper: keeper)
        guard case .failed(let error) = progress else {
            Issue.record("expected a failure, got \(progress)")
            return
        }
        #expect(error as? NetworkError == .insufficientStorage)
        #expect(server.uploads.isEmpty)
        #expect(server.file("/Photos/v.mov") == nil)
        #expect(!FileManager.default.fileExists(atPath: files.chunks.path(percentEncoded: false)))
    }

    @Test func aTransientChunkFailureKeepsTheChunksForTheNextAttempt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        server.fail("PUT", suffix: "/3", times: ChunkedUpload.maxFailures, with: .error(.timedOut))
        let progress = await run(driver(), keeper: keeper)
        guard case .failed(let error) = progress else {
            Issue.record("expected a failure, got \(progress)")
            return
        }
        #expect(error as? NetworkError == .timedOut)
        #expect(server.uploads.values.first?.chunks.keys.sorted() == [1, 2, 4])
    }
}

extension ChunkedUploadDriverTests {
    /// An earlier launch recorded the end but could not act on it any more.
    @Test func anUploadThatEndedInAnEarlierLaunchIsSettled() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeFile(size: 35)
        let keeper = UploadKeeper()
        try await start(file, keeper: keeper)
        guard case .finished = await run(driver(), keeper: keeper) else {
            Issue.record("not finished")
            return
        }
        // The record still says "finished": the file is found at its destination.
        guard case .finished(let uploaded) = await keeper.advance(driver(), files: files) else {
            Issue.record("the file is at its destination")
            return
        }
        #expect(uploaded.path == "/Photos/v.mov")
        // One that failed is handed back to be started again, not as a failure of the file.
        var failed = try #require(await keeper.upload)
        failed.markFailed()
        await keeper.set(failed)
        guard case .failed(let error) = await keeper.advance(driver(), files: files) else {
            Issue.record("expected the upload to be given back")
            return
        }
        #expect(error as? NetworkError == .cancelled)
    }
}

@Suite struct ConflictPolicyTests {
    @Test func aConvertedCopyIsKnownByItsCaptureTime() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let policy = Uploader.ConflictPolicy.skipIfSameSizeOrTime(captured)
        #expect(policy.isSameFile(size: 10, existingSize: 10, existingModified: nil))
        #expect(policy.isSameFile(size: 10, existingSize: 12, existingModified: captured.addingTimeInterval(1)))
        #expect(!policy.isSameFile(size: 10, existingSize: 12, existingModified: captured.addingTimeInterval(5)))
        #expect(!Uploader.ConflictPolicy.skipIfSameSize.isSameFile(size: 10, existingSize: 12, existingModified: captured))
        #expect(!Uploader.ConflictPolicy.rename.isSameFile(size: 10, existingSize: 10, existingModified: captured))
    }
}
