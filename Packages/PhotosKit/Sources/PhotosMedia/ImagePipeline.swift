// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosModel
import PhotosNetworking

/// Loads previews and originals with de-duplication of concurrent requests (SPEC §5.5).
public actor ImagePipeline {
    public let api: PhotosAPI
    public nonisolated let cache: PreviewCache
    public nonisolated let originals: OriginalStore
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "images")
    /// Public album token: previews go through `publicPreview`.
    private let publicToken: String?

    public init(api: PhotosAPI, cache: PreviewCache, originals: OriginalStore, publicToken: String? = nil) {
        self.api = api
        self.cache = cache
        self.originals = originals
        self.publicToken = publicToken
    }

    public struct Request: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var bucket: Int
        public var hasPreview: Bool
        public var mimeType: String
        /// DAV URL of the original, used when the server has no preview.
        public var originalURL: URL?

        public init(
            fileId: FileID, etag: String, bucket: Int, hasPreview: Bool = true, mimeType: String = "image/jpeg", originalURL: URL? = nil
        ) {
            self.fileId = fileId
            self.etag = etag
            self.bucket = bucket
            self.hasPreview = hasPreview
            self.mimeType = mimeType
            self.originalURL = originalURL
        }
    }

    /// Returns a preview from memory, disk or the server.
    public func preview(_ request: Request) async -> CGImage? {
        if let image = cache.memoryImage(fileId: request.fileId, etag: request.etag, bucket: request.bucket) { return image }
        let key = PreviewCache.key(fileId: request.fileId, etag: request.etag, bucket: request.bucket)
        if let task = inflight[key] { return await task.value }
        let task = Task<CGImage?, Never> { [api, cache, originals, publicToken, logger] in
            if let image = cache.diskImage(fileId: request.fileId, etag: request.etag, bucket: request.bucket) { return image }
            if Task.isCancelled { return nil }
            do {
                let data: Data
                if let publicToken {
                    data = try await api.dav.get(api.publicPreviewURL(fileId: request.fileId, size: request.bucket, token: publicToken))
                        .data
                } else {
                    data = try await api.preview(fileId: request.fileId, size: request.bucket, etag: request.etag)
                }
                if let image = cache.store(data, fileId: request.fileId, etag: request.etag, bucket: request.bucket) { return image }
            } catch NetworkError.notFound {
                // fall through to local thumbnail
            } catch {
                logger.debug("preview \(request.fileId) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            // No server preview (e.g. HEIC/RAW without a preview provider): thumbnail the original locally.
            guard MimeTypes.kind(of: request.mimeType) == .image, let url = request.originalURL,
                let file = try? await originals.original(fileId: request.fileId, etag: request.etag, url: url, maxBytes: 50 * 1024 * 1024),
                let image = ImageDecoding.decode(url: file, maxPixelSize: request.bucket)
            else { return nil }
            return cache.store(image, fileId: request.fileId, etag: request.etag, bucket: request.bucket)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        return image
    }

    /// Prefetches previews without waiting.
    public func prefetch(_ requests: [Request]) {
        for request in requests where !cache.hasDiskImage(fileId: request.fileId, etag: request.etag, bucket: request.bucket) {
            Task(priority: .utility) { _ = await self.preview(request) }
        }
    }
}

/// Downloads and caches original files (SPEC §5.5.2), separate LRU cap.
public actor OriginalStore {
    public let directory: URL
    let dav: DAVClient
    private var inflight: [String: Task<URL, any Error>] = [:]

    public init(directory: URL, dav: DAVClient) {
        self.directory = directory
        self.dav = dav
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func localURL(fileId: FileID, etag: String, ext: String) -> URL {
        directory.appending(path: "\(fileId)-\(etag).\(ext.isEmpty ? "bin" : ext)")
    }

    /// Cached local copy if present.
    public nonisolated func cached(fileId: FileID, etag: String, url: URL) -> URL? {
        let local = localURL(fileId: fileId, etag: etag, ext: url.pathExtension.lowercased())
        return FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) ? local : nil
    }

    /// Downloads the original (or returns the cached copy).
    public func original(fileId: FileID, etag: String, url: URL, maxBytes: Int64? = nil) async throws -> URL {
        if let cached = cached(fileId: fileId, etag: etag, url: url) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path(percentEncoded: false))
            return cached
        }
        let key = "\(fileId)-\(etag)"
        if let task = inflight[key] { return try await task.value }
        let target = localURL(fileId: fileId, etag: etag, ext: url.pathExtension.lowercased())
        let task = Task<URL, any Error> { [dav] in
            if let maxBytes {
                let head = try await dav.head(url)
                if let length = head.header("content-length").flatMap(Int64.init), length > maxBytes {
                    throw NetworkError.http(status: 413, message: "File too large to preview locally")
                }
            }
            let (file, _) = try await dav.download(url)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    public func trim(toBytes limit: Int64) {
        let manager = FileManager.default
        guard
            let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize
            else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? manager.removeItem(at: url)
            total -= size
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
