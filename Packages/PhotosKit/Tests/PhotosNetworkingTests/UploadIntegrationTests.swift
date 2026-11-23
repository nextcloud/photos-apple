// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import PhotosNetworking

/// Against a real server. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set. Uploads into a
/// test folder of its own and removes it again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct UploadIntegrationTests {
    let dav: DAVClient
    let folder = "/Photos iOS upload test \(UUID().uuidString.prefix(8))"

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        dav = DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
    }

    func makeFile(size: Int) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-it-\(UUID().uuidString).bin")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: file)
        return file
    }

    @Test func aChunkedUploadThatWasInterruptedIsContinued() async throws {
        let file = try makeFile(size: 1_000_000)
        defer { try? FileManager.default.removeItem(at: file) }
        var uploader = Uploader(dav: dav)
        let folders = MemoryUploadFolders()
        uploader.folders = folders
        uploader.chunkThreshold = 200_000
        uploader.chunkSize = 200_000
        let digest = try Uploader.sha256(of: file)
        let path = "\(folder)/resume.bin"
        let uploadFolder = uploader.uploadFolder(path: path, size: 1_000_000, chunkSize: 200_000, fingerprint: digest)
        do {
            // First attempt: stopped after the second of five chunks.
            let attempt = Mutex<Task<UploadedFile, any Error>?>(nil)
            let reached = ValueLog()
            let task = Task { [uploader, folder] in
                try await uploader.upload(
                    file: file, fileName: "resume.bin", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    progress: { value in
                        reached.add(value)
                        if value > 0.35 { attempt.withLock { $0?.cancel() } }
                    })
            }
            attempt.withLock { $0 = task }
            await #expect(throws: (any Error).self) { _ = try await task.value }

            // The chunks sent so far are still on the server.
            let left = try await uploader.existingChunks(in: uploadFolder)
            #expect(left[1] == 200_000)
            #expect(left[2] == 200_000)
            #expect(left.count < 5)
            #expect(Array(folders.entries().keys) == [uploadFolder.lastPathComponent])
            #expect(await (try? dav.propfind(dav.connection.filesURL(path), depth: 0, properties: [DAVProp.size])) == nil)

            // Second attempt: continues, and the file arrives intact.
            let progress = ValueLog()
            let uploaded = try await uploader.upload(
                file: file, fileName: "resume.bin", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                progress: { progress.add($0) })
            #expect(uploaded.path == path)
            #expect(uploaded.fileId > 0)
            #expect((progress.values.first ?? 0) >= Double(left.count) * 0.2 * 0.98 - 0.001)
            #expect(progress.values.count == 5 - left.count + 2)  // the starting point, the remaining chunks, done
            let (downloaded, _) = try await dav.download(dav.connection.filesURL(path))
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Uploader.sha256(of: downloaded) == digest)
            // The upload folder is gone after the MOVE.
            await #expect(throws: NetworkError.notFound) { _ = try await uploader.existingChunks(in: uploadFolder) }
            #expect(folders.entries().isEmpty)

            // An upload nobody continues is removed by the cleanup.
            let other = try makeFile(size: 500_000)
            defer { try? FileManager.default.removeItem(at: other) }
            let stopped = Mutex<Task<UploadedFile, any Error>?>(nil)
            let second = Task { [uploader, folder] in
                try await uploader.upload(
                    file: other, fileName: "left.bin", folder: folder, capturedAt: nil,
                    progress: { _ in stopped.withLock { $0?.cancel() } })
            }
            stopped.withLock { $0 = second }
            await #expect(throws: (any Error).self) { _ = try await second.value }
            let name = try #require(folders.entries().keys.first)
            let leftFolder = dav.connection.davURL("uploads/\(dav.connection.userId)/\(name)/")
            #expect(try await uploader.existingChunks(in: leftFolder).count >= 1)
            #expect(await uploader.removeStaleUploads() == 0)
            #expect(await uploader.removeStaleUploads(now: Date().addingTimeInterval(25 * 3600)) == 1)
            await #expect(throws: NetworkError.notFound) { _ = try await uploader.existingChunks(in: leftFolder) }
        } catch {
            try? await dav.delete(uploadFolder)
            try? await dav.delete(dav.connection.filesURL(folder))
            throw error
        }
        try await dav.delete(dav.connection.filesURL(folder))
    }
}

/// The real background transfer session, against a real server. macOS runs background sessions too, so the session's
/// delegate handling is exercised here; what only iOS does (suspending the app, launching it for finished uploads) is not.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct BackgroundUploadIntegrationTests {
    let base = UploadIntegrationTests()

    @Test func theSystemUploadsAFileAndReportsTheServersAnswer() async throws {
        let dav = base.dav
        let folder = base.folder
        let session = BackgroundUploadSession(
            identifier: "com.nextcloud.photos.tests.\(UUID().uuidString)", trustStore: TrustStore(directory: nil))
        let file = try base.makeFile(size: 300_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = Uploader(dav: dav)
        do {
            guard
                case .put(let path, let request) = try await uploader.prepare(
                    file: file, fileName: "background.bin", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            else {
                Issue.record("the file cannot be there yet")
                return
            }
            try await session.start(jobId: "job-1", request: request, file: file)
            #expect(await session.activeJobIds() == ["job-1"])
            // A second one that the server refuses (404): the parent folder does not exist and may not be created.
            var refused = request
            refused.url = dav.connection.filesURL("\(folder)/missing/sub/background.bin")
            refused.headers["X-NC-WebDAV-Auto-Mkcol"] = nil
            try await session.start(jobId: "job-2", request: refused, file: file)

            var events: [String: BackgroundUploadEvent] = [:]
            for await signal in session.signals {
                if case .finished(let event) = signal { events[event.jobId] = event }
                if events.count == 2 { break }
            }
            let done = try #require(events["job-1"])
            #expect(done.error == nil)
            #expect(done.response?.status == 201)
            let uploaded = try await uploader.finish(path: path, response: try #require(done.response))
            #expect(uploaded.fileId > 0)
            #expect(uploaded.path == "\(folder)/background.bin")
            let (downloaded, _) = try await dav.download(dav.connection.filesURL(path))
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Uploader.sha256(of: downloaded) == (try Uploader.sha256(of: file)))

            let failed = try #require(events["job-2"])
            let response = try #require(failed.response)
            #expect(response.status == 404)
            await #expect(throws: NetworkError.notFound) { _ = try await uploader.finish(path: "x", response: response) }
            #expect(await session.activeJobIds().isEmpty)

            // A cancelled upload is reported as cancelled.
            try await session.start(jobId: "job-3", request: refused, file: file)
            await session.cancel(jobIds: ["job-3"])
            for await signal in session.signals {
                guard case .finished(let event) = signal else { continue }
                #expect(event.jobId == "job-3")
                #expect(event.error == .cancelled || event.response != nil)
                break
            }
        } catch {
            try? await dav.delete(dav.connection.filesURL(folder))
            throw error
        }
        try await dav.delete(dav.connection.filesURL(folder))
    }
}
