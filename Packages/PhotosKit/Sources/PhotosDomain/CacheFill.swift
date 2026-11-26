// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

// Filling the preview cache before it is needed (SPEC §18.3): thumbnails of the whole library, and the first screens the
// app shows when it opens. Only the decisions live here (sizes, estimates, pacing, order); the downloads are in PhotosCore.

/// Thumbnails of the whole library (SPEC §18.3.1): the 256 px preview of every photo (the grid's tiles at the smaller zoom
/// steps, and the placeholder of larger ones) and the 64 px one (Years and Months).
public enum LibraryThumbnailPlan {
    /// The buckets kept for every photo, the one downloaded first. The 64 px one is made on the device from the 256 px one.
    public static let buckets = [256, 64]

    /// What a server preview takes on average before this device has measured its own (Nextcloud 33, the 448 JPEG photos
    /// of the test library: 256 px 11 163 bytes, 64 px 1 538 bytes; 64 px made on the device from the 256 px one with
    /// `ImageDecoding.jpegData` (quality 0.8): 2 430 bytes).
    public static let typicalBytes: [Int: Int64] = [256: 11_200, 64: 2_450]

    /// The space the thumbnails of `photos` photos take, from measured averages per bucket where there are some.
    public static func estimatedBytes(photos: Int, averages: [Int: Int64] = [:]) -> Int64 {
        guard photos > 0 else { return 0 }
        let perPhoto = buckets.reduce(Int64(0)) { sum, bucket in
            sum + (averages[bucket].flatMap { $0 > 0 ? $0 : nil } ?? typicalBytes[bucket] ?? 0)
        }
        return Int64(photos) * perPhoto
    }

    /// The setting's default: on where a library's thumbnails are small next to the disk (the Mac), off on iPhone, iPad
    /// and Apple Vision Pro, where the Settings row shows the estimate before it is turned on (SPEC §18.3.1).
    public static var defaultEnabled: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }
}

/// What a filler needs to know before it downloads the next preview.
public struct FillConditions: Sendable, Equatable {
    public var isConnected: Bool
    /// Cellular or a personal hotspot.
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    public var isLowPowerMode: Bool
    /// The user allowed downloads on cellular.
    public var allowsExpensive: Bool
    /// Nothing the app shows waits for a preview from the server, and no prefetch of the grid is queued.
    public var pipelineIdle: Bool
    /// How long the pipeline has been idle.
    public var idleFor: TimeInterval

    public init(
        isConnected: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false, isLowPowerMode: Bool = false,
        allowsExpensive: Bool = false, pipelineIdle: Bool = true, idleFor: TimeInterval = .infinity
    ) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isLowPowerMode = isLowPowerMode
        self.allowsExpensive = allowsExpensive
        self.pipelineIdle = pipelineIdle
        self.idleFor = idleFor
    }
}

/// How a background filler is paced so that it never slows what is on screen (SPEC §18.3.1).
public enum FillPacing {
    public enum Decision: Sendable, Equatable {
        /// Download the next preview.
        case go
        /// Ask again after this many seconds.
        case wait(TimeInterval)
        /// Stop the pass: the conditions will not change soon (no network, cellular, Low Power Mode). It goes on later.
        case stop
    }

    /// The pipeline must have been idle this long: scrolling makes short pauses between its loads, which are not a gap
    /// to fill.
    public static let quietPeriod: TimeInterval = 1.5
    /// How often a waiting filler looks again while the pipeline is busy.
    public static let busyRecheck: TimeInterval = 0.5

    public static func decide(_ conditions: FillConditions, quietPeriod: TimeInterval = quietPeriod) -> Decision {
        guard conditions.isConnected, !conditions.isConstrained, !conditions.isLowPowerMode else { return .stop }
        if conditions.isExpensive && !conditions.allowsExpensive { return .stop }
        guard conditions.pipelineIdle else { return .wait(busyRecheck) }
        if conditions.idleFor < quietPeriod { return .wait(max(0.05, quietPeriod - conditions.idleFor)) }
        return .go
    }
}

/// What the app prepares before it is opened (SPEC §18.3.2, §5.5.1): the first screens of the timeline, today's memories
/// and the albums opened recently, at the sizes their views ask for.
public enum PreparationPlan {
    /// The grid's tiles the timeline shows at its zoom step, as `AccountServices.previewRequest` sizes them.
    public struct Tiles: Sendable, Equatable {
        /// Side of a tile in points.
        public var side: Double
        /// Backing scale the grid sizes previews for (capped at 2 like the grid's).
        public var scale: Double
        /// The tiles crop to a square (the timeline's default).
        public var square: Bool
        /// Tiles on one screen.
        public var perScreen: Int

        public init(side: Double, scale: Double, square: Bool, perScreen: Int) {
            self.side = side
            self.scale = scale
            self.square = square
            self.perScreen = perScreen
        }

        /// The bucket a tile of a photo with this aspect ratio requests.
        public func bucket(aspectRatio: Double) -> Int {
            PreviewSizing.bucket(
                forPixels: PreviewSizing.neededPixels(tileSide: side, scale: scale, aspectRatio: square ? aspectRatio : 1))
        }
    }

    /// A photo the plan may ask for.
    public struct Photo: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var aspectRatio: Double

        public init(fileId: FileID, etag: String, aspectRatio: Double = 1) {
            self.fileId = fileId
            self.etag = etag
            self.aspectRatio = aspectRatio
        }
    }

    /// A memory or an album: its cover and its first photos.
    public struct Collection: Sendable, Hashable {
        public var cover: Photo?
        public var photos: [Photo]

        public init(cover: Photo?, photos: [Photo]) {
            self.cover = cover
            self.photos = photos
        }
    }

    /// One preview to have on the disk.
    public struct Entry: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        public var bucket: Int

        public init(fileId: FileID, etag: String, bucket: Int) {
            self.fileId = fileId
            self.etag = etag
            self.bucket = bucket
        }
    }

    /// Screens of the timeline prepared.
    public static let timelineScreens = 2
    /// Memories of today prepared, and photos of each after its cover (the first story pages).
    public static let memories = 3
    public static let memoryPhotos = 4
    /// Albums opened recently that are prepared, and how recently.
    public static let albums = 3
    public static let albumWindow: TimeInterval = 14 * 86_400
    /// Memory covers, story pages and album covers are shown at 1024 px (`MemoriesStrip`, `MemoryStories`, `AlbumCover`
    /// on a 2× screen).
    public static let coverBucket = 1024
    /// At most this many previews per preparation: about 15 MB at the sizes above.
    public static let limit = 300

    /// What to prepare, most important first: what is on the first screen of the timeline and of the memories strip,
    /// then the album covers, the timeline's next screen, the memories' first pages and the albums' first screens.
    public static func entries(
        timeline: [Photo], memories: [Collection], albums: [Collection], tiles: Tiles, limit: Int = limit
    ) -> [Entry] {
        var result: [Entry] = []
        var seen = Set<Entry>()
        func add(_ photo: Photo?, bucket: Int) {
            guard let photo, result.count < limit else { return }
            let entry = Entry(fileId: photo.fileId, etag: photo.etag, bucket: bucket)
            if seen.insert(entry).inserted { result.append(entry) }
        }
        func tile(_ photo: Photo) { add(photo, bucket: tiles.bucket(aspectRatio: photo.aspectRatio)) }

        let screen = max(1, tiles.perScreen)
        let memories = Array(memories.prefix(Self.memories))
        let albums = Array(albums.prefix(Self.albums))
        timeline.prefix(screen).forEach(tile)
        for memory in memories { add(memory.cover ?? memory.photos.first, bucket: coverBucket) }
        for album in albums { add(album.cover ?? album.photos.first, bucket: coverBucket) }
        timeline.dropFirst(screen).prefix(screen * (timelineScreens - 1)).forEach(tile)
        for memory in memories {
            memory.photos.prefix(memoryPhotos).forEach { add($0, bucket: coverBucket) }
        }
        for album in albums { album.photos.prefix(screen).forEach(tile) }
        return result
    }
}
