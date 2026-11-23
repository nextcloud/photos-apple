// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking
import Synchronization
import Testing

@testable import PhotosMedia

/// A fake server holding one file; records the requests it gets.
final class FakeRangeServer: Sendable {
    let body: Data
    let honoursRanges: Bool
    let status: Int?
    let requests = Mutex<[[String: String]]>([])

    init(size: Int, honoursRanges: Bool = true, status: Int? = nil) {
        body = Data((0..<size).map { UInt8($0 % 251) })
        self.honoursRanges = honoursRanges
        self.status = status
    }

    var ranges: [String] { requests.withLock { $0.compactMap { $0["Range"] } } }

    func source(chunkSize: Int64) -> MediaByteSource {
        MediaByteSource(
            url: URL(string: "https://cloud.example/remote.php/direct/token")!, headers: ["User-Agent": "Tests"], chunkSize: chunkSize
        ) { [self] _, headers in
            requests.withLock { $0.append(headers) }
            if let status { return HTTPResponse(status: status) }
            guard honoursRanges, let range = headers["Range"], range.hasPrefix("bytes=") else {
                return HTTPResponse(status: 200, headers: ["content-type": "video/mp4"], data: body)
            }
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] < body.count else { return HTTPResponse(status: 416) }
            let upper = min(bounds[1], body.count - 1)
            return HTTPResponse(
                status: 206,
                headers: ["content-type": "video/mp4; charset=binary", "content-range": "bytes \(bounds[0])-\(upper)/\(body.count)"],
                data: body.subdata(in: bounds[0]..<(upper + 1)))
        }
    }
}

@Suite struct VideoStreamingTests {
    func collect(_ source: MediaByteSource, offset: Int64, length: Int64?) async throws -> (Data, [MediaByteSource.Info]) {
        var data = Data()
        var infos: [MediaByteSource.Info] = []
        try await source.read(offset: offset, length: length) {
            infos.append($0)
        } onData: {
            data.append($0)
        }
        return (data, infos)
    }

    @Test func rangeHeader() {
        #expect(MediaByteSource.rangeHeader(offset: 0, length: 2) == "bytes=0-1")
        #expect(MediaByteSource.rangeHeader(offset: 1000, length: 500) == "bytes=1000-1499")
    }

    @Test func contentRangeTotal() {
        #expect(MediaByteSource.totalLength(contentRange: "bytes 0-1/1100548") == 1_100_548)
        #expect(MediaByteSource.totalLength(contentRange: "bytes 0-1/*") == nil)
        #expect(MediaByteSource.totalLength(contentRange: nil) == nil)
    }

    /// The probe AVFoundation sends first: two bytes, and it wants to know length, type and range support.
    @Test func probeReportsContentInformation() async throws {
        let server = FakeRangeServer(size: 5000)
        let (data, infos) = try await collect(server.source(chunkSize: 1000), offset: 0, length: 2)
        #expect(data == server.body.prefix(2))
        #expect(infos == [MediaByteSource.Info(contentLength: 5000, mimeType: "video/mp4", supportsByteRanges: true)])
        #expect(server.ranges == ["bytes=0-1"])
    }

    @Test func rangeIsFetchedInChunks() async throws {
        let server = FakeRangeServer(size: 5000)
        let (data, infos) = try await collect(server.source(chunkSize: 1000), offset: 500, length: 2500)
        #expect(data == server.body.subdata(in: 500..<3000))
        #expect(infos.count == 1)
        #expect(server.ranges == ["bytes=500-1499", "bytes=1500-2499", "bytes=2500-2999"])
    }

    @Test func readsToTheEndOfTheResource() async throws {
        let server = FakeRangeServer(size: 2500)
        let (data, _) = try await collect(server.source(chunkSize: 1000), offset: 1000, length: nil)
        #expect(data == server.body.subdata(in: 1000..<2500))
        #expect(server.ranges == ["bytes=1000-1999", "bytes=2000-2499"])
    }

    @Test func requestBeyondTheEndStopsAtTheEnd() async throws {
        let server = FakeRangeServer(size: 1500)
        let (data, _) = try await collect(server.source(chunkSize: 1000), offset: 1000, length: 4000)
        #expect(data == server.body.subdata(in: 1000..<1500))
    }

    @Test func everyRequestCarriesTheConfiguredHeaders() async throws {
        let server = FakeRangeServer(size: 3000)
        _ = try await collect(server.source(chunkSize: 1000), offset: 0, length: nil)
        #expect(server.requests.withLock { $0.allSatisfy { $0["User-Agent"] == "Tests" } })
        #expect(server.requests.withLock { $0.count } == 3)
    }

    /// A server that ignores `Range` sends the whole file: it is sliced locally and downloaded only once.
    @Test func serverWithoutRangeSupport() async throws {
        let server = FakeRangeServer(size: 3000, honoursRanges: false)
        let source = server.source(chunkSize: 1000)
        let (probe, infos) = try await collect(source, offset: 0, length: 2)
        #expect(probe == server.body.prefix(2))
        #expect(infos == [MediaByteSource.Info(contentLength: 3000, mimeType: "video/mp4", supportsByteRanges: false)])
        let (data, _) = try await collect(source, offset: 100, length: 400)
        #expect(data == server.body.subdata(in: 100..<500))
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test func httpErrorsAreThrown() async {
        await #expect(throws: NetworkError.notFound) {
            _ = try await collect(FakeRangeServer(size: 10, status: 404).source(chunkSize: 1000), offset: 0, length: 2)
        }
        await #expect(throws: NetworkError.unauthorized) {
            _ = try await collect(FakeRangeServer(size: 10, status: 401).source(chunkSize: 1000), offset: 0, length: 2)
        }
    }

    /// Errors of the transport (untrusted certificate, client certificate required) reach the player unchanged.
    @Test func transportErrorsAreThrown() async {
        let source = MediaByteSource(url: URL(string: "https://cloud.example/v")!) { _, _ in
            throw NetworkError.untrustedCertificate(host: "cloud.example", certificate: nil)
        }
        await #expect(throws: NetworkError.untrustedCertificate(host: "cloud.example", certificate: nil)) {
            try await source.read(offset: 0, length: 2) { _ in }
        }
    }

    @Test func cancellationStopsFetching() async throws {
        let server = FakeRangeServer(size: 10_000)
        let source = server.source(chunkSize: 1000)
        let task = Task {
            try await source.read(offset: 0, length: nil) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test func assetURLUsesTheCustomSchemeAndKeepsTheExtension() {
        let url = StreamingAssetLoader.assetURL(fileName: "Holiday clip.MOV")
        #expect(url.scheme == StreamingAssetLoader.scheme)
        #expect(url.pathExtension == "mov")
        #expect(StreamingAssetLoader.assetURL(fileName: "no extension").pathExtension == "mp4")
    }

    @Test func contentTypeIsAUniformTypeIdentifier() {
        #expect(
            StreamingAssetLoader.contentType(serverMime: "application/octet-stream", libraryMime: "video/quicktime")
                == "com.apple.quicktime-movie")
        #expect(StreamingAssetLoader.contentType(serverMime: "video/mp4", libraryMime: nil) == "public.mpeg-4")
        #expect(StreamingAssetLoader.contentType(serverMime: nil, libraryMime: nil) == nil)
    }
}
