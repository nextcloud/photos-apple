// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// A server for share uploads that keeps files by path.
final class FakeShareRemote: ShareUploadRemote {
    struct State: Sendable {
        var files: [String: Int64] = [:]
        var nextId: Int64 = 100
        var albumAdds: [String] = []
        var prepared: [String: Int64] = [:]
        var deleted: [String] = []
    }

    let state = Mutex(State())

    func resolve(_ name: String, folder: String, size: Int64, conflict: Uploader.ConflictPolicy, reserved: Set<String>) -> (
        path: String, existing: UploadedFile?
    ) {
        state.withLock { state in
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = name
            var counter = 2
            while true {
                let path = "\(folder)/\(candidate)"
                if !reserved.contains(path) {
                    guard let existing = state.files[path] else {
                        state.prepared[path] = size
                        return (path, nil)
                    }
                    if conflict.isSameFile(size: size, existingSize: existing, existingModified: nil) {
                        return (path, UploadedFile(fileId: 1, path: path, etag: nil))
                    }
                }
                candidate = "\(base) (\(counter)).\(ext)"
                counter += 1
            }
        }
    }

    func prepare(file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>)
        async throws -> Uploader.Prepared
    {
        let size = Int64((try? Data(contentsOf: file).count) ?? 0)
        let (path, existing) = resolve(fileName, folder: folder, size: size, conflict: conflict, reserved: reserved)
        if let existing { return .existing(existing) }
        return .put(path: path, request: HTTPRequest(method: "PUT", url: URL(string: "https://share.test")!.appending(path: path)))
    }

    func prepareChunked(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>
    ) async throws -> Uploader.PreparedChunked {
        let size = Int64((try? Data(contentsOf: file).count) ?? 0)
        let (path, existing) = resolve(fileName, folder: folder, size: size, conflict: conflict, reserved: reserved)
        if let existing { return .existing(existing) }
        var upload = ChunkedUpload(
            id: UUID().uuidString, path: path, size: size, chunkSize: 100,
            folder: URL(string: "https://share.test/uploads/\(UUID().uuidString)")!,
            destination: URL(string: "https://share.test")!.appending(path: path), headers: [:])
        upload.folderReady()
        return .chunked(upload)
    }

    var chunkedServer: any ChunkedUploadServer { FakeShareChunks(remote: self) }

    func store(_ path: String) -> UploadedFile {
        state.withLock { state in
            state.nextId += 1
            state.files[path] = state.prepared.removeValue(forKey: path) ?? 0
            return UploadedFile(fileId: state.nextId, path: path, etag: nil)
        }
    }

    func finish(path: String, response: HTTPResponse) async throws -> UploadedFile {
        if let error = NetworkError.from(status: response.status, data: Data()) { throw error }
        return store(path)
    }

    func existingFile(at path: String, size: Int64) async throws -> UploadedFile? {
        state.withLock { $0.files[path] == size ? UploadedFile(fileId: 1, path: path, etag: nil) : nil }
    }

    func addToAlbum(_ album: Album, path: String) async throws {
        state.withLock { $0.albumAdds.append(path) }
    }
}

struct FakeShareChunks: ChunkedUploadServer {
    let remote: FakeShareRemote

    func openFolder(_ upload: inout ChunkedUpload) async throws { upload.folderReady() }

    func request(for step: ChunkedUpload.Step, of upload: ChunkedUpload) -> HTTPRequest {
        switch step {
        case .chunk(let number): HTTPRequest(method: "PUT", url: upload.folder.appending(path: String(number)))
        case .assemble: HTTPRequest(method: "MOVE", url: upload.folder.appending(path: ".file"))
        }
    }

    func finish(_ upload: ChunkedUpload, status: Int, headers: [String: String]) async throws -> UploadedFile {
        remote.store(upload.path)
    }

    func assembledFile(of upload: ChunkedUpload) async throws -> UploadedFile? {
        try await remote.existingFile(at: upload.path, size: upload.size)
    }

    func abandon(_ upload: ChunkedUpload, after error: (any Error)?) async {
        remote.state.withLock { $0.deleted.append(upload.path) }
    }
}

/// The system of the share tests: keeps what it was given until the test reports it.
final class ShareTransport: BackgroundUploading {
    struct Job: Sendable {
        var jobId: String
        var request: HTTPRequest
        var fileExisted: Bool
    }

    let identifier = "tests.share"
    let signals: AsyncStream<BackgroundUploadSignal>
    let continuation: AsyncStream<BackgroundUploadSignal>.Continuation
    let jobs = Mutex<[Job]>([])
    let active = Mutex<Set<String>>([])

    init() {
        (signals, continuation) = AsyncStream.makeStream(of: BackgroundUploadSignal.self)
    }

    func start(jobId: String, request: HTTPRequest, file: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        jobs.withLock { $0.append(Job(jobId: jobId, request: request, fileExisted: exists)) }
        active.withLock { _ = $0.insert(jobId) }
    }

    func activeJobIds() async -> Set<String> { active.withLock { $0 } }
    func cancel(jobIds: Set<String>) async { active.withLock { $0.subtract(jobIds) } }
    func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void) {}
    func eventsHandled() {}

    var pending: [Job] { jobs.withLock { jobs in active.withLock { active in jobs.filter { active.contains($0.jobId) } } } }

    /// Reports every request the system has, until there are none (each report may start new ones).
    func deliverAll(to batch: ShareUploadBatch, status: @Sendable (Job) -> Int = { _ in 201 }) async {
        for _ in 0..<100 {
            let jobs = pending
            if jobs.isEmpty { return }
            for job in jobs {
                active.withLock { _ = $0.remove(job.jobId) }
                await batch.handle(BackgroundUploadEvent(jobId: job.jobId, response: HTTPResponse(status: status(job))))
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ShareUploadTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ShareUploadTests-\(UUID().uuidString)")
    let remote = FakeShareRemote()
    let transport = ShareTransport()
    let album = Album(kind: .own, name: "Trip")

    var batchDirectory: URL { root.appending(path: "ShareUploads/share-upload.test") }

    func makeBatch(record: ShareUploadRecord? = nil) -> ShareUploadBatch {
        ShareUploadBatch(
            identifier: "share-upload.test", directory: batchDirectory,
            record: record ?? ShareUploadRecord(accountId: AccountID(rawValue: "a"), album: album), transport: transport, remote: remote,
            maxSingleSize: 100)
    }

    /// A shared file's temporary copy.
    func copy(_ name: String, size: Int) throws -> URL {
        let url = root.appending(path: "tmp/\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: size).write(to: url)
        return url
    }

    func items(_ files: URL...) -> [(file: URL, capturedAt: Date?, sameSizeIsThisFile: Bool)] {
        files.map { ($0, nil, false) }
    }

    @Test func smallAndLargeFilesGoThroughTheSystemAndIntoTheAlbum() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try copy("IMG_1.JPG", size: 10)
        let large = try copy("VID_2.MOV", size: 250)
        let batch = makeBatch()
        try await batch.add(items(small, large), folder: "/Photos")
        // The copies wait in the shared container now.
        #expect(!FileManager.default.fileExists(atPath: small.path(percentEncoded: false)))
        #expect(await batch.handOver() == nil)
        // One PUT, and the chunks of the large file (100 bytes each).
        #expect(transport.pending.map(\.request.method) == ["PUT", "PUT", "PUT", "PUT"])
        #expect(transport.pending.allSatisfy { $0.fileExisted })
        #expect(await batch.progress.fraction == 0)
        await transport.deliverAll(to: batch)
        let progress = await batch.progress
        #expect(progress.isThrough)
        #expect(progress.done == 2)
        #expect(remote.state.withLock { $0.files } == ["/Photos/IMG_1.JPG": 10, "/Photos/VID_2.MOV": 250])
        #expect(remote.state.withLock { $0.albumAdds.sorted() } == ["/Photos/IMG_1.JPG", "/Photos/VID_2.MOV"])
        // Nothing of the share is left.
        #expect(!FileManager.default.fileExists(atPath: batchDirectory.path(percentEncoded: false)))
    }

    /// The extension ends; the app takes the share over from what it recorded and finishes it.
    @Test func theAppFinishesWhatTheExtensionStarted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let large = try copy("VID_2.MOV", size: 950)
        let extensionBatch = makeBatch()
        try await extensionBatch.add(items(large), folder: "/Photos")
        await extensionBatch.handOver()
        #expect(transport.pending.count == 8)
        let started = transport.pending

        let record = try #require(ShareUploads.loadRecord(batchDirectory))
        let appBatch = makeBatch(record: record)
        for job in started {
            transport.active.withLock { _ = $0.remove(job.jobId) }
            await appBatch.handle(BackgroundUploadEvent(jobId: job.jobId, response: HTTPResponse(status: 201)))
        }
        // The app handed over the last two chunks.
        #expect(transport.pending.count == 2)
        await transport.deliverAll(to: appBatch)
        #expect(await appBatch.progress.done == 1)
        #expect(remote.state.withLock { $0.files["/Photos/VID_2.MOV"] } == 950)
        #expect(transport.jobs.withLock { $0.filter { $0.request.method == "PUT" }.count } == 10)
    }

    @Test func aNameTakenMeanwhileIsLookedUpAgainNothingIsOverwritten() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try copy("IMG_1.JPG", size: 10)
        let batch = makeBatch()
        try await batch.add(items(file), folder: "/Photos")
        await batch.handOver()
        // Another client puts a file there before the system's PUT.
        remote.state.withLock { $0.files["/Photos/IMG_1.JPG"] = 77 }
        await transport.deliverAll(to: batch) { job in job.request.url.lastPathComponent == "IMG_1.JPG" ? 412 : 201 }
        #expect(remote.state.withLock { $0.files } == ["/Photos/IMG_1.JPG": 77, "/Photos/IMG_1 (2).JPG": 10])
        #expect(await batch.progress.done == 1)
    }

    @Test func aFailureCanBeTriedAgainWithoutASecondCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try copy("IMG_1.JPG", size: 10)
        let batch = makeBatch()
        try await batch.add(items(file), folder: "/Photos")
        await batch.handOver()
        // The server stored the file, but the answer said it failed.
        let job = try #require(transport.pending.first)
        transport.active.withLock { _ = $0.remove(job.jobId) }
        remote.state.withLock { $0.files["/Photos/IMG_1.JPG"] = 5 }
        await batch.handle(BackgroundUploadEvent(jobId: job.jobId, response: HTTPResponse(status: 507)))
        let failed = await batch.progress
        #expect(failed.failed == 1)
        #expect(failed.isThrough)
        // The file waits for another attempt.
        #expect(FileManager.default.fileExists(atPath: batchDirectory.path(percentEncoded: false)))
        // The same name and size the second time: the first attempt arrived.
        remote.state.withLock { $0.files["/Photos/IMG_1.JPG"] = 10 }
        #expect(await batch.retryFailed() == nil)
        #expect(await batch.progress.done == 1)
        #expect(remote.state.withLock { $0.files.count } == 1)
    }

    @Test func requestsTheSystemLostAreHandedOverAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try copy("IMG_1.JPG", size: 10)
        let batch = makeBatch()
        try await batch.add(items(file), folder: "/Photos")
        await batch.handOver()
        transport.active.withLock { $0 = [] }
        await batch.checkLost()
        #expect(transport.pending.isEmpty)
        await batch.checkLost()
        #expect(transport.pending.count == 1)
        await transport.deliverAll(to: batch)
        #expect(await batch.progress.done == 1)
    }

    @MainActor @Test func theAppTakesOverOnlySharesWhoseExtensionHasEnded() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let account = makeAccount("alice", server: "https://share.test")
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let directory = ShareUploads.directory(sandbox.layout)
        let ended = "share-upload.\(UUID().uuidString)"
        let alive = "share-upload.\(UUID().uuidString)"
        for (identifier, until) in [(ended, Date().addingTimeInterval(-60)), (alive, Date().addingTimeInterval(60))] {
            try FileManager.default.createDirectory(at: directory.appending(path: identifier), withIntermediateDirectories: true)
            let record = ShareUploadRecord(accountId: account.id, album: nil, items: [], aliveUntil: until)
            try JSONEncoder().encode(record).write(to: directory.appending(path: "\(identifier)/batch.json"))
        }
        ShareUploads.resumeAbandoned(layout: sandbox.layout, keychain: sandbox.keychain)
        #expect(ShareUploads.isAttached(ended))
        #expect(!ShareUploads.isAttached(alive))
    }
}
