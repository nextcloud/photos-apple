// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosNetworking

/// ETags come from the server; no ETag may move a cache file out of its directory.
@Suite struct CachePathTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "photos-cache-path-\(UUID().uuidString)")
    static let hostile = ["../../../../tmp/evil", "a/../../b", "..", "x/y"]

    func isInside(_ url: URL, _ directory: URL, depth: Int) -> Bool {
        let base = directory.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.count == base.count + depth && Array(path.prefix(base.count)) == base
    }

    @Test func previewCacheFiles() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PreviewCache(directory: directory)
        // Unchanged for ordinary ETags: previews cached before stay valid.
        #expect(PreviewCache.key(fileId: 1234, etag: "5f3a9c2b7d1e4", bucket: 256) == "1234-5f3a9c2b7d1e4-256")
        #expect(PreviewCache.key(fileId: 1234, etag: "", bucket: 256) == "1234-0-256")
        for etag in Self.hostile {
            let url = cache.fileURL(key: PreviewCache.key(fileId: 1234, etag: etag, bucket: 256))
            #expect(isInside(url, directory, depth: 2), "\(etag): \(url.path)")
            #expect(url.deletingLastPathComponent().lastPathComponent == "34")
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        cache.store(jpeg, fileId: 7, etag: "../../escaped", bucket: 64)
        #expect(cache.hasDiskImage(fileId: 7, etag: "../../escaped", bucket: 64))
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appending(path: "escaped-64.jpg").path))
    }

    @Test func originalFiles() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ServerConnection(
            serverURL: URL(string: "http://localhost")!, userId: "a", loginName: "a", appPassword: "s", userAgent: "tests")
        let store = OriginalStore(
            directory: directory, dav: DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection))
        #expect(store.localURL(fileId: 5, etag: "abc123", ext: "jpg").lastPathComponent == "5-abc123.jpg")
        for etag in Self.hostile {
            #expect(isInside(store.localURL(fileId: 5, etag: etag, ext: "jpg"), directory, depth: 1), "\(etag)")
        }
    }
}
