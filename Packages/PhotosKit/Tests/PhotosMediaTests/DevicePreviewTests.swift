// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import PhotosModel
import PhotosNetworking
import Synchronization
import Testing

@testable import PhotosMedia

/// A server without previews (every preview answers 404) that serves originals, with byte ranges, and counts what it sent.
final class OriginalStubServer: Sendable {
    struct File: Sendable {
        var data: Data
        var mimeType: String
        /// `Content-Length` a HEAD answers with (a large file without sending it).
        var advertisedLength: Int?
    }

    struct State: Sendable {
        var files: [String: File] = [:]
        var previewRequests = 0
        /// GET and HEAD requests of originals: "GET a.jpg", "HEAD a.jpg".
        var originalRequests: [String] = []
        var bytesSent: [String: Int] = [:]
    }

    let host = "originals-\(UUID().uuidString.lowercased()).invalid"
    let state = Mutex(State())

    init() {
        OriginalStubProtocol.servers.withLock { $0[host] = self }
    }

    deinit {
        let host = self.host
        OriginalStubProtocol.servers.withLock { $0[host] = nil }
    }

    var connection: ServerConnection {
        ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: "alice", loginName: "alice", appPassword: "secret", userAgent: "tests")
    }

    var api: PhotosAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginalStubProtocol.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        return PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    func add(_ name: String, data: Data, mimeType: String, advertisedLength: Int? = nil) -> URL {
        state.withLock { $0.files[name] = File(data: data, mimeType: mimeType, advertisedLength: advertisedLength) }
        return connection.filesURL("/Photos/\(name)")
    }

    var previewRequests: Int { state.withLock { $0.previewRequests } }
    var originalRequests: [String] { state.withLock { $0.originalRequests } }
    func bytesSent(_ name: String) -> Int { state.withLock { $0.bytesSent[name] ?? 0 } }

    /// The answer to a request: status, headers, body.
    func answer(_ request: URLRequest) -> (Int, [String: String], Data) {
        guard let url = request.url else { return (400, [:], Data()) }
        if url.path.contains("/preview/") {
            state.withLock { $0.previewRequests += 1 }
            return (404, ["Content-Type": "application/json"], Data("[]".utf8))
        }
        let name = url.lastPathComponent
        let method = request.httpMethod ?? "GET"
        guard
            let file = state.withLock({ state -> File? in
                state.originalRequests.append("\(method) \(name)")
                return state.files[name]
            })
        else { return (404, [:], Data()) }
        if method == "HEAD" {
            return (200, ["Content-Type": file.mimeType, "Content-Length": String(file.advertisedLength ?? file.data.count)], Data())
        }
        var body = file.data
        var status = 200
        var headers = ["Content-Type": file.mimeType, "Accept-Ranges": "bytes"]
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            let lower = bounds.first.flatMap { $0 } ?? 0
            let upper = min(file.data.count - 1, (bounds.count > 1 ? bounds[1] : nil) ?? file.data.count - 1)
            guard lower < file.data.count else { return (416, ["Content-Range": "bytes */\(file.data.count)"], Data()) }
            body = file.data.subdata(in: lower..<(upper + 1))
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(file.data.count)"
        }
        headers["Content-Length"] = String(body.count)
        let sent = body.count
        state.withLock { $0.bytesSent[name, default: 0] += sent }
        return (status, headers, body)
    }
}

final class OriginalStubProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: OriginalStubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasPrefix("originals-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, body) = server.answer(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum TestMedia {
    static func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageDecoding.jpegData(context.makeImage()!)!
    }

    /// The first 24 bytes of a JPEG and nothing else: the two files of the test library that have no preview (SPEC §20.1).
    static let truncatedJPEG = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF,
        0xDB, 0x00, 0x43,
    ])

    /// A QuickTime movie of noise (so it is large for its length: about 1 MB a second), its index at the end of the file
    /// as AVAssetWriter writes it unless asked otherwise, a key frame every second.
    static func video(seconds: Int = 6, width: Int = 640, height: Int = 360, fastStart: Bool = false) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "device-preview-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = fastStart
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoMaxKeyFrameIntervalKey: 30],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var seed: UInt32 = 12345
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CancellationError() }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetBytesPerRow(buffer) / 4 * height
            for index in 0..<count {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                base[index] = seed | 0xFF00_0000
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }
}

/// Previews made on the device when the server has none (SPEC §20.1).
@Suite(.timeLimit(.minutes(2))) struct DevicePreviewTests {
    let server = OriginalStubServer()
    let directory = FileManager.default.temporaryDirectory.appending(path: "device-preview-\(UUID().uuidString)")

    func pipeline(constrained: Bool = false) -> ImagePipeline {
        let api = server.api
        let pipeline = ImagePipeline(
            api: api, cache: PreviewCache(directory: directory.appending(path: "previews")),
            originals: OriginalStore(directory: directory.appending(path: "originals"), dav: api.dav))
        pipeline.setConstrainedProvider { constrained }
        return pipeline
    }

    func request(_ id: FileID, url: URL?, mimeType: String = "image/jpeg", bucket: Int = 256, hasPreview: Bool = true)
        -> ImagePipeline.Request
    {
        ImagePipeline.Request(fileId: id, etag: "e\(id)", bucket: bucket, hasPreview: hasPreview, mimeType: mimeType, originalURL: url)
    }

    @Test func aPreviewMadeOnceIsStoredForEverySizeUpToIt() {
        #expect(DevicePreview.storedBuckets(renderedAt: DevicePreview.renderBucket(for: 256), requested: 256) == [64, 256, 1024])
        #expect(DevicePreview.storedBuckets(renderedAt: DevicePreview.renderBucket(for: 4096), requested: 4096) == [64, 256, 1024, 4096])
        #expect(DevicePreview.storedBuckets(renderedAt: 1024, requested: 512) == [64, 256, 512, 1024])
    }

    @Test func anImageWithoutAServerPreviewIsDecodedFromItsOriginalOnceAndCachedForEverySize() async {
        let url = server.add("photo.heic", data: TestMedia.jpeg(width: 3000, height: 2000), mimeType: "image/heic")
        let pipeline = pipeline()
        let image = await pipeline.preview(request(1, url: url, mimeType: "image/heic"))
        #expect(image.map { max($0.width, $0.height) } == 256)
        #expect(!pipeline.hasNoPreview(fileId: 1, etag: "e1"))
        #expect(server.previewRequests == 1)
        #expect(server.originalRequests == ["HEAD photo.heic", "GET photo.heic"])
        // Every size up to 1024 is on disk, each no larger than its bucket.
        for bucket in [64, 256, 1024] {
            let stored = pipeline.cache.diskImage(fileId: 1, etag: "e1", bucket: bucket)
            #expect(stored.map { max($0.width, $0.height) } == bucket)
        }
        // A cover or the viewer (another size, no original URL) costs no request.
        pipeline.cache.clearMemory()
        #expect(await pipeline.preview(ImagePipeline.Request(fileId: 1, etag: "e1", bucket: 1024)) != nil)
        #expect(server.previewRequests == 1)
        #expect(server.originalRequests.count == 2)
    }

    @Test func aFileTheServerSaysHasNoPreviewGoesStraightToTheDevice() async {
        let url = server.add("photo.tiff", data: TestMedia.jpeg(width: 400, height: 300), mimeType: "image/tiff")
        let pipeline = pipeline()
        #expect(await pipeline.preview(request(2, url: url, mimeType: "image/tiff", hasPreview: false)) != nil)
        #expect(server.previewRequests == 0)
    }

    @Test func aRequestWithoutItsOriginalFindsItInTheLibrary() async {
        let url = server.add("cover.heic", data: TestMedia.jpeg(width: 800, height: 600), mimeType: "image/heic")
        let pipeline = pipeline()
        pipeline.setSourceProvider { fileId in fileId == 3 ? ("image/heic", url) : nil }
        #expect(await pipeline.preview(ImagePipeline.Request(fileId: 3, etag: "e3", bucket: 1024)) != nil)
        #expect(server.originalRequests == ["HEAD cover.heic", "GET cover.heic"])
    }

    @Test func aDamagedFileHasNoPreviewAndIsNotAskedForAgain() async {
        let url = server.add("evil.jpg", data: TestMedia.truncatedJPEG, mimeType: "image/jpeg")
        let pipeline = pipeline()
        #expect(await pipeline.preview(request(4, url: url)) == nil)
        #expect(pipeline.noPreviewReason(fileId: 4, etag: "e4") == .unreadable)
        #expect(await pipeline.preview(request(4, url: url, bucket: 1024)) == nil)
        #expect(server.previewRequests == 1)
        #expect(server.originalRequests == ["HEAD evil.jpg", "GET evil.jpg"])
    }

    @Test func anOriginalAboveTheLimitIsNotDownloadedAndSaysItsSize() async {
        let url = server.add("huge.heic", data: Data(), mimeType: "image/heic", advertisedLength: 80_000_000)
        let pipeline = pipeline()
        #expect(await pipeline.preview(request(5, url: url, mimeType: "image/heic")) == nil)
        #expect(pipeline.noPreviewReason(fileId: 5, etag: "e5") == .tooLarge(bytes: 80_000_000))
        #expect(server.originalRequests == ["HEAD huge.heic"])
    }

    @Test func lowDataModeDownloadsNothingAndTheFileIsTriedWhenItEnds() async {
        let url = server.add("later.heic", data: TestMedia.jpeg(width: 400, height: 300), mimeType: "image/heic")
        let constrained = Mutex(true)
        let pipeline = pipeline()
        pipeline.setConstrainedProvider { constrained.withLock { $0 } }
        #expect(await pipeline.preview(request(6, url: url, mimeType: "image/heic")) == nil)
        #expect(pipeline.noPreviewReason(fileId: 6, etag: "e6") == .lowDataMode)
        #expect(server.originalRequests.isEmpty)
        // Still in Low Data Mode: not asked again.
        #expect(await pipeline.preview(request(6, url: url, mimeType: "image/heic")) == nil)
        #expect(server.previewRequests == 1)
        // Low Data Mode is off: made at once, without waiting for a sync or the backoff.
        constrained.withLock { $0 = false }
        #expect(await pipeline.preview(request(6, url: url, mimeType: "image/heic")) != nil)
        #expect(!pipeline.hasNoPreview(fileId: 6, etag: "e6"))
    }

    @Test(arguments: [false, true]) func aVideoFrameIsReadInRangesWithoutTheWholeFile(fastStart: Bool) async throws {
        let movie = try await TestMedia.video(fastStart: fastStart)
        let url = server.add("clip.mov", data: movie, mimeType: "video/quicktime")
        let pipeline = pipeline()
        let image = await pipeline.preview(request(7, url: url, mimeType: "video/quicktime", hasPreview: false))
        #expect(image.map { max($0.width, $0.height) } == 256)
        #expect(server.previewRequests == 0)
        // Ranges only, and well under the file (its index and the frames up to the first second's key frame).
        #expect(server.originalRequests.allSatisfy { $0 == "GET clip.mov" })
        let sent = server.bytesSent("clip.mov")
        #expect(sent > 0 && sent < movie.count / 2, "read \(sent) of \(movie.count) bytes")
        #expect(pipeline.cache.hasDiskImage(fileId: 7, etag: "e7", bucket: 1024))
    }

    @Test func aVideoThatNeedsMoreThanTheLimitIsGivenUp() async throws {
        let movie = try await TestMedia.video(seconds: 3)
        let url = server.add("big.mov", data: movie, mimeType: "video/quicktime")
        let result = await DevicePreview.remoteVideoFrame(
            url: url, mimeType: "video/quicktime", dav: server.api.dav, maxPixelSize: 256, byteLimit: 64 * 1024, chunkSize: 32 * 1024)
        guard case .failure(.unreadable) = result else {
            Issue.record("expected unreadable, got \(result)")
            return
        }
        #expect(server.bytesSent("big.mov") <= 64 * 1024)
    }

    @Test func aVideoTheDeviceCannotPlayIsNotRead() async {
        let url = server.add("clip.webm", data: Data(repeating: 1, count: 100), mimeType: "video/webm")
        let pipeline = pipeline()
        #expect(await pipeline.preview(request(8, url: url, mimeType: "video/webm")) == nil)
        #expect(pipeline.noPreviewReason(fileId: 8, etag: "e8") == .unreadable)
        #expect(server.originalRequests.isEmpty)
    }
}
