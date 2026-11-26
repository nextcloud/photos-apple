// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosModel
import PhotosNetworking
import Synchronization
import UniformTypeIdentifiers

#if !os(watchOS)
    import AVFoundation
#endif

/// Why a photo has no preview at all (SPEC §20.1): the server has none, and none was made on the device.
public enum NoPreviewReason: Sendable, Equatable {
    /// Neither the server nor the device could read the file: damaged, or a format neither reads.
    case unreadable
    /// The original is larger than the device downloads to make a preview (`DevicePreview.maxImageBytes`).
    case tooLarge(bytes: Int64)
    /// Low Data Mode: the original is not downloaded for a preview. Made when Low Data Mode is off again.
    case lowDataMode
}

/// Previews made on the device for files the server has none of (SPEC §20.1), as Apple's and Google's apps always show a
/// picture: a server without the Movie or HEIC preview provider (the default configuration) has none for videos and HEIC
/// photos, and no server makes one of a file above `preview_max_filesize_image`.
///
/// - Images: the original is downloaded once (at most `maxImageBytes`, into the originals cache) and decoded downscaled
///   with ImageIO.
/// - Videos: one frame, read through the app's authenticated HTTP client in byte ranges (`MediaByteSource`), at most
///   `maxVideoBytes` of the file, never the whole file.
/// - The picture is made once, at least `renderSize` large, and stored in the preview cache under the preview's own key
///   for every bucket up to that size: the grid, the viewer, covers and memories all find it there.
/// - Not in Low Data Mode (unless the original is on the device already).
enum DevicePreview {
    /// Larger originals are not downloaded for a preview (the server's own limit for images is 50 MB too).
    static let maxImageBytes: Int64 = 50 * 1024 * 1024
    /// At most this much of a video is read for its frame (a frame near the start needs a few hundred KB to a few MB).
    static let maxVideoBytes: Int64 = 16 * 1024 * 1024
    /// Range requests for a video's frame: small, so little is read past what the decoder needs.
    static let videoChunkBytes: Int64 = 256 * 1024
    /// A frame that has not come after this long is given up (a stalled server).
    static let videoTimeout: Duration = .seconds(30)
    /// The smallest size a preview is made at: one decode serves the grid, covers and the viewer's first picture.
    static let renderSize = 1024

    enum Outcome: Sendable {
        case image(CGImage)
        case noPreview(NoPreviewReason)
        /// Offline, cancelled, a server error: not a file without a preview, asked again as before.
        case failed
    }

    /// What is known about the original.
    struct Source: Sendable {
        var url: URL
        var mimeType: String
    }

    /// The size a preview of `bucket` is made at: at least `renderSize`.
    static func renderBucket(for bucket: Int) -> Int { max(bucket, renderSize) }

    /// The buckets a preview made at `size` is stored under: every standard bucket up to it, and the one asked for.
    static func storedBuckets(renderedAt size: Int, requested bucket: Int) -> [Int] {
        Array(Set(PhotosAPI.previewBuckets.filter { $0 <= size } + [bucket])).sorted()
    }

    /// Whether ImageIO reads this type at all; unknown types are tried.
    static func imageIOReads(mimeType: String) -> Bool {
        guard let type = UTType(mimeType: mimeType) else { return true }
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return readable.contains(type.identifier) || readable.contains { UTType($0)?.conforms(to: type) == true }
    }

    /// Makes the preview of `request` on the device and stores it (`store`).
    static func render(
        _ request: ImagePipeline.Request, source: Source?, originals: OriginalStore, dav: DAVClient, cache: PreviewCache,
        isConstrained: Bool, allowsVideo: Bool
    ) async -> Outcome {
        guard let source, let kind = MimeTypes.kind(of: source.mimeType) else { return .noPreview(.unreadable) }
        let size = renderBucket(for: request.bucket)
        let image: CGImage
        switch kind {
        case .image:
            guard imageIOReads(mimeType: source.mimeType) else { return .noPreview(.unreadable) }
            let file: URL
            if let cached = originals.cached(fileId: request.fileId, etag: request.etag, url: source.url) {
                file = cached
            } else if isConstrained {
                return .noPreview(.lowDataMode)
            } else {
                do {
                    file = try await originals.original(
                        fileId: request.fileId, etag: request.etag, url: source.url, maxBytes: maxImageBytes)
                } catch let error as OriginalTooLarge {
                    return .noPreview(.tooLarge(bytes: error.bytes))
                } catch NetworkError.notFound {
                    return .noPreview(.unreadable)
                } catch {
                    return .failed
                }
            }
            if Task.isCancelled { return .failed }
            guard let decoded = ImageDecoding.decode(url: file, maxPixelSize: size) else {
                return Task.isCancelled ? .failed : .noPreview(.unreadable)
            }
            image = decoded
        case .video:
            #if os(watchOS)
                return .noPreview(.unreadable)
            #else
                guard allowsVideo, !MimeTypes.unplayableVideos.contains(source.mimeType) else { return .noPreview(.unreadable) }
                if let cached = originals.cached(fileId: request.fileId, etag: request.etag, url: source.url) {
                    guard let frame = try? await videoFrame(AVURLAsset(url: cached), maxPixelSize: size) else {
                        return Task.isCancelled ? .failed : .noPreview(.unreadable)
                    }
                    image = frame
                } else {
                    if isConstrained { return .noPreview(.lowDataMode) }
                    switch await remoteVideoFrame(url: source.url, mimeType: source.mimeType, dav: dav, maxPixelSize: size) {
                    case .success(let frame): image = frame
                    case .failure(.unreadable): return Task.isCancelled ? .failed : .noPreview(.unreadable)
                    case .failure(.network): return .failed
                    }
                }
            #endif
        }
        guard !Task.isCancelled,
            let stored = store(
                image, fileId: request.fileId, etag: request.etag, bucket: request.bucket, maxPixelSize: request.maxPixelSize,
                renderedAt: size, in: cache)
        else { return .failed }
        return .image(stored)
    }

    /// Stores a picture made on the device under the preview's key at every bucket up to its size (each one downscaled
    /// from it), so that no other size makes it again. Returns the picture for the request (`bucket`, `maxPixelSize`).
    static func store(
        _ image: CGImage, fileId: FileID, etag: String, bucket: Int, maxPixelSize: Int?, renderedAt size: Int, in cache: PreviewCache
    ) -> CGImage? {
        guard let full = ImageDecoding.jpegData(image) else { return nil }
        var result: CGImage?
        for stored in storedBuckets(renderedAt: size, requested: bucket) {
            let data: Data? =
                stored >= max(image.width, image.height)
                ? full : ImageDecoding.decode(data: full, maxPixelSize: stored).flatMap { ImageDecoding.jpegData($0) }
            guard let data else { continue }
            let decoded = cache.store(
                data, fileId: fileId, etag: etag, bucket: stored, maxPixelSize: stored == bucket ? maxPixelSize : stored)
            if stored == bucket { result = decoded }
        }
        return result
    }

    #if !os(watchOS)
        enum VideoFailure: Error {
            /// The file could not be read as a video (or needed more than `maxVideoBytes`).
            case unreadable
            /// Offline, a server error, cancelled: try again later.
            case network
        }

        /// More than `maxVideoBytes` were read for one frame.
        struct ReadLimitReached: Error {}

        /// A frame of a remote video, read in byte ranges through the account's DAV client (its authentication, trusted
        /// certificates and client certificate), at most `byteLimit` bytes.
        static func remoteVideoFrame(
            url: URL, mimeType: String, dav: DAVClient, maxPixelSize: Int, byteLimit: Int64 = maxVideoBytes,
            chunkSize: Int64 = videoChunkBytes
        ) async -> Result<CGImage, VideoFailure> {
            let read = Mutex<Int64>(0)
            let networkError = Mutex(false)
            // Stops the frame's generation when the limit is reached: AVFoundation would otherwise try other ranges for a while.
            let stop = Mutex<(@Sendable () -> Void)?>(nil)
            let source = MediaByteSource(url: url, chunkSize: chunkSize) { url, headers in
                // Counted before the request: AVFoundation reads several ranges at once.
                let wanted = requestedLength(range: headers["Range"]) ?? chunkSize
                let allowed = read.withLock { total in
                    guard total + wanted <= byteLimit else { return false }
                    total += wanted
                    return true
                }
                guard allowed else {
                    stop.withLock { $0 }?()
                    throw ReadLimitReached()
                }
                do {
                    return try await dav.send("GET", url, headers: headers, timeout: 60)
                } catch NetworkError.notFound {
                    throw NetworkError.notFound
                } catch NetworkError.cancelled {
                    // AVFoundation cancels the reads it no longer needs.
                    throw NetworkError.cancelled
                } catch {
                    // Offline, a timeout, a server error: the frame is tried again later, the file is not "unreadable".
                    networkError.withLock { $0 = true }
                    throw error
                }
            }
            let loader = StreamingAssetLoader(source: source, mimeType: mimeType)
            let asset = loader.makeAsset(fileName: url.lastPathComponent)
            let frame = try? await videoFrame(asset, maxPixelSize: maxPixelSize) { cancel in stop.withLock { $0 = cancel } }
            withExtendedLifetime(loader) {}
            if let frame { return .success(frame) }
            return networkError.withLock { $0 } || Task.isCancelled ? .failure(.network) : .failure(.unreadable)
        }

        /// The bytes a `Range: bytes=<first>-<last>` header asks for.
        static func requestedLength(range: String?) -> Int64? {
            guard let range, range.hasPrefix("bytes=") else { return nil }
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int64($0) }
            guard bounds.count == 2, bounds[1] >= bounds[0] else { return nil }
            return bounds[1] - bounds[0] + 1
        }

        /// The frame a video is shown with: a second in (past a fade from black), or a third of a short clip; the nearest
        /// key frame up to two seconds later, so little has to be read and decoded.
        /// - Parameter onStart: receives a function that stops loading and generating at once (from any thread).
        static func videoFrame(
            _ asset: AVURLAsset, maxPixelSize: Int, timeout: Duration = videoTimeout,
            onStart: ((@escaping @Sendable () -> Void) -> Void)? = nil
        ) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let box = GeneratorBox(generator: generator, asset: asset)
            let (stopped, signal) = AsyncStream<Void>.makeStream()
            onStart?({ signal.finish() })
            defer { signal.finish() }
            return try await withThrowingTaskGroup(of: CGImage?.self) { group in
                group.addTask {
                    let duration = try await box.asset.load(.duration)
                    let seconds = duration.isNumeric ? min(1, duration.seconds / 3) : 0
                    return try await box.generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
                }
                // Stopped (the read limit) or too slow: AVFoundation would keep trying other ranges for a while.
                group.addTask {
                    for await _ in stopped {}
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                defer {
                    box.stop()
                    group.cancelAll()
                }
                guard let first = try await group.next(), let image = first else { throw CancellationError() }
                return image
            }
        }

        /// `AVAssetImageGenerator` and `AVURLAsset` are thread-safe for these calls (loading, generating and cancelling
        /// from any thread, as their documentation describes), but not marked `Sendable`; the box carries them into the
        /// tasks that use them.
        private struct GeneratorBox: @unchecked Sendable {
            let generator: AVAssetImageGenerator
            let asset: AVURLAsset

            func stop() {
                generator.cancelAllCGImageGeneration()
                asset.cancelLoading()
            }
        }
    #endif
}

/// The original is larger than the download was allowed to be (`OriginalStore.original(maxBytes:)`).
public struct OriginalTooLarge: Error, Equatable {
    public let bytes: Int64
}
