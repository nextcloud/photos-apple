// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosNetworking

/// A chunked upload sent by a real background `URLSession` to a real server: chunk PUTs from files, the MOVE with an empty
/// body. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set; uses a folder of its own and
/// removes it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil), .timeLimit(.minutes(3)))
struct BackgroundChunkedIntegrationTests {
    let dav: DAVClient
    let folder = "/r4-backup-chunked-\(UUID().uuidString.prefix(8))"
    let directory = FileManager.default.temporaryDirectory.appending(path: "BackgroundChunkedIT-\(UUID().uuidString)")

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        dav = DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
    }

    @Test func aLargeFileArrivesThroughABackgroundSession() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "large.bin")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<2_600_000).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: file)
        var uploader = Uploader(dav: dav)
        uploader.chunkSize = 1_000_000
        do {
            guard
                case .chunked(let upload) = try await uploader.prepareChunked(
                    file: file, fileName: "large.bin", folder: folder, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            else {
                Issue.record("the destination is free")
                return
            }
            let session = BackgroundUploadSession(identifier: "tests.chunked.\(UUID().uuidString)", trustStore: TrustStore(directory: nil))
            defer { session.finishAndInvalidate() }
            let keeper = UploadKeeper()
            await keeper.set(upload)
            let driver = ChunkedUploadDriver(transport: session, uploader: uploader, window: 2)
            let files = ChunkedUploadDriver.Files(file: file, chunks: directory.appending(path: "chunks"))
            var progress = await keeper.advance(driver, files: files)
            for await signal in session.signals {
                guard case .finished(let event) = signal else { continue }
                if let next = await keeper.report(event, driver: driver, files: files) { progress = next }
                if case .running = progress { continue }
                break
            }
            guard case .finished(let uploaded) = progress else {
                Issue.record("not finished: \(progress)")
                try? await dav.delete(dav.connection.filesURL(folder))
                return
            }
            #expect(uploaded.path == "\(folder)/large.bin")
            #expect(uploaded.fileId > 0)
            let (downloaded, _) = try await dav.download(dav.connection.filesURL(uploaded.path))
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Uploader.sha256(of: downloaded) == (try Uploader.sha256(of: file)))
            // The capture time went with the MOVE.
            let resource = try await dav.propfind(dav.connection.filesURL(uploaded.path), depth: 0, properties: [DAVProp.lastModified]).first
            #expect(resource?.httpDate(DAVProp.lastModified)?.timeIntervalSince1970 == 1_700_000_000)
            #expect(!FileManager.default.fileExists(atPath: files.chunks.path(percentEncoded: false)))
        } catch {
            try? await dav.delete(dav.connection.filesURL(folder))
            throw error
        }
        try await dav.delete(dav.connection.filesURL(folder))
    }
}
