// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import PhotosNetworking
import Synchronization
import UniformTypeIdentifiers

/// Reads byte ranges of a remote file through the app's own HTTP transport, in chunks.
///
/// `AVPlayer(url:)` uses the system's media stack, which knows nothing about certificates the user
/// trusted in the app or the client certificate of the account. Fetching the bytes with the app's
/// `HTTPClient` keeps video playback on the same trust and authentication path as everything else.
public final class MediaByteSource: Sendable {
    /// Performs one GET with the given headers (normally `HTTPClient.send`).
    public typealias Fetch = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> HTTPResponse

    public struct Info: Sendable, Equatable {
        /// Length of the whole resource, when the server told us.
        public var contentLength: Int64?
        public var mimeType: String?
        public var supportsByteRanges: Bool
    }

    public let url: URL
    public let headers: [String: String]
    /// Bytes requested per HTTP request.
    public let chunkSize: Int64
    let fetch: Fetch
    /// The complete body, kept when a server ignores `Range` and answers 200, so it is downloaded only once.
    private let wholeBody = Mutex<Data?>(nil)

    public init(url: URL, headers: [String: String] = [:], chunkSize: Int64 = 1 << 20, fetch: @escaping Fetch) {
        self.url = url
        self.headers = headers
        self.chunkSize = max(1, chunkSize)
        self.fetch = fetch
    }

    public convenience init(url: URL, headers: [String: String] = [:], http: HTTPClient) {
        self.init(url: url, headers: headers) { url, headers in
            try await http.send(HTTPRequest(url: url, headers: headers, timeout: 120))
        }
    }

    /// `Range` header value for `length` bytes starting at `offset`.
    public static func rangeHeader(offset: Int64, length: Int64) -> String {
        "bytes=\(offset)-\(offset + max(1, length) - 1)"
    }

    /// Total length from a `Content-Range` header (`bytes 0-1/12345`); `nil` when unknown (`*`) or malformed.
    public static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    static func mimeType(of response: HTTPResponse) -> String? {
        response.header("Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Reads `length` bytes from `offset` (to the end of the file when `length` is `nil`).
    ///
    /// - Parameters:
    ///   - onInfo: called once, before the first data, with what the server said about the resource.
    ///   - onData: called with consecutive pieces of the requested range.
    public func read(
        offset: Int64, length: Int64?, onInfo: (Info) -> Void = { _ in }, onData: (Data) -> Void
    ) async throws {
        var position = offset
        var end: Int64? = length.map { offset + $0 }
        var toldInfo = false
        if let body = wholeBody.withLock({ $0 }) {
            onInfo(Info(contentLength: Int64(body.count), mimeType: nil, supportsByteRanges: false))
            onData(Self.slice(body, from: offset, to: end))
            return
        }
        while end.map({ position < $0 }) ?? true {
            try Task.checkCancellation()
            let want = min(chunkSize, end.map { $0 - position } ?? chunkSize)
            var requestHeaders = headers
            requestHeaders["Range"] = Self.rangeHeader(offset: position, length: want)
            let response = try await fetch(url, requestHeaders)
            try Task.checkCancellation()
            switch response.status {
            case 206:
                let total = Self.totalLength(contentRange: response.header("Content-Range"))
                if !toldInfo {
                    onInfo(Info(contentLength: total, mimeType: Self.mimeType(of: response), supportsByteRanges: true))
                    toldInfo = true
                }
                // Never hand out more than was asked for, even if the server sends more.
                let data = response.data.prefix(Int(want))
                if data.isEmpty { return }
                onData(Data(data))
                position += Int64(data.count)
                if let total {
                    if position >= total { return }
                    end = min(end ?? total, total)
                }
            case 200:
                // The server ignored the range and sent everything.
                let body = response.data
                wholeBody.withLock { $0 = body }
                if !toldInfo {
                    onInfo(Info(contentLength: Int64(body.count), mimeType: Self.mimeType(of: response), supportsByteRanges: false))
                }
                onData(Self.slice(body, from: position, to: end))
                return
            case 416 where position > offset:
                return  // read past the end of a resource of unknown length
            default:
                throw Self.error(status: response.status)
            }
        }
    }

    static func error(status: Int) -> NetworkError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden(message: nil)
        case 404: .notFound
        case 503: .maintenance
        default: .http(status: status, message: nil)
        }
    }

    static func slice(_ body: Data, from: Int64, to: Int64?) -> Data {
        let count = Int64(body.count)
        let lower = min(max(0, from), count)
        let upper = min(max(lower, to ?? count), count)
        return body.subdata(in: Int(lower)..<Int(upper))
    }
}

/// Feeds an `AVURLAsset` from a `MediaByteSource`, so playback uses the app's HTTP transport.
///
/// Keep a strong reference for as long as the asset plays: `AVAssetResourceLoader` holds its delegate weakly.
public final class StreamingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    /// Custom scheme that makes AVFoundation ask the delegate instead of loading the URL itself.
    public static let scheme = "nc-photos-stream"

    let source: MediaByteSource
    /// MIME type known from the library, used when the server does not send a useful one.
    let mimeType: String?
    private let queue = DispatchQueue(label: "com.nextcloud.photos.video-stream")
    private let tasks = Mutex<[ObjectIdentifier: Task<Void, Never>]>([:])

    public init(source: MediaByteSource, mimeType: String? = nil) {
        self.source = source
        self.mimeType = mimeType
    }

    deinit {
        for task in tasks.withLock({ $0.values }) { task.cancel() }
    }

    /// The asset to play. `fileName` only supplies the path extension AVFoundation uses as a format hint.
    public func makeAsset(fileName: String) -> AVURLAsset {
        let asset = AVURLAsset(url: Self.assetURL(fileName: fileName))
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    static func assetURL(fileName: String) -> URL {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let safe = ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && !ext.isEmpty ? ext : "mp4"
        return URL(string: "\(scheme)://media/\(UUID().uuidString).\(safe)")!
    }

    /// Uniform type identifier AVFoundation expects as the content type.
    static func contentType(serverMime: String?, libraryMime: String?) -> String? {
        for mime in [libraryMime, serverMime] {
            guard let mime, mime != "application/octet-stream", let type = UTType(mimeType: mime) else { continue }
            return type.identifier
        }
        return nil
    }

    /// `AVAssetResourceLoadingRequest` is not `Sendable`, but AVFoundation documents that a request may be
    /// answered and finished from any thread; the box only carries it into the task that serves it.
    private struct RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let box = RequestBox(request: loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let source = self.source
        let mimeType = self.mimeType
        let task = Task { [weak self] in
            await Self.serve(box, source: source, mimeType: mimeType)
            self?.tasks.withLock { $0[key] = nil }
        }
        tasks.withLock { $0[key] = task }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.withLock { $0.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    private static func serve(_ box: RequestBox, source: MediaByteSource, mimeType: String?) async {
        let request = box.request
        let offset: Int64
        let length: Int64?
        if let data = request.dataRequest {
            offset = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
            let remaining = Int64(data.requestedLength) - (offset - data.requestedOffset)
            length = data.requestsAllDataToEndOfResource ? nil : max(0, remaining)
        } else {
            // Only the content information is wanted: two bytes are enough to learn it.
            offset = 0
            length = 2
        }
        do {
            try await source.read(offset: offset, length: length) { info in
                guard let wanted = request.contentInformationRequest else { return }
                wanted.contentType = contentType(serverMime: info.mimeType, libraryMime: mimeType)
                if let total = info.contentLength { wanted.contentLength = total }
                wanted.isByteRangeAccessSupported = info.supportsByteRanges
            } onData: { data in
                request.dataRequest?.respond(with: data)
            }
            if !request.isCancelled && !request.isFinished { request.finishLoading() }
        } catch {
            if !request.isCancelled && !request.isFinished { request.finishLoading(with: error) }
        }
    }
}
