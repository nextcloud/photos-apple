// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import PhotosNetworking

/// Videos of 2 GB and more (SPEC §21.1, round 11 item 3): chunked upload v2 against a real server, interrupted the ways a
/// phone interrupts it (the app is killed, the network goes, the device restarts and the system forgets its transfers),
/// continued from the chunks the server kept, and checked byte for byte: the server's size above 2³¹, the SHA-256 the
/// app sent (`OC-Checksum`) and the SHA-256 of the file downloaded again.
///
/// Runs only when PHOTOS_IT_SERVER (with PHOTOS_IT_USER, PHOTOS_IT_PASSWORD) and PHOTOS_IT_LARGE=1 are set: it writes
/// a 2.1 GB file and sends it twice. Uses a folder of its own and removes it, and the upload folders it leaves.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil && ProcessInfo.processInfo.environment["PHOTOS_IT_LARGE"] == "1"),
    .serialized, .timeLimit(.minutes(30)))
struct LargeUploadIntegrationTests {
    let dav: DAVClient
    let folder = "/r11-backup-large-\(UUID().uuidString.prefix(8))"
    /// Above 2³¹ bytes, not a multiple of the chunk size.
    static let size: Int64 = 2_254_857_830

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        dav = DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
    }

    /// A file of `size` bytes whose every 1 MiB differs (a pseudo-random block, each MiB stamped with its number), written
    /// in 64 MiB pieces.
    static func makeFile(size: Int64, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "large-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var generator = SystemRandomNumberGenerator()
        let mebibyte = 1 << 20
        var block = Data((0..<(64 * mebibyte)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        var written: Int64 = 0
        var stamp: UInt64 = 0
        while written < size {
            let count = Int(min(Int64(block.count), size - written))
            block.withUnsafeMutableBytes { bytes in
                for offset in stride(from: 0, to: count, by: mebibyte) {
                    stamp += 1
                    withUnsafeBytes(of: stamp.bigEndian) {
                        bytes.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: 8)
                    }
                }
            }
            try handle.write(contentsOf: block.prefix(count))
            written += Int64(count)
        }
        return file
    }

    /// What the server has at `path`: its size and the checksum it stored (`oc:checksums`, whose `oc:checksum` children the
    /// app's PROPFIND parser does not read, so it is asked for with a plain request).
    func serverFile(_ path: String) async throws -> (size: Int64?, checksums: String?) {
        let resource = try await dav.propfind(dav.connection.filesURL(path), depth: 0, properties: [DAVProp.size, DAVProp.contentLength])
            .first
        var request = URLRequest(url: dav.connection.filesURL(path))
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let login = Data("\(dav.connection.loginName):\(dav.connection.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:checksums/></d:prop></d:propfind>"#
                .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        let checksum = body.range(of: #"<oc:checksum>[^<]*</oc:checksum>"#, options: .regularExpression).map { String(body[$0]) }
        return (resource?.int64(DAVProp.contentLength) ?? resource?.int64(DAVProp.size), checksum)
    }

    func verify(_ path: String, digest: String) async throws {
        let stored = try await serverFile(path)
        #expect(stored.size == Self.size)
        // The SHA-256 the app sent with the upload (`OC-Checksum`), stored by the server.
        #expect(stored.checksums?.lowercased().contains("sha256:\(digest)") == true, "checksum: \(stored.checksums ?? "none")")
        let (downloaded, _) = try await dav.download(dav.connection.filesURL(path))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(try Uploader.sha256(of: downloaded) == digest)
    }

    /// The app sends the chunks itself (the Mac, and iPhone files larger than the system takes). It is stopped after a
    /// third (the app is killed, or the connection is lost): the chunks stay on the server, and the next attempt sends only
    /// the rest.
    @Test func aLargeVideoSurvivesAnInterruptionAndArrivesIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LargeUploadIT-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.makeFile(size: Self.size, in: directory)
        let digest = try Uploader.sha256(of: file)
        var uploader = Uploader(dav: dav)
        uploader.folders = MemoryUploadFolders()
        let chunkSize = uploader.effectiveChunkSize(for: Self.size)
        let total = Int((Self.size + Int64(chunkSize) - 1) / Int64(chunkSize))
        let path = "\(folder)/large.mov"
        let uploadFolder = uploader.uploadFolder(path: path, size: Self.size, chunkSize: chunkSize, fingerprint: digest)
        do {
            let attempt = Mutex<Task<UploadedFile, any Error>?>(nil)
            let task = Task { [uploader, folder] in
                try await uploader.upload(
                    file: file, fileName: "large.mov", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    progress: { value in if value > 0.33 { attempt.withLock { $0?.cancel() } } })
            }
            attempt.withLock { $0 = task }
            await #expect(throws: (any Error).self) { _ = try await task.value }
            let left = try await uploader.existingChunks(in: uploadFolder)
            #expect(left.count >= total / 3 && left.count < total, "\(left.count) of \(total) chunks kept")
            // Nothing at the destination yet (PROPFIND: 404).
            #expect(await (try? serverFile(path)) == nil)

            let started = ContinuousClock.now
            let progress = Mutex<[Double]>([])
            let uploaded = try await uploader.upload(
                file: file, fileName: "large.mov", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                progress: { value in progress.withLock { $0.append(value) } })
            let elapsed = ContinuousClock.now - started
            #expect(uploaded.path == path)
            #expect(uploaded.fileId > 0)
            // Only the chunks that were missing were sent again.
            #expect(progress.withLock { $0.count } <= total - left.count + 3)
            print("large upload: \(total) chunks of \(chunkSize) bytes, \(left.count) kept, the rest in \(elapsed)")
            try await verify(path, digest: digest)
        } catch {
            try? await dav.delete(uploadFolder)
            try? await dav.delete(dav.connection.filesURL(folder))
            throw error
        }
        try await dav.delete(dav.connection.filesURL(folder))
    }

    /// The system sends the chunks (iPhone, iPad: a background session, SPEC §7.18.6). Midway the session is invalidated
    /// with its transfers, as when the app is killed and the device restarts: the transfers are gone, the journal is not.
    /// A new launch prepares the same upload (the same upload folder), finds the chunks the server has and hands over the
    /// rest to a new session.
    @Test func aLargeVideoSentByTheSystemContinuesAfterARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LargeBackgroundIT-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.makeFile(size: Self.size, in: directory)
        let digest = try Uploader.sha256(of: file)
        let uploader = Uploader(dav: dav)
        let files = ChunkedUploadDriver.Files(file: file, chunks: directory.appending(path: "chunks"))
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        var uploadFolder: URL?
        do {
            // First launch: a third of the chunks, then the session is gone.
            guard
                case .chunked(let first) = try await uploader.prepareChunked(
                    file: file, fileName: "large.mov", folder: folder, capturedAt: captured)
            else {
                Issue.record("the destination is free")
                return
            }
            uploadFolder = first.folder
            let total = first.chunkCount
            let session = BackgroundUploadSession(identifier: "tests.large.\(UUID().uuidString)", trustStore: TrustStore(directory: nil))
            let keeper = UploadKeeper()
            await keeper.set(first)
            let driver = ChunkedUploadDriver(transport: session, uploader: uploader, window: 4)
            var progress = await keeper.advance(driver, files: files)
            var reported = 0
            for await signal in session.signals {
                guard case .finished(let event) = signal else { continue }
                reported += 1
                if let next = await keeper.report(event, driver: driver, files: files) { progress = next }
                if reported >= total / 3 { break }
            }
            // The transfers go with the session, as after a restart.
            await session.cancel(jobIds: await session.activeJobIds())
            session.finishAndInvalidate()
            if case .finished = progress { Issue.record("finished before the restart") }

            // Next launch: the same upload is prepared again; the server's chunks are found and the rest is handed over.
            guard
                case .chunked(let second) = try await uploader.prepareChunked(
                    file: file, fileName: "large.mov", folder: folder, capturedAt: captured)
            else {
                Issue.record("the destination is still free")
                return
            }
            #expect(second.folder == first.folder)
            let kept = try await uploader.existingChunks(in: second.folder).filter { $0.value == second.range(of: $0.key).count }.count
            #expect(kept >= total / 4, "\(kept) of \(total) chunks kept")
            let restarted = BackgroundUploadSession(identifier: "tests.large.\(UUID().uuidString)", trustStore: TrustStore(directory: nil))
            defer { restarted.finishAndInvalidate() }
            await keeper.set(second)
            let resumed = ChunkedUploadDriver(transport: restarted, uploader: uploader, window: 4)
            progress = await keeper.advance(resumed, files: files)
            var sent = 0
            for await signal in restarted.signals {
                guard case .finished(let event) = signal else { continue }
                sent += 1
                if let next = await keeper.report(event, driver: resumed, files: files) { progress = next }
                if case .running = progress { continue }
                break
            }
            guard case .finished(let uploaded) = progress else {
                Issue.record("not finished: \(progress)")
                throw CancellationError()
            }
            // The chunks the server had were not sent again (the MOVE is one more request).
            #expect(sent <= total - kept + 1 + 4, "\(sent) requests after the restart for \(total - kept) missing chunks")
            print("large background upload: \(total) chunks, \(kept) kept over the restart, \(sent) requests after it")
            #expect(uploaded.path == "\(folder)/large.mov")
            try await verify(uploaded.path, digest: digest)
        } catch {
            if let uploadFolder { try? await dav.delete(uploadFolder) }
            try? await dav.delete(dav.connection.filesURL(folder))
            throw error
        }
        try await dav.delete(dav.connection.filesURL(folder))
    }
}
