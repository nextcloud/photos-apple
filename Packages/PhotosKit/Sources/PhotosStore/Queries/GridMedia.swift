// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// Lightweight row for grids (keeps 100k items cheap in memory).
public struct GridMedia: Hashable, Sendable, Identifiable, FetchableRecord, CopyStackCandidate {
    public var id: FileID { fileId }
    public var fileId: FileID
    public var timestamp: Date
    public var kind: MediaKind
    public var etag: String
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    public var hasPreview: Bool
    public var blurhash: String?
    public var duration: Double?
    public var aspectRatio: Double
    public var name: String
    public var directory: String
    public var mimeType: String
    public var isArchived: Bool
    /// The copies of one shot this tile stands for, the one it shows first (`CopyStacks`); empty when it is not a stack.
    /// Set by the screen that stacks its grid, never by the store.
    public var stack: [FileID] = []

    public init(row: Row) throws {
        fileId = row["fileId"]
        timestamp = Date(timeIntervalSince1970: row["timestamp"] ?? 0)
        kind = MediaKind(rawValue: row["kind"]) ?? .image
        etag = row["etag"]
        isFavorite = row["isFavorite"]
        isLivePhoto = (row["livePhotoPeer"] as Int64?) != nil
        hasPreview = row["hasPreview"]
        blurhash = row["blurhash"]
        duration = row["duration"]
        let width: Int? = row["width"]
        let height: Int? = row["height"]
        if let width, let height, width > 0, height > 0 { aspectRatio = Double(width) / Double(height) } else { aspectRatio = 1 }
        name = row["name"]
        let path: String = row["path"]
        directory = (path as NSString).deletingLastPathComponent
        mimeType = row["mimeType"]
        isArchived = row["isArchived"]
    }

    /// Decodes a row of `LibraryStore.gridColumns` by position. Looking fifteen columns up by name for each of 100 000
    /// rows, and bridging every path to `NSString`, is most of the cost of a timeline query.
    init(gridRow row: Row) {
        fileId = row[0]
        timestamp = Date(timeIntervalSince1970: row[1] ?? 0)
        kind = MediaKind(rawValue: row[2]) ?? .image
        etag = row[3]
        isFavorite = row[4]
        isLivePhoto = !row.hasNull(atIndex: 5)
        hasPreview = row[6]
        blurhash = row[7]
        duration = row[8]
        let width: Int? = row[9]
        let height: Int? = row[10]
        if let width, let height, width > 0, height > 0 { aspectRatio = Double(width) / Double(height) } else { aspectRatio = 1 }
        name = row[11]
        directory = Self.directory(of: row[12])
        mimeType = row[13]
        isArchived = row[14]
    }

    /// `(path as NSString).deletingLastPathComponent` for the paths of the index (`/folder/…/name`), without bridging.
    static func directory(of path: String) -> String {
        let utf8 = path.utf8
        guard utf8.first == UInt8(ascii: "/"), utf8.last != UInt8(ascii: "/"), let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else {
            return (path as NSString).deletingLastPathComponent
        }
        if slash == utf8.startIndex { return "/" }
        let directory = path[..<slash]
        // "//" and similar: let Foundation normalise the rare odd path.
        if directory.utf8.last == UInt8(ascii: "/") { return (path as NSString).deletingLastPathComponent }
        return String(directory)
    }

    public init(_ item: MediaItem) {
        fileId = item.fileId
        timestamp = item.timestamp
        kind = item.kind
        etag = item.etag
        isFavorite = item.isFavorite
        isLivePhoto = item.isLivePhoto
        hasPreview = item.hasPreview
        blurhash = item.blurhash
        duration = item.duration
        aspectRatio = item.aspectRatio
        name = item.name
        directory = item.directory
        mimeType = item.mimeType
        isArchived = item.isArchived
    }
}

extension GridMedia {
    public var isVideo: Bool { kind == .video }
}

/// A row of the timeline with only what laying out, sectioning and badging the grid needs (about 40 bytes, no strings).
/// Details of the tiles on screen come from `LibraryStore.gridMedia(_:)`.
public struct TimelineRow: Hashable, Sendable, Identifiable {
    public var id: FileID { fileId }
    public var fileId: FileID
    public var timestamp: Date
    public var kind: MediaKind
    public var isFavorite: Bool
    public var isLivePhoto: Bool
    /// Pixel size; 0 when unknown.
    public var width: Int32
    public var height: Int32
    /// Video duration in seconds when known.
    public var duration: Double?

    public var aspectRatio: Double { width > 0 && height > 0 ? Double(width) / Double(height) : 1 }

    public init(
        fileId: FileID, timestamp: Date, kind: MediaKind = .image, isFavorite: Bool = false, isLivePhoto: Bool = false, width: Int32 = 0,
        height: Int32 = 0, duration: Double? = nil
    ) {
        self.fileId = fileId
        self.timestamp = timestamp
        self.kind = kind
        self.isFavorite = isFavorite
        self.isLivePhoto = isLivePhoto
        self.width = width
        self.height = height
        self.duration = duration
    }

    /// Decodes a row of `LibraryStore.timelineColumns` by position.
    init(timelineRow row: Row) {
        fileId = row[0]
        timestamp = Date(timeIntervalSince1970: row[1] ?? 0)
        kind = (row[2] as String) == MediaKind.video.rawValue ? .video : .image
        isFavorite = row[3]
        isLivePhoto = !row.hasNull(atIndex: 4)
        width = Int32(clamping: (row[5] as Int64?) ?? 0)
        height = Int32(clamping: (row[6] as Int64?) ?? 0)
        duration = row[7]
    }
}
