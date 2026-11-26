// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// What a timeline-like view shows.
public enum MediaFilter: Hashable, Sendable {
    case all
    case photos
    case videos
    case favorites
    case archived
    case place(String)
    case album(String)
    case person(String)
    case tag(Int)
    case fileIds([FileID])
}

/// A search over the index (SPEC SR-2/SR-3): AND between the kinds of criteria, OR within places, dates and albums.
public struct LibrarySearch: Hashable, Sendable {
    /// Free text. Every word must occur (as a substring, ignoring case and diacritics) in the file name, place, country,
    /// caption or folder path, or in the names of the file's tags and people, the labels recognised on this device
    /// (`SearchLabels`) or the titles of the albums it is in (`SearchAlbums`).
    public var texts: [String]
    public var places: [String]
    public var dateRanges: [Range<Date>]
    public var favoritesOnly: Bool
    public var videosOnly: Bool
    /// Still photos only (SPEC §16.2). With `videosOnly` too, nothing matches.
    public var photosOnly: Bool = false
    /// At least this many stars (SPEC §15.2 ratings, §16.2).
    public var minimumRating: Int?
    public var albumIds: [String]
    /// Memberships that come from the server (tags, people): results must be in every set.
    public var memberships: [Set<FileID>]

    public init(
        texts: [String] = [], places: [String] = [], dateRanges: [Range<Date>] = [], favoritesOnly: Bool = false,
        videosOnly: Bool = false, albumIds: [String] = [], memberships: [Set<FileID>] = []
    ) {
        self.texts = texts
        self.places = places
        self.dateRanges = dateRanges
        self.favoritesOnly = favoritesOnly
        self.videosOnly = videosOnly
        self.albumIds = albumIds
        self.memberships = memberships
    }

    /// The words of the free text.
    var terms: [String] {
        var seen = Set<String>()
        return texts.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { seen.insert($0.lowercased()).inserted }
    }
}

extension LibrarySearch {
    /// The criteria of filter chips that the index answers by itself. Tags and people are memberships on the server:
    /// fetch them and add one set per kind to `memberships`.
    public init(filters: [SearchFilter]) {
        self.init()
        for filter in filters {
            switch filter {
            case .text(let text): texts.append(text)
            case .place(let name): places.append(name)
            case .dateRange(let start, let end, _): if start < end { dateRanges.append(start..<end) }
            case .album(let id, _): albumIds.append(id)
            case .favorites: favoritesOnly = true
            case .videos: videosOnly = true
            case .photos: photosOnly = true
            // Something the photo shows is looked for in all the indexed text (labels, descriptions, tags…).
            case .label(let word): texts.append(word)
            case .rating(let stars): minimumRating = max(minimumRating ?? 0, stars)
            case .tag, .person: break
            }
        }
    }
}

/// A rectangle on the map, in degrees.
public struct MapRegion: Hashable, Sendable {
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = max(-90, minLatitude)
        self.maxLatitude = min(90, maxLatitude)
        self.minLongitude = max(-180, minLongitude)
        self.maxLongitude = min(180, maxLongitude)
    }

    /// The rectangle that reaches `latitudeReach` / `longitudeReach` degrees from the centre in each direction.
    public init(centerLatitude: Double, centerLongitude: Double, latitudeReach: Double, longitudeReach: Double) {
        self.init(
            minLatitude: centerLatitude - latitudeReach, maxLatitude: centerLatitude + latitudeReach,
            minLongitude: centerLongitude - longitudeReach, maxLongitude: centerLongitude + longitudeReach)
    }
}

/// The geotagged items of one grid cell of the map, aggregated by the database.
public struct MapCell: Hashable, Sendable, Identifiable {
    public var id: String { "\(row)-\(column)" }
    public var row: Int
    public var column: Int
    public var count: Int
    /// The newest file of the cell and where it was taken (where the cell's marker goes).
    public var cover: GridMedia
    public var latitude: Double
    public var longitude: Double
    /// The place name of the cover ("Lisbon"), for the marker's label.
    public var place: String?
    /// The region of the query this cell came from (its count is of the part inside); `LibraryStore.mapItems(in:)` lists the
    /// same items.
    public var region: MapRegion
    public var cellLatitude: Double
    public var cellLongitude: Double
    /// The time the map was filtered to (SPEC MP-1 time slider), nil for all of it.
    public var period: Range<Date>? = nil
}

/// Where and when the geotagged photos of the library were taken.
public struct MapOverview: Hashable, Sendable {
    public var oldest: Date
    public var newest: Date
    /// The smallest rectangle around all of them.
    public var region: MapRegion
}

/// What the actions of a selection need to know about it (which actions apply, their titles), without the items: a
/// whole library can be selected.
public struct SelectionSummary: Sendable, Equatable {
    /// The selected items that are known (index or collection media).
    public var count = 0
    public var favorites = 0
    public var deletable = 0
    public var writable = 0
    /// On the user's own storage, not archived and deletable: can be archived.
    public var archivable = 0
    public var archived = 0

    public init() {}

    public init(_ items: [MediaItem]) {
        for item in items { add(item) }
    }

    mutating func add(_ item: MediaItem) {
        count += 1
        if item.isFavorite { favorites += 1 }
        if item.permissions.canDelete { deletable += 1 }
        if item.permissions.canWrite { writable += 1 }
        if item.isOwnStorage && !item.isArchived && item.permissions.canDelete { archivable += 1 }
        if item.isArchived { archived += 1 }
    }

    public var allFavorite: Bool { count > 0 && favorites == count }
}

/// The memories of a library (SPEC §7.12).
public struct MemoriesSnapshot: Sendable, Equatable {
    public var onThisDay: [Memory] = []
    public var trips: [Memory] = []
    public var recap: Memory?

    public init(onThisDay: [Memory] = [], trips: [Memory] = [], recap: Memory? = nil) {
        self.onThisDay = onThisDay
        self.trips = trips
        self.recap = recap
    }
}
