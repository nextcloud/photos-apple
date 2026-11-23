// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosNetworking

@Suite struct RetryPolicyTests {
    @Test func waitsGrowAndEnd() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 3)
        #expect(policy.delay(afterAttempt: 1) == 1)
        #expect(policy.delay(afterAttempt: 2) == 2)
        #expect(policy.delay(afterAttempt: 3) == 3)  // capped
        #expect(policy.delay(afterAttempt: 4) == nil)
    }

    @Test func retryAfterIsWaitedForUnlessItIsTooLong() {
        let policy = RetryPolicy(maxRetryAfter: 60)
        #expect(policy.delay(afterAttempt: 1, retryAfter: 7) == 7)
        #expect(policy.delay(afterAttempt: 3, retryAfter: 2) == 4)  // never shorter than the backoff
        #expect(policy.delay(afterAttempt: 1, retryAfter: 120) == nil)
    }

    @Test func retryAfterHeaderInSecondsOrAsADate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RetryPolicy.retryAfter(HTTPResponse(status: 429, headers: ["retry-after": "12"])) == 12)
        let date = HTTPDate.format(now.addingTimeInterval(30))
        #expect(RetryPolicy.retryAfter(HTTPResponse(status: 503, headers: ["retry-after": date]), now: now) == 30)
        #expect(RetryPolicy.retryAfter(HTTPResponse(status: 503)) == nil)
        #expect(RetryPolicy.retryAfter(HTTPResponse(status: 503, headers: ["retry-after": "soon"])) == nil)
    }

    @Test func whatIsWorthAnotherAttempt() {
        for error: NetworkError in [
            .timedOut, .offline, .transport(code: -1004, message: ""), .maintenance, .rateLimited, .http(status: 502, message: nil),
        ] {
            #expect(RetryPolicy.isRetryable(error), "\(error)")
        }
        for error: NetworkError in [
            .cancelled, .unauthorized, .forbidden(message: nil), .notFound, .conflict, .insufficientStorage, .locked,
            .http(status: 501, message: nil), .http(status: 400, message: nil),
        ] {
            #expect(!RetryPolicy.isRetryable(error), "\(error)")
        }
        #expect(!RetryPolicy.isRetryable(status: 507))
        #expect(!RetryPolicy.isRetryable(status: 201))
    }
}

@Suite(.timeLimit(.minutes(1))) struct UploaderTests {
    let server = UploadStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "UploaderTests-\(UUID().uuidString)")

    /// A file with the bytes 0, 1, 2 …
    func makeFile(_ name: String = "a.jpg", size: Int) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try Data((0..<size).map { UInt8($0 % 251) }).write(to: file)
        return file
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    var chunkPuts: [String] { server.lines.filter { $0.hasPrefix("PUT /uploads/") }.map { String($0.split(separator: "/").last ?? "") } }

    // MARK: Retry

    @Test func aSmallFileIsSentAgainAfterATimeout() async throws {
        defer { cleanUp() }
        let file = try makeFile(size: 8)
        server.fail("PUT", with: .error(.timedOut))
        let uploaded = try await server.uploader.upload(file: file, fileName: "a.jpg", folder: "/Photos", capturedAt: nil)
        #expect(uploaded.path == "/Photos/a.jpg")
        #expect(uploaded.fileId > 0)
        #expect(server.file("/Photos/a.jpg") == (try Data(contentsOf: file)))
        #expect(server.lines.filter { $0 == "PUT /files/alice/Photos/a.jpg" }.count == 2)
        #expect(server.sleeps.values == [1])
    }

    @Test func serverErrorsAreRetriedWithGrowingWaitsAndThenReported() async throws {
        defer { cleanUp() }
        let file = try makeFile(size: 8)
        server.fail("PUT", times: 3, with: .status(500))
        _ = try await server.uploader.upload(file: file, fileName: "a.jpg", folder: "/Photos", capturedAt: nil)
        #expect(server.sleeps.values == [1, 2, 4])

        server.sleeps.clear()
        server.fail("PUT", times: 4, with: .status(502))
        await #expect(throws: NetworkError.http(status: 502, message: nil)) {
            _ = try await server.uploader.upload(file: file, fileName: "b.jpg", folder: "/Photos", capturedAt: nil)
        }
        #expect(server.lines.filter { $0 == "PUT /files/alice/Photos/b.jpg" }.count == 4)
        #expect(server.sleeps.values == [1, 2, 4])
    }

    @Test func tooManyRequestsWaitsAsLongAsTheServerSays() async throws {
        defer { cleanUp() }
        let file = try makeFile(size: 8)
        server.fail("PUT", with: .status(429, headers: ["Retry-After": "7"]))
        _ = try await server.uploader.upload(file: file, fileName: "a.jpg", folder: "/Photos", capturedAt: nil)
        #expect(server.sleeps.values == [7])

        // Maintenance mode asks for more patience than a request has: no further attempt.
        server.sleeps.clear()
        server.fail("PUT", with: .status(503, headers: ["Retry-After": "120"]))
        await #expect(throws: NetworkError.maintenance) {
            _ = try await server.uploader.upload(file: file, fileName: "b.jpg", folder: "/Photos", capturedAt: nil)
        }
        #expect(server.sleeps.values.isEmpty)
    }

    @Test func aRefusalIsNotRetried() async throws {
        defer { cleanUp() }
        let file = try makeFile(size: 8)
        server.fail("PUT", times: 10, with: .status(403))
        await #expect(throws: NetworkError.forbidden(message: nil)) {
            _ = try await server.uploader.upload(file: file, fileName: "a.jpg", folder: "/Photos", capturedAt: nil)
        }
        #expect(server.lines.filter { $0.hasPrefix("PUT") }.count == 1)
        #expect(server.sleeps.values.isEmpty)
    }

    @Test func withoutAPolicyNothingIsRepeated() async throws {
        defer { cleanUp() }
        let file = try makeFile(size: 8)
        server.fail("PUT", with: .error(.timedOut))
        var uploader = server.uploader
        uploader.retry = nil
        await #expect(throws: NetworkError.timedOut) {
            _ = try await uploader.upload(file: file, fileName: "a.jpg", folder: "/Photos", capturedAt: nil)
        }
        #expect(server.lines.filter { $0.hasPrefix("PUT") }.count == 1)
    }

    // MARK: Chunked uploads

    @Test func chunkedUploadArrivesComplete() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        let uploaded = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos/2026", capturedAt: nil)
        #expect(server.file("/Photos/2026/v.mov") == (try Data(contentsOf: file)))
        #expect(uploaded.fileId > 0)
        #expect(chunkPuts == ["1", "2", "3", "4"])
        #expect(server.uploads.isEmpty)
    }

    @Test func aChunkIsRetriedOnItsOwn() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("PUT", suffix: "/3", times: 2, with: .error(.networkConnectionLost))
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(chunkPuts == ["1", "2", "3", "3", "3", "4"])
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func anInterruptedChunkedUploadContinuesWithTheFirstMissingChunk() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        // Chunk 3 fails on every attempt of the first run.
        server.fail("PUT", suffix: "/3", times: 4, with: .error(.timedOut))
        await #expect(throws: NetworkError.timedOut) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        // The folder with the first two chunks is still there.
        #expect(server.uploads.count == 1)
        #expect(server.uploads.values.first?.chunks.keys.sorted() == [1, 2])
        #expect(!server.lines.contains { $0.hasPrefix("DELETE") })
        #expect(server.file("/Photos/v.mov") == nil)

        server.clearRequests()
        let progress = ValueLog()
        let uploaded = try await server.uploader.upload(
            file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil, progress: { progress.add($0) })
        #expect(chunkPuts == ["3", "4"])
        #expect(server.lines.filter { $0.hasPrefix("MKCOL /uploads/") }.count == 1)
        #expect(server.lines.filter { $0.hasPrefix("PROPFIND /uploads/") }.count == 1)
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
        #expect(uploaded.path == "/Photos/v.mov")
        #expect(server.uploads.isEmpty)
        // Progress starts where the first run stopped.
        #expect((progress.values.first ?? 0) > 0.5)
        #expect(progress.values.last == 1)
    }

    @Test func anIncompleteChunkAndEverythingAfterItIsSentAgain() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("MOVE", times: 4, with: .status(500))
        await #expect(throws: NetworkError.http(status: 500, message: nil)) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        // All four chunks are there; the second one arrived truncated.
        server.state.withLock { state in
            let name = state.uploads.keys.first!
            state.uploads[name]?.chunks[2] = Data([1, 2, 3])
        }
        server.clearRequests()
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(chunkPuts == ["2", "3", "4"])
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func aCompleteFolderOnlyNeedsTheMove() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 30)
        server.fail("MOVE", times: 4, with: .status(500))
        await #expect(throws: NetworkError.self) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        server.clearRequests()
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(chunkPuts.isEmpty)
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func aRefusedChunkRemovesTheUploadFolder() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("PUT", suffix: "/2", with: .status(403))
        await #expect(throws: NetworkError.forbidden(message: nil)) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        #expect(server.uploads.isEmpty)
        #expect(server.lines.contains { $0.hasPrefix("DELETE /uploads/alice/photos-") })
    }

    @Test func whichFailuresKeepTheUploadFolder() {
        for error: any Error in [
            NetworkError.timedOut, NetworkError.offline, NetworkError.http(status: 503, message: nil), NetworkError.maintenance,
            NetworkError.cancelled, NetworkError.unauthorized, NetworkError.locked, CancellationError(),
        ] {
            #expect(Uploader.keepsUploadFolder(after: error), "\(error)")
        }
        for error: any Error in [
            NetworkError.forbidden(message: nil), NetworkError.insufficientStorage, NetworkError.preconditionFailed,
            NetworkError.http(status: 400, message: nil), CocoaError(.fileReadNoSuchFile),
        ] {
            #expect(!Uploader.keepsUploadFolder(after: error), "\(error)")
        }
    }

    @Test func aLostAnswerToTheMoveIsNotAFailure() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        // The server assembles the file, the answer never arrives.
        server.fail("MOVE", afterHandling: true, with: .error(.timedOut))
        let uploaded = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(server.lines.filter { $0.hasPrefix("MOVE") }.count == 1)
        #expect(uploaded.fileId > 0)
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func aMoveThatReallyFailedIsSentAgain() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("MOVE", times: 2, with: .status(503))
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(server.lines.filter { $0.hasPrefix("MOVE") }.count == 3)
        #expect(server.sleeps.values == [1, 2])
    }

    @Test func anUploadFolderThatVanishedIsStartedAgainOnce() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("PUT", suffix: "/3", with: .status(404), sideEffect: { $0.uploads = [:] })
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(chunkPuts == ["1", "2", "3", "1", "2", "3", "4"])
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    @Test func theUploadFolderBelongsToFileAndDestination() throws {
        defer { cleanUp() }
        let key = Uploader.uploadKey(path: "/Photos/a.mov", size: 35, chunkSize: 10, fingerprint: "abc")
        #expect(key == Uploader.uploadKey(path: "/Photos/a.mov", size: 35, chunkSize: 10, fingerprint: "abc"))
        #expect(key != Uploader.uploadKey(path: "/Photos/b.mov", size: 35, chunkSize: 10, fingerprint: "abc"))
        #expect(key != Uploader.uploadKey(path: "/Photos/a.mov", size: 35, chunkSize: 20, fingerprint: "abc"))
        #expect(key != Uploader.uploadKey(path: "/Photos/a.mov", size: 35, chunkSize: 10, fingerprint: "abd"))
        #expect(key.count == 32)
        // More than 10 000 chunks are not allowed.
        var uploader = server.uploader
        uploader.chunkSize = 10
        #expect(uploader.effectiveChunkSize(for: 1_000_000) == 100)
        #expect(uploader.effectiveChunkSize(for: 50) == 10)
    }

    @Test func otherContentUnderTheSameNameDoesNotContinueTheOldUpload() async throws {
        defer { cleanUp() }
        let file = try makeFile("v.mov", size: 35)
        server.fail("PUT", suffix: "/3", times: 4, with: .error(.timedOut))
        await #expect(throws: NetworkError.timedOut) {
            _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        }
        try Data((0..<35).map { UInt8(200 - $0) }).write(to: file)
        server.clearRequests()
        _ = try await server.uploader.upload(file: file, fileName: "v.mov", folder: "/Photos", capturedAt: nil)
        #expect(chunkPuts == ["1", "2", "3", "4"])
        #expect(server.file("/Photos/v.mov") == (try Data(contentsOf: file)))
    }

    // MARK: Cleanup

    @Test func uploadFoldersThatWereNeverContinuedAreRemoved() async throws {
        defer { cleanUp() }
        let folders = MemoryUploadFolders()
        var uploader = server.uploader
        uploader.folders = folders
        // One interrupted upload, one that went through.
        server.fail("PUT", suffix: "/3", times: 4, with: .error(.timedOut))
        await #expect(throws: NetworkError.timedOut) {
            _ = try await uploader.upload(file: try makeFile("a.mov", size: 35), fileName: "a.mov", folder: "/Photos", capturedAt: nil)
        }
        _ = try await uploader.upload(file: try makeFile("b.mov", size: 35), fileName: "b.mov", folder: "/Photos", capturedAt: nil)
        let kept = try #require(server.uploads.keys.first)
        #expect(Array(folders.entries().keys) == [kept])
        #expect(kept.hasPrefix("photos-"))

        // Too young to go.
        #expect(await uploader.removeStaleUploads() == 0)
        #expect(server.uploads.count == 1)
        // A day later nobody has continued it.
        #expect(await uploader.removeStaleUploads(now: Date().addingTimeInterval(25 * 3600)) == 1)
        #expect(server.uploads.isEmpty)
        #expect(folders.entries().isEmpty)
    }

    @Test func aContinuedUploadIsNotStale() async throws {
        defer { cleanUp() }
        let folders = MemoryUploadFolders()
        var uploader = server.uploader
        uploader.folders = folders
        let file = try makeFile("a.mov", size: 35)
        server.fail("PUT", suffix: "/3", times: 4, with: .error(.timedOut))
        await #expect(throws: NetworkError.timedOut) {
            _ = try await uploader.upload(file: file, fileName: "a.mov", folder: "/Photos", capturedAt: nil)
        }
        _ = try await uploader.upload(file: file, fileName: "a.mov", folder: "/Photos", capturedAt: nil)
        #expect(folders.entries().isEmpty)
        #expect(server.file("/Photos/a.mov") != nil)
    }

    @Test func aRefusedUploadIsForgotten() async throws {
        defer { cleanUp() }
        let folders = MemoryUploadFolders()
        var uploader = server.uploader
        uploader.folders = folders
        server.fail("PUT", suffix: "/2", with: .status(403))
        await #expect(throws: NetworkError.self) {
            _ = try await uploader.upload(file: try makeFile("a.mov", size: 35), fileName: "a.mov", folder: "/Photos", capturedAt: nil)
        }
        #expect(folders.entries().isEmpty)
    }

    @Test func cleanupKeepsWhatItCouldNotRemoveAndForgetsWhatIsGone() async throws {
        let folders = MemoryUploadFolders()
        var uploader = server.uploader
        uploader.folders = folders
        let old = Date().addingTimeInterval(-30 * 3600)
        folders.touch("photos-gone", at: old)  // the server has expired it already
        folders.touch("photos-there", at: old)
        server.state.withLock { $0.uploads["photos-there"] = .init(chunks: [1: Data([1])]) }
        server.fail("DELETE", suffix: "/photos-there", with: .status(500))
        #expect(await uploader.removeStaleUploads() == 0)
        #expect(Array(folders.entries().keys) == ["photos-there"])
        #expect(server.lines.filter { $0.hasSuffix("/photos-there") }.count == 1)  // best effort, no retry
        #expect(await uploader.removeStaleUploads() == 1)
        #expect(folders.entries().isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct BackgroundUploadTests {
    final class Counter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theSystemsHandlerIsCalledOnceTheReportsAreDealtWith() async {
        let completion = BackgroundEventsCompletion()
        let calls = Counter()
        completion.set { calls.increment() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 0)
        completion.eventsHandled()
        #expect(await eventually { calls.value == 1 })
        // Never twice.
        completion.eventsHandled()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 1)
    }

    @Test func reportsDealtWithBeforeTheHandlerArrivedCount() async {
        let completion = BackgroundEventsCompletion()
        completion.eventsHandled()
        let calls = Counter()
        completion.set { calls.increment() }
        #expect(await eventually { calls.value == 1 })
        // That was used up: the next handler waits for the next reports.
        let later = Counter()
        completion.set { later.increment() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(later.value == 0)
        completion.eventsHandled()
        #expect(await eventually { later.value == 1 })
    }

    @Test func reportsFromLongAgoDoNotCount() async {
        let completion = BackgroundEventsCompletion(memory: 0.05)
        completion.eventsHandled()
        try? await Task.sleep(for: .milliseconds(120))
        let calls = Counter()
        completion.set { calls.increment() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 0)
    }

    @Test func theSystemIsNeverLeftWaiting() async {
        let completion = BackgroundEventsCompletion(limit: 0.05)
        let calls = Counter()
        completion.set { calls.increment() }
        #expect(await eventually { calls.value == 1 })
    }

    @Test func reportsCarryTheAnswerOrTheError() throws {
        let trust = SessionDelegate(trustStore: TrustStore(directory: nil), clientCredentials: nil)
        let url = URL(string: "https://cloud.example.com/remote.php/dav/files/alice/Photos/a.jpg")!
        let http = try #require(
            HTTPURLResponse(
                url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["OC-FileId": "00000123ocabc", "OC-ETag": "\"e1\""]))
        let done = BackgroundSessionDelegate.event(jobId: "1", response: http, body: Data(), error: nil, url: url, trust: trust)
        #expect(done.error == nil)
        #expect(done.response?.status == 201)
        #expect(done.response?.header("oc-fileid") == "00000123ocabc")

        let full = try #require(HTTPURLResponse(url: url, statusCode: 507, httpVersion: "HTTP/1.1", headerFields: [:]))
        let refused = BackgroundSessionDelegate.event(jobId: "2", response: full, body: Data("x".utf8), error: nil, url: url, trust: trust)
        #expect(refused.response?.status == 507)
        #expect(refused.response?.data == Data("x".utf8))

        let lost = BackgroundSessionDelegate.event(
            jobId: "3", response: nil, body: Data(), error: URLError(.networkConnectionLost), url: url, trust: trust)
        #expect(lost.error == .offline)
        #expect(lost.response == nil)
        let cancelled = BackgroundSessionDelegate.event(
            jobId: "4", response: http, body: Data(), error: URLError(.cancelled), url: url, trust: trust)
        #expect(cancelled.error == .cancelled)
        let nothing = BackgroundSessionDelegate.event(jobId: "5", response: nil, body: Data(), error: nil, url: url, trust: trust)
        #expect(nothing.error != nil)
    }

    @Test func aPreparedUploadIsTheSamePutTheAppWouldSend() async throws {
        let server = UploadStubServer()
        let directory = FileManager.default.temporaryDirectory.appending(path: "PrepareTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "a.jpg")
        try Data([1, 2, 3, 4]).write(to: file)
        let uploader = server.uploader
        let captured = Date(timeIntervalSince1970: 1_700_000_000)

        guard
            case .put(let path, let request) = try await uploader.prepare(
                file: file, fileName: "a.jpg", folder: "/Photos/2026", capturedAt: captured, conflict: .skipIfSameSize)
        else {
            Issue.record("nothing is there yet")
            return
        }
        #expect(path == "/Photos/2026/a.jpg")
        #expect(request.method == "PUT")
        #expect(request.url.path() == "/remote.php/dav/files/alice/Photos/2026/a.jpg")
        #expect(request.headers["Authorization"] == server.connection.authorizationHeader)
        #expect(request.headers["X-OC-MTime"] == "1700000000")
        #expect(request.headers["OC-Checksum"] == "SHA256:\(try Uploader.sha256(of: file))")
        #expect(request.headers["X-NC-WebDAV-Auto-Mkcol"] == "1")
        // The folder was created, nothing was uploaded.
        #expect(server.lines.contains("MKCOL /files/alice/Photos/2026"))
        #expect(!server.lines.contains { $0.hasPrefix("PUT") })

        // A name that is on its way counts as taken.
        guard
            case .put(let second, _) = try await uploader.prepare(
                file: file, fileName: "a.jpg", folder: "/Photos/2026", capturedAt: captured, conflict: .skipIfSameSize, reserved: [path])
        else {
            Issue.record("nothing is there yet")
            return
        }
        #expect(second == "/Photos/2026/a (2).jpg")

        // The answer to the PUT gives the file id; a refusal is thrown.
        let uploaded = try await uploader.finish(path: path, response: HTTPResponse(status: 201, headers: ["oc-fileid": "00000042ocstub"]))
        #expect(uploaded == UploadedFile(fileId: 42, path: path, etag: nil))
        await #expect(throws: NetworkError.insufficientStorage) {
            _ = try await uploader.finish(path: path, response: HTTPResponse(status: 507))
        }

        // Once the file is there, preparing it again finds it.
        server.state.withLock { state in
            state.files[path] = Data([1, 2, 3, 4])
            state.fileIds[path] = 42
        }
        guard
            case .existing(let existing) = try await uploader.prepare(
                file: file, fileName: "a.jpg", folder: "/Photos/2026", capturedAt: captured, conflict: .skipIfSameSize)
        else {
            Issue.record("the file is there")
            return
        }
        #expect(existing.fileId == 42)
        // Without the id in the answer it is asked for.
        #expect(try await uploader.finish(path: path, response: HTTPResponse(status: 201)).fileId == 42)
    }
}
