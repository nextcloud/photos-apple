// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI

/// A preview of a file from the account's image pipeline (memory, disk or server), with its BlurHash until it is there.
struct TVPreview: View {
    let fileId: FileID
    var item: MediaItem?
    var bucket = 1024
    var maxPixelSize: Int? = 720
    var contentMode = ContentMode.fill
    @Environment(SessionModel.self) private var session
    @State private var image: CGImage?
    @State private var loadedItem: MediaItem?

    init(fileId: FileID, bucket: Int = 1024, maxPixelSize: Int? = 720, contentMode: ContentMode = .fill) {
        self.fileId = fileId
        self.bucket = bucket
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
    }

    init(item: MediaItem, bucket: Int = 1024, maxPixelSize: Int? = 720, contentMode: ContentMode = .fill) {
        self.fileId = item.fileId
        self.item = item
        self.bucket = bucket
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Tiles show a grey card while loading; a photo shown whole (the viewer) has the black screen around it.
                if contentMode == .fill { Rectangle().fill(.quaternary) }
                if let shown = image ?? placeholder {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
        }
        .task(id: "\(fileId)-\(bucket)") { await load() }
    }

    var placeholder: CGImage? {
        guard let hash = (item ?? loadedItem)?.blurhash else { return nil }
        return BlurHash.decode(hash)
    }

    func load() async {
        guard let services = session.services else { return }
        var media = item
        if media == nil {
            media = try? services.collections.mediaItem(fileId: fileId)
            loadedItem = media
        }
        guard let media else { return }
        if let cached = services.images.cache.bestMemoryImage(fileId: media.fileId, etag: media.etag, upTo: bucket) { image = cached }
        let request = ImagePipeline.Request(
            fileId: media.fileId, etag: media.etag, bucket: bucket, hasPreview: media.hasPreview, mimeType: media.mimeType,
            originalURL: services.originalURL(for: media), maxPixelSize: maxPixelSize)
        if let loaded = await services.images.preview(request) { image = loaded }
    }
}

/// A memory as a large 16:9 card: cover, title and dates.
struct TVMemoryCard: View {
    let memory: Memory

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TVPreview(fileId: memory.cover, bucket: 1024, maxPixelSize: 1024)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                if let line = Memories.dateLine(for: memory) {
                    Text(line).font(.callout).foregroundStyle(.white.opacity(0.8))
                }
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(width: 640, height: 360)
        .accessibilityElement(children: .combine)
    }
}

/// An album as a poster: the cover lifts on focus, the title and count below it.
struct TVAlbumCard: View {
    let album: Album
    var size = CGSize(width: 400, height: 300)

    var body: some View {
        NavigationLink(value: TVDestination.album(album)) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let cover = album.displayCoverFileId {
                        TVPreview(fileId: cover, bucket: 1024, maxPixelSize: 720)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 12))
                .hoverEffect(.highlight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.callout).lineLimit(1)
                    Text("\(album.itemCount) items", comment: "TV: number of photos and videos under an album's title; plural variations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: size.width, alignment: .leading)
                .padding(.top, 16)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .combine)
    }
}

/// A photo or video tile in rows and grids; videos show their length.
struct TVPhotoTile: View {
    let item: MediaItem
    var size: CGSize

    var body: some View {
        TVPreview(item: item, bucket: 1024, maxPixelSize: Int(max(size.width, size.height)))
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        if let duration = item.duration {
                            Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                        }
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .padding(14)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(TVText.label(for: item))
    }
}

/// Spoken and shown descriptions of items.
enum TVText {
    static func label(for item: MediaItem) -> Text {
        let date = item.timestamp.formatted(date: .long, time: .omitted)
        switch (item.kind == .video, item.place) {
        case (true, let place?):
            return Text("Video, \(date), \(place)", comment: "TV: VoiceOver label of a video; placeholders: date, place.")
        case (true, nil):
            return Text("Video, \(date)", comment: "TV: VoiceOver label of a video; the placeholder is its date.")
        case (false, let place?):
            return Text("Photo, \(date), \(place)", comment: "TV: VoiceOver label of a photo; placeholders: date, place.")
        case (false, nil):
            return Text("Photo, \(date)", comment: "TV: VoiceOver label of a photo; the placeholder is its date.")
        }
    }
}
