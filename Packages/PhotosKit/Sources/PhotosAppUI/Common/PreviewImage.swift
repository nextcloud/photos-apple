// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Decoded BlurHash placeholders, cached.
enum BlurHashCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, ImageHolder> = {
        let cache = NSCache<NSString, ImageHolder>()
        cache.countLimit = 2000
        return cache
    }()

    final class ImageHolder: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func image(_ hash: String?) -> CGImage? {
        guard let hash, !hash.isEmpty else { return nil }
        if let cached = cache.object(forKey: hash as NSString) { return cached.image }
        guard let image = BlurHash.decode(hash, width: 24, height: 24) else { return nil }
        cache.setObject(ImageHolder(image), forKey: hash as NSString)
        return image
    }
}

/// A server preview with BlurHash placeholder (used for covers, viewer, lists).
public struct PreviewImage: View {
    let fileId: FileID
    let etag: String
    let bucket: Int
    var blurhash: String?
    var hasPreview: Bool = true
    var mimeType: String = "image/jpeg"
    var path: String?
    var contentMode: ContentMode = .fill
    @Environment(SessionModel.self) private var session
    @State private var image: CGImage?

    public init(
        fileId: FileID, etag: String, bucket: Int, blurhash: String? = nil, hasPreview: Bool = true, mimeType: String = "image/jpeg",
        path: String? = nil, contentMode: ContentMode = .fill
    ) {
        self.fileId = fileId
        self.etag = etag
        self.bucket = bucket
        self.blurhash = blurhash
        self.hasPreview = hasPreview
        self.mimeType = mimeType
        self.path = path
        self.contentMode = contentMode
    }

    public init(item: MediaItem, bucket: Int, contentMode: ContentMode = .fill) {
        self.init(
            fileId: item.fileId, etag: item.etag, bucket: bucket, blurhash: item.blurhash, hasPreview: item.hasPreview,
            mimeType: item.mimeType, path: item.path, contentMode: contentMode)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.secondary.opacity(0.12)
                if let shown = image ?? BlurHashCache.image(blurhash) {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
        }
        .task(id: "\(fileId)-\(etag)-\(bucket)") { await load() }
    }

    func load() async {
        guard let services = session.services else { return }
        if let cached = services.images.cache.bestMemoryImage(fileId: fileId, etag: etag, upTo: bucket) { image = cached }
        let request = ImagePipeline.Request(
            fileId: fileId, etag: etag, bucket: bucket, hasPreview: hasPreview, mimeType: mimeType,
            originalURL: path.map { services.connection.originalURL(path: $0) })
        if let loaded = await services.images.preview(request) { image = loaded }
    }
}
