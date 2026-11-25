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

/// Read and write access to the library index.
///
/// The `async` queries run on a database reader queue, never on the caller's actor: views call them from `.task` without
/// blocking the main thread. The synchronous ones are for callers that are off the main thread already (sync, widgets).
public struct LibraryStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// The time items are ordered by, as the expression the `media_timeline` index is built on (the generated
    /// `timestamp` column has the same value, but SQLite would not answer a query from that index alone with it).
    static let timestamp = "coalesce(media.capturedAt, media.modifiedAt)"

    static let gridColumns =
        "media.fileId, \(timestamp) AS timestamp, media.kind, media.etag, media.isFavorite, media.livePhotoPeer, media.hasPreview, media.blurhash, media.duration, media.width, media.height, media.name, media.path, media.mimeType, media.isArchived"

    /// The columns of `TimelineRow`; all of them are in the `media_timeline` index.
    static let timelineColumns =
        "media.fileId, \(timestamp) AS timestamp, media.kind, media.isFavorite, media.livePhotoPeer, media.width, media.height, media.duration"

    /// Items that are shown at all: not the video half of a Live Photo and not archived. Written out literally (not bound)
    /// so that SQLite can use the partial indexes declared with the same condition.
    static let visible = "media.isLivePhotoVideo = 0 AND media.isArchived = 0"

    static let displayOrder = "ORDER BY \(timestamp) DESC, media.fileId DESC"

    /// SQL for a filter; visible items exclude Live Photo videos and (unless asked) archived items.
    static func sql(
        for filter: MediaFilter, excludedPrefixes: [String], columns: String = gridColumns, culling: CullingFilter = .all
    ) -> (String, StatementArguments) {
        var conditions = ["media.isLivePhotoVideo = 0"]
        var arguments: StatementArguments = []
        switch filter {
        case .all: conditions.append("media.isArchived = 0")
        case .photos: conditions.append("media.isArchived = 0 AND media.kind = 'image'")
        case .videos: conditions.append("media.isArchived = 0 AND media.kind = 'video'")
        case .favorites: conditions.append("media.isArchived = 0 AND media.isFavorite = 1")
        case .archived: conditions.append("media.isArchived = 1")
        case .place(let name):
            conditions.append("media.isArchived = 0 AND media.place = ?")
            arguments += [name]
        // Memberships are subqueries, not joins: an item is listed once however often it is a member (a person can have
        // two detections in one photo), without a DISTINCT over every column.
        case .album(let id):
            conditions.append("media.fileId IN (SELECT fileId FROM albumItem WHERE albumId = ?)")
            arguments += [id]
        case .person(let name):
            conditions.append("media.fileId IN (SELECT fileId FROM personItem WHERE person = ?)")
            arguments += [name]
        case .tag(let id):
            conditions.append("media.isArchived = 0 AND media.fileId IN (SELECT fileId FROM tagItem WHERE tagId = ?)")
            arguments += [id]
        case .fileIds(let ids):
            conditions.append("media.fileId IN (\(ids.map { String($0) }.joined(separator: ",").ifEmpty("-1")))")
        }
        for prefix in excludedPrefixes {
            conditions.append("media.path NOT LIKE ? ESCAPE '\\'")
            arguments += [Self.likePrefix(prefix)]
        }
        // Ratings and flags (SPEC §15.2).
        if let (condition, values) = CullingStore.condition(for: culling) {
            conditions.append(condition)
            arguments += values
        }
        let sql = "SELECT \(columns) FROM media WHERE \(conditions.joined(separator: " AND ")) \(displayOrder)"
        return (sql, arguments)
    }

    static func likePrefix(_ folder: String) -> String {
        let trimmed = folder.hasSuffix("/") ? folder : folder + "/"
        return likeEscaped(trimmed) + "%"
    }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(
            of: "_", with: "\\_")
    }

    static func fetchGrid(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> [GridMedia] {
        var result: [GridMedia] = []
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() { result.append(GridMedia(gridRow: row)) }
        return result
    }

    static func fetchTimeline(_ db: Database, sql: String, arguments: StatementArguments = []) throws -> [TimelineRow] {
        var result: [TimelineRow] = []
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() { result.append(TimelineRow(timelineRow: row)) }
        return result
    }

    // MARK: Grids

    public func gridItems(_ filter: MediaFilter, excludedFolders: [String] = []) throws -> [GridMedia] {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders)
        return try database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments) }
    }

    /// `gridItems` without blocking the caller's actor.
    public func fetchGridItems(_ filter: MediaFilter, excludedFolders: [String] = []) async throws -> [GridMedia] {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders)
        return try await database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments) }
    }

    /// Live updates of a grid query. Values are fetched and compared off the main thread.
    ///
    /// - Parameter interval: with `.zero` every committed change of the tables involved refetches at once. With an
    ///   interval, a change after a quiet period still refetches at once, but during a burst of writes (a sync that
    ///   stores page after page) there is at most one refetch per interval, and the last state is always delivered.
    public func observeGrid(
        _ filter: MediaFilter, excludedFolders: [String] = [], culling: CullingFilter = .all, coalescing interval: Duration = .zero
    ) -> AsyncThrowingStream<[GridMedia], any Error> {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders, culling: culling)
        if interval > .zero {
            return observeCoalesced(sql: sql, arguments: arguments, interval: interval) { db in
                try Self.fetchGrid(db, sql: sql, arguments: arguments)
            }
        }
        return ValueObservation.tracking { db in try Self.fetchGrid(db, sql: sql, arguments: arguments) }
            .removeDuplicates()
            .values(in: database.writer)
            .stream()
    }

    /// The timeline as lightweight rows, in display order (newest first). For `.all`, `.photos`, `.videos` and
    /// `.favorites` without excluded folders this reads one index and nothing else.
    public func timelineRows(_ filter: MediaFilter = .all, excludedFolders: [String] = []) async throws -> [TimelineRow] {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders, columns: Self.timelineColumns)
        return try await database.writer.read { db in try Self.fetchTimeline(db, sql: sql, arguments: arguments) }
    }

    /// Live updates of the timeline as lightweight rows; cheap enough to follow a running sync (see `observeGrid` for
    /// what `interval` does). Pair it with `gridMedia(_:)` for the tiles on screen.
    public func observeTimeline(
        _ filter: MediaFilter = .all, excludedFolders: [String] = [], coalescing interval: Duration = .milliseconds(300)
    ) -> AsyncThrowingStream<[TimelineRow], any Error> {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders, columns: Self.timelineColumns)
        return observeCoalesced(sql: sql, arguments: arguments, interval: interval) { db in
            try Self.fetchTimeline(db, sql: sql, arguments: arguments)
        }
    }

    /// Grid details of some items (the tiles on screen of a timeline built from `TimelineRow`).
    public func gridMedia(_ fileIds: [FileID]) async throws -> [FileID: GridMedia] {
        try await database.writer.read { db in try Self.gridMedia(db, fileIds) }
    }

    static func gridMedia(_ db: Database, _ fileIds: [FileID]) throws -> [FileID: GridMedia] {
        var result: [FileID: GridMedia] = [:]
        result.reserveCapacity(fileIds.count)
        for chunk in fileIds.chunked(500) {
            let sql = "SELECT \(gridColumns) FROM media WHERE media.fileId IN (\(chunk.map { String($0) }.joined(separator: ",")))"
            for item in try fetchGrid(db, sql: sql) { result[item.fileId] = item }
        }
        return result
    }

    /// While the tables keep changing (more than `busyRefetches` refetches within `busyWindow`: a sync storing page after
    /// page, a backup uploading photo after photo, the outbox working through a large selection), a coalesced observation
    /// refetches at most this often. A change after a quiet moment still refetches at once.
    static let busyInterval = Duration.seconds(2)
    static let busyWindow = Duration.seconds(5)
    static let busyRefetches = 3

    /// Observes the tables `sql` reads and refetches with `fetch` when they change, at most once per `interval` during a
    /// burst, and at most once per `busyInterval` while the burst goes on. Equal values are not delivered twice.
    func observeCoalesced<Value: Sendable & Equatable>(
        sql: String, arguments: StatementArguments, interval: Duration, fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        let writer = database.writer
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // One pending signal is enough: whatever was committed before a fetch starts is seen by that fetch.
            let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let observation = DatabaseRegionObservation(tracking: SQLRequest<Row>(sql: sql, arguments: arguments))
            let cancellable = observation.start(
                in: writer, onError: { error in continuation.finish(throwing: error) }, onChange: { _ in changed.yield() })
            let task = Task {
                do {
                    var last = try await writer.read(fetch)
                    var fetchedAt = ContinuousClock.now
                    var recent: [ContinuousClock.Instant] = []
                    continuation.yield(last)
                    for await _ in changes {
                        let busy = recent.count >= Self.busyRefetches && ContinuousClock.now - recent[0] < Self.busyWindow
                        let wait = (busy ? max(interval, Self.busyInterval) : interval) - (ContinuousClock.now - fetchedAt)
                        if wait > .zero { try await Task.sleep(for: wait) }
                        try Task.checkCancellation()
                        let value = try await writer.read(fetch)
                        fetchedAt = .now
                        recent.append(fetchedAt)
                        if recent.count > Self.busyRefetches { recent.removeFirst(recent.count - Self.busyRefetches) }
                        if value != last {
                            last = value
                            continuation.yield(value)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                cancellable.cancel()
                changed.finish()
            }
        }
    }

    // MARK: Items

    public func item(_ fileId: FileID) throws -> MediaItem? {
        try database.writer.read { db in
            if let item = try MediaItem.fetchOne(db, key: fileId) { return item }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
    }

    /// Live updates of one item (index or collection-only), e.g. the photo shown in the viewer: its favourite heart
    /// follows a toggle, and the next toggle sends the opposite value.
    public func observeItem(_ fileId: FileID) -> AsyncThrowingStream<MediaItem?, any Error> {
        ValueObservation.tracking { db -> MediaItem? in
            if let item = try MediaItem.fetchOne(db, key: fileId) { return item }
            return try CollectionMediaRecord.fetchOne(db, key: fileId)?.item
        }
        .removeDuplicates()
        .values(in: database.writer)
        .stream()
    }

    public func items(_ fileIds: [FileID]) throws -> [FileID: MediaItem] {
        try database.writer.read { db in try Self.items(db, fileIds) }
    }

    /// `items(_:)` without blocking the caller's actor.
    public func fetchItems(_ fileIds: [FileID]) async throws -> [FileID: MediaItem] {
        try await database.writer.read { db in try Self.items(db, fileIds) }
    }

    static func items(_ db: Database, _ fileIds: [FileID]) throws -> [FileID: MediaItem] {
        var result: [FileID: MediaItem] = [:]
        result.reserveCapacity(fileIds.count)
        // In chunks: a memory or a map area can have more items than SQLite accepts bound values.
        for chunk in fileIds.chunked(5000) {
            for item in try MediaItem.fetchAll(db, keys: chunk) { result[item.fileId] = item }
            let missing = chunk.filter { result[$0] == nil }
            for record in try CollectionMediaRecord.fetchAll(db, keys: missing) { result[record.fileId] = record.item }
        }
        return result
    }

    /// Counts what the actions of a selection depend on, in the database: no item of a selection of 150 000 is loaded.
    public func selectionSummary(_ fileIds: [FileID]) async throws -> SelectionSummary {
        try await database.writer.read { db in try Self.selectionSummary(fileIds, db: db) }
    }

    /// `selectionSummary` for callers that must answer at once (a context menu that opens before the summary arrived).
    public func selectionSummaryNow(_ fileIds: [FileID]) throws -> SelectionSummary {
        try database.writer.read { db in try Self.selectionSummary(fileIds, db: db) }
    }

    static func selectionSummary(_ fileIds: [FileID], db: Database) throws -> SelectionSummary {
        var summary = SelectionSummary()
        for chunk in fileIds.chunked(5000) {
            let list = chunk.map { String($0) }.joined(separator: ",")
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*), TOTAL(isFavorite), TOTAL(instr(permissions, 'D') > 0), TOTAL(instr(permissions, 'W') > 0),
                        TOTAL(mountType = '' AND isArchived = 0 AND instr(permissions, 'D') > 0), TOTAL(isArchived)
                    FROM media WHERE fileId IN (\(list))
                    """)
            if let row {
                summary.count += row[0] as Int
                summary.favorites += Int(row[1] as Double)
                summary.deletable += Int(row[2] as Double)
                summary.writable += Int(row[3] as Double)
                summary.archivable += Int(row[4] as Double)
                summary.archived += Int(row[5] as Double)
            }
            // Items of shared albums and other collections are not in the index.
            let indexed = row.map { $0[0] as Int } ?? 0
            guard indexed < chunk.count else { continue }
            let found = Set(try FileID.fetchAll(db, sql: "SELECT fileId FROM media WHERE fileId IN (\(list))"))
            for record in try CollectionMediaRecord.fetchAll(db, keys: chunk.filter { !found.contains($0) }) { summary.add(record.item) }
        }
        return summary
    }

    /// All visible items as full rows. This is the whole table: only for work that really needs every item (duplicates,
    /// clean-up), and never on the main thread. Search, memories and the map have their own queries.
    public func allVisibleItems() throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(db, sql: "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 ORDER BY timestamp DESC")
        }
    }

    /// The visible items that can be exact duplicates of another (SPEC §7.15): another visible item has the same size,
    /// capture second and pixel size. `Duplicates.groups` over these gives the same groups as over the whole library,
    /// without loading every row.
    public func duplicateCandidates() async throws -> [MediaItem] {
        try await database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    WITH visible AS (
                        SELECT * FROM media
                        WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND size > 0
                            AND capturedAt IS NOT NULL AND width IS NOT NULL AND height IS NOT NULL),
                    keys AS (
                        SELECT size, CAST(capturedAt AS INTEGER) AS second, width, height FROM visible
                        GROUP BY size, second, width, height HAVING COUNT(*) >= 2)
                    SELECT visible.* FROM visible
                    JOIN keys ON keys.size = visible.size AND keys.second = CAST(visible.capturedAt AS INTEGER)
                        AND keys.width = visible.width AND keys.height = visible.height
                    ORDER BY visible.timestamp DESC
                    """)
        }
    }

    /// The visible items that can be "Free up space" candidates (SPEC §7.15): videos, PNGs and images whose name has
    /// the words of a screenshot. `Cleanup.candidates` over these gives the same result as over the whole library;
    /// the exact rules (patterns, phone screen sizes, permissions) stay in `Cleanup`.
    public func cleanupCandidates() async throws -> [MediaItem] {
        // Wider than `Cleanup.screenshotNames` (`%` for the optional separators and the apostrophes and accents).
        let names = ["%screen%shot%", "%bildschirmfoto%", "%capture d%cran%", "%captura de pantalla%", "%schermafbeelding%"]
        let nameClause = names.map { _ in "name LIKE ?" }.joined(separator: " OR ")
        let arguments = StatementArguments([MediaKind.video.rawValue, MediaKind.image.rawValue] + names)
        return try await database.writer.read { db in
            try MediaItem.fetchAll(
                db,
                sql: """
                    SELECT * FROM media
                    WHERE isLivePhotoVideo = 0 AND isArchived = 0
                        AND (kind = ? OR (kind = ? AND (lower(mimeType) = 'image/png' OR \(nameClause))))
                    ORDER BY timestamp DESC
                    """, arguments: arguments)
        }
    }

    /// Items within ±3 days of today in each of the last 20 years (cheap SQL for widgets).
    public func onThisDayItems(now: Date = Date(), calendar: Calendar = .current, limit: Int = 200) throws -> [MediaItem] {
        var ranges: [String] = []
        var arguments: StatementArguments = []
        for yearsAgo in 1...20 {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: now),
                let start = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: anchor)),
                let end = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: anchor))
            else { continue }
            ranges.append("(timestamp >= ? AND timestamp < ?)")
            arguments += [start.timeIntervalSince1970, end.timeIntervalSince1970]
        }
        let sql =
            "SELECT * FROM media WHERE isLivePhotoVideo = 0 AND isArchived = 0 AND kind = 'image' AND (\(ranges.joined(separator: " OR "))) ORDER BY isFavorite DESC, timestamp DESC LIMIT \(limit)"
        return try database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    public func favoriteImages(limit: Int = 50) throws -> [MediaItem] {
        try database.writer.read { db in
            try MediaItem.fetchAll(
                db, sql: "SELECT * FROM media WHERE isFavorite = 1 AND isArchived = 0 AND kind = 'image' ORDER BY timestamp DESC LIMIT ?",
                arguments: [limit])
        }
    }

    public func count() throws -> Int {
        try database.writer.read { db in try MediaItem.fetchCount(db) }
    }

    // MARK: Search

    /// The conditions of a search, without the server memberships (those are applied to the rows).
    static func searchSQL(_ search: LibrarySearch, columns: String) -> (String, StatementArguments) {
        var conditions = [visible]
        var arguments: StatementArguments = []
        // Trigram tokens need three characters; shorter words are looked up by scanning the indexed text.
        let terms = search.terms
        let indexed = terms.filter { $0.unicodeScalars.count >= 3 }
        if !indexed.isEmpty {
            conditions.append("media.fileId IN (SELECT rowid FROM searchIndex WHERE searchIndex MATCH ?)")
            arguments += [SearchIndex.matchExpression(indexed)]
        }
        for term in terms where term.unicodeScalars.count < 3 {
            conditions.append("media.fileId IN (SELECT rowid FROM searchIndex WHERE text LIKE ? ESCAPE '\\')")
            arguments += ["%" + likeEscaped(term) + "%"]
        }
        if !search.places.isEmpty {
            conditions.append("media.place IN (\(search.places.map { _ in "?" }.joined(separator: ",")))")
            for place in search.places { arguments += [place] }
        }
        if !search.dateRanges.isEmpty {
            let ranges = search.dateRanges.map { _ in "(\(timestamp) >= ? AND \(timestamp) < ?)" }
            conditions.append("(" + ranges.joined(separator: " OR ") + ")")
            for range in search.dateRanges {
                arguments += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
            }
        }
        if search.favoritesOnly { conditions.append("media.isFavorite = 1") }
        if search.videosOnly { conditions.append("media.kind = 'video'") }
        if !search.albumIds.isEmpty {
            let marks = search.albumIds.map { _ in "?" }.joined(separator: ",")
            conditions.append("media.fileId IN (SELECT fileId FROM albumItem WHERE albumId IN (\(marks)))")
            for id in search.albumIds { arguments += [id] }
        }
        return ("SELECT \(columns) FROM media WHERE \(conditions.joined(separator: " AND ")) \(displayOrder)", arguments)
    }

    /// Search results as grid rows, newest first.
    public func search(_ search: LibrarySearch) async throws -> [GridMedia] {
        let (sql, arguments) = Self.searchSQL(search, columns: Self.gridColumns)
        return try await database.writer.read { db in
            var result: [GridMedia] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try rows.next() {
                let fileId: FileID = row[0]
                if search.memberships.allSatisfy({ $0.contains(fileId) }) { result.append(GridMedia(gridRow: row)) }
            }
            let extra = try Self.albumOnlyMatches(search, db: db)
            guard !extra.isEmpty else { return result }
            return Self.newestFirst(result + extra.map(GridMedia.init), timestamp: \.timestamp, fileId: \.fileId)
        }
    }

    /// Search results as full items (smart albums), newest first.
    public func searchItems(_ search: LibrarySearch) async throws -> [MediaItem] {
        let (sql, arguments) = Self.searchSQL(search, columns: "media.*")
        return try await database.writer.read { db in
            let items = try MediaItem.fetchAll(db, sql: sql, arguments: arguments)
            let found = items.filter { item in search.memberships.allSatisfy { $0.contains(item.fileId) } }
            let extra = try Self.albumOnlyMatches(search, db: db)
            guard !extra.isEmpty else { return found }
            return Self.newestFirst(found + extra, timestamp: \.timestamp, fileId: \.fileId)
        }
    }

    static func newestFirst<T>(_ items: [T], timestamp: (T) -> Date, fileId: (T) -> FileID) -> [T] {
        items.sorted { a, b in
            let (ta, tb) = (timestamp(a), timestamp(b))
            return ta != tb ? ta > tb : fileId(a) > fileId(b)
        }
    }

    /// Photos of albums that are not in the timeline index (other people's photos in albums shared with the user, own
    /// albums' photos outside the timeline folders), matched by the album filters and by free text over their name,
    /// place, caption and album titles (SPEC SR-3). Only for searches by text or album: the other criteria alone search
    /// the library. They are known once the album's content was read (`collectionMedia`), and are checked here in Swift
    /// with the same rules as the index (every word a substring, case and diacritics ignored).
    static func albumOnlyMatches(_ search: LibrarySearch, db: Database) throws -> [MediaItem] {
        let terms = search.terms
        guard !terms.isEmpty || !search.albumIds.isEmpty else { return [] }
        var conditions = ["album.kind IN ('own', 'shared')", "albumItem.fileId NOT IN (SELECT fileId FROM media)"]
        var arguments: StatementArguments = []
        if !search.albumIds.isEmpty {
            let marks = search.albumIds.map { _ in "?" }.joined(separator: ",")
            conditions.append("albumItem.fileId IN (SELECT fileId FROM albumItem WHERE albumId IN (\(marks)))")
            for id in search.albumIds { arguments += [id] }
        }
        let sql = """
            SELECT albumItem.fileId, group_concat(album.title, ' ') FROM albumItem JOIN album ON album.id = albumItem.albumId
            WHERE \(conditions.joined(separator: " AND ")) GROUP BY albumItem.fileId
            """
        var titles: [FileID: String] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) { titles[row[0]] = row[1] ?? "" }
        guard !titles.isEmpty else { return [] }
        var result: [MediaItem] = []
        for chunk in Array(titles.keys).chunked(500) {
            for record in try CollectionMediaRecord.fetchAll(db, keys: Array(chunk)) {
                let item = record.item
                guard Self.matches(item, albumTitles: titles[item.fileId] ?? "", search: search, terms: terms) else { continue }
                result.append(item)
            }
        }
        return result
    }

    /// Whether a photo that is not in the index meets a search: what `searchSQL` asks of an indexed one.
    static func matches(_ item: MediaItem, albumTitles: String, search: LibrarySearch, terms: [String]) -> Bool {
        guard !item.isLivePhotoVideo, !item.isArchived else { return false }
        if !terms.isEmpty {
            let fields = [item.name, item.place, item.placeCountry, item.caption, albumTitles].compactMap { $0 }
            let text = fields.joined(separator: " ")
            for term in terms where text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        if !search.places.isEmpty && !search.places.contains(item.place ?? "") { return false }
        if !search.dateRanges.isEmpty && !search.dateRanges.contains(where: { $0.contains(item.timestamp) }) { return false }
        if search.favoritesOnly && !item.isFavorite { return false }
        if search.videosOnly && item.kind != .video { return false }
        return search.memberships.allSatisfy { $0.contains(item.fileId) }
    }

    /// The names of the places visible items were taken at, sorted (search suggestions).
    public func placeNames() async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT DISTINCT media.place FROM media WHERE media.place IS NOT NULL AND media.place <> '' AND \(Self.visible) ORDER BY 1"
            )
        }
    }

    // MARK: Memories

    /// On this day, trips and the year in review, from purpose-built queries (SPEC §7.12).
    public func memories(onlyOnThisDay: Bool = false, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current)
        async throws -> MemoriesSnapshot
    {
        try await database.writer.read { db in
            var snapshot = MemoriesSnapshot()
            snapshot.onThisDay = Memories.onThisDay(
                try Self.onThisDayCandidates(db, now: now, calendar: calendar), now: now, calendar: calendar)
            guard !onlyOnThisDay else { return snapshot }
            snapshot.trips = Memories.trips(try Self.tripCandidates(db), locale: locale)
            snapshot.recap = Memories.yearRecap(try Self.recapCandidates(db, calendar: calendar), calendar: calendar)
            return snapshot
        }
    }

    static func memoryItems(_ db: Database, sql: String, arguments: StatementArguments = [], into result: inout [MemoryItem]) throws {
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            result.append(
                MemoryItem(fileId: row[0], timestamp: Date(timeIntervalSince1970: row[1] ?? 0), isFavorite: row[2], place: row[3]))
        }
    }

    static let inTimeRange = "\(visible) AND \(timestamp) >= ? AND \(timestamp) < ?"

    /// The items inside the on-this-day windows: twenty short ranges of the timeline index.
    static func onThisDayCandidates(_ db: Database, now: Date, calendar: Calendar) throws -> [MemoryItem] {
        var result: [MemoryItem] = []
        for window in Memories.onThisDayWindows(now: now, calendar: calendar) {
            try memoryItems(
                db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, NULL FROM media WHERE \(inTimeRange)",
                arguments: [window.range.lowerBound.timeIntervalSince1970, window.range.upperBound.timeIntervalSince1970], into: &result)
        }
        return result
    }

    /// Trips are found by the gaps between consecutive items, so this reads four columns of every visible item.
    static func tripCandidates(_ db: Database) throws -> [MemoryItem] {
        var result: [MemoryItem] = []
        try memoryItems(
            db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, media.place FROM media WHERE \(visible)", into: &result)
        return result
    }

    /// The items of the newest year that has enough photos for a recap; years are counted in the timeline index.
    static func recapCandidates(_ db: Database, calendar: Calendar) throws -> [MemoryItem] {
        func edge(_ direction: String) throws -> Double? {
            try Double.fetchOne(db, sql: "SELECT \(timestamp) FROM media WHERE \(visible) ORDER BY \(timestamp) \(direction) LIMIT 1")
        }
        guard let newest = try edge("DESC"), let oldest = try edge("ASC") else { return [] }
        let firstYear = calendar.component(.year, from: Date(timeIntervalSince1970: oldest))
        var year = calendar.component(.year, from: Date(timeIntervalSince1970: newest))
        while year >= firstYear {
            defer { year -= 1 }
            guard let start = calendar.date(from: DateComponents(year: year)), let end = calendar.date(from: DateComponents(year: year + 1))
            else { continue }
            let range: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media WHERE \(inTimeRange)", arguments: range) ?? 0
            if count >= Memories.recapMinimum {
                var result: [MemoryItem] = []
                try memoryItems(
                    db, sql: "SELECT media.fileId, \(timestamp), media.isFavorite, NULL FROM media WHERE \(inTimeRange)", arguments: range,
                    into: &result)
                return result
            }
        }
        return []
    }

    // MARK: Map

    static let located =
        "\(visible) AND media.latitude IS NOT NULL AND media.longitude IS NOT NULL AND NOT (media.latitude = 0 AND media.longitude = 0)"

    static let inRegion = "media.latitude >= ? AND media.latitude <= ? AND media.longitude >= ? AND media.longitude <= ?"

    static func arguments(_ region: MapRegion) -> StatementArguments {
        [region.minLatitude, region.maxLatitude, region.minLongitude, region.maxLongitude]
    }

    /// The located items of a region, within a period when the map is filtered by time.
    static func mapCondition(_ region: MapRegion, period: Range<Date>?) -> (String, StatementArguments) {
        guard let period else { return ("\(located) AND \(inRegion)", arguments(region)) }
        return (
            "\(located) AND \(inRegion) AND \(timestamp) >= ? AND \(timestamp) < ?",
            arguments(region) + [period.lowerBound.timeIntervalSince1970, period.upperBound.timeIntervalSince1970]
        )
    }

    /// The grid cell of a coordinate, as SQL. The offsets keep the values positive, so the cast rounds down.
    static let cellRow = "CAST((media.latitude + 90.0) / ? AS INTEGER)"
    static let cellColumn = "CAST((media.longitude + 180.0) / ? AS INTEGER)"

    /// Geotagged items of a region, aggregated into grid cells by the database (SPEC MP-1): the map never holds the
    /// located items themselves, only one row per cell. With a `period` only the items taken then (time slider).
    public func mapCells(in region: MapRegion, cellLatitude: Double, cellLongitude: Double, during period: Range<Date>? = nil)
        async throws -> [MapCell]
    {
        guard cellLatitude > 0, cellLongitude > 0 else { return [] }
        let (condition, conditionArguments) = Self.mapCondition(region, period: period)
        return try await database.writer.read { db in
            let sql = """
                SELECT \(Self.cellRow) AS cellRow, \(Self.cellColumn) AS cellColumn, COUNT(*), MAX(media.fileId)
                FROM media WHERE \(condition) GROUP BY cellRow, cellColumn
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cellLatitude, cellLongitude] + conditionArguments)
            let coverIds: [FileID] = rows.map { $0[3] }
            let covers = try Self.gridMedia(db, coverIds)
            var coordinates: [FileID: (Double, Double, String?)] = [:]
            for chunk in coverIds.chunked(500) {
                let list = chunk.map { String($0) }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT fileId, latitude, longitude, place FROM media WHERE fileId IN (\(list))") {
                    coordinates[row[0]] = (row[1], row[2], row[3])
                }
            }
            return rows.compactMap { row -> MapCell? in
                let coverId: FileID = row[3]
                guard let cover = covers[coverId], let coordinate = coordinates[coverId] else { return nil }
                return MapCell(
                    row: row[0], column: row[1], count: row[2], cover: cover, latitude: coordinate.0, longitude: coordinate.1,
                    place: coordinate.2.flatMap { $0.isEmpty ? nil : $0 }, region: region, cellLatitude: cellLatitude,
                    cellLongitude: cellLongitude, period: period)
            }
        }
    }

    /// The condition of the items of some cells of the same size and period (a marker, or a cluster of markers MapKit
    /// merged, which may come from the queries of different regions as the map moved): their rows and columns, within the
    /// rectangle around the cells (for the coordinate index) and around the regions they were counted in.
    static func cellsCondition(_ cells: [MapCell]) -> (String, StatementArguments)? {
        guard let first = cells.first else { return nil }
        // A little more than the cells: the rows and columns decide, the rectangle only narrows the index range.
        let margin = 1e-9
        let rows = cells.map(\.row)
        let columns = cells.map(\.column)
        let around = MapRegion(
            minLatitude: max(Double(rows.min()!) * first.cellLatitude - 90 - margin, cells.map(\.region.minLatitude).min()!),
            maxLatitude: min(Double(rows.max()! + 1) * first.cellLatitude - 90 + margin, cells.map(\.region.maxLatitude).max()!),
            minLongitude: max(Double(columns.min()!) * first.cellLongitude - 180 - margin, cells.map(\.region.minLongitude).min()!),
            maxLongitude: min(Double(columns.max()! + 1) * first.cellLongitude - 180 + margin, cells.map(\.region.maxLongitude).max()!))
        var (condition, arguments) = mapCondition(around, period: first.period)
        let pairs = cells.map { _ in "(?, ?)" }.joined(separator: ", ")
        condition += " AND (\(cellRow), \(cellColumn)) IN (VALUES \(pairs))"
        arguments += [first.cellLatitude, first.cellLongitude]
        for cell in cells { arguments += [cell.row, cell.column] }
        return (condition, arguments)
    }

    /// The items of a map cell, newest first.
    public func mapItems(in cell: MapCell) async throws -> [MediaItem] {
        guard let (condition, arguments) = Self.cellsCondition([cell]) else { return [] }
        let sql = "SELECT media.* FROM media WHERE \(condition) \(Self.displayOrder)"
        return try await database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// The geotagged items of a region, newest first.
    public func mapItems(in region: MapRegion, during period: Range<Date>? = nil) async throws -> [MediaItem] {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT media.* FROM media WHERE \(condition) \(Self.displayOrder)"
        return try await database.writer.read { db in try MediaItem.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// A page of the items of a map cell as grid rows, newest first ("Photos in this area" can be most of the library).
    public func mapGridItems(in cell: MapCell, limit: Int, offset: Int = 0) async throws -> [GridMedia] {
        try await mapGridItems(in: [cell], limit: limit, offset: offset)
    }

    /// A page of the items of several cells of the same query (a cluster) as grid rows, newest first.
    public func mapGridItems(in cells: [MapCell], limit: Int, offset: Int = 0) async throws -> [GridMedia] {
        guard let (condition, arguments) = Self.cellsCondition(cells) else { return [] }
        let sql = "SELECT \(Self.gridColumns) FROM media WHERE \(condition) \(Self.displayOrder) LIMIT ? OFFSET ?"
        return try await database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments + [limit, offset]) }
    }

    /// A page of the geotagged items of a region as grid rows, newest first.
    public func mapGridItems(in region: MapRegion, during period: Range<Date>? = nil, limit: Int, offset: Int = 0) async throws
        -> [GridMedia]
    {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT \(Self.gridColumns) FROM media WHERE \(condition) \(Self.displayOrder) LIMIT ? OFFSET ?"
        return try await database.writer.read { db in try Self.fetchGrid(db, sql: sql, arguments: arguments + [limit, offset]) }
    }

    public func mapItemCount(in region: MapRegion, during period: Range<Date>? = nil) async throws -> Int {
        let (condition, arguments) = Self.mapCondition(region, period: period)
        let sql = "SELECT COUNT(*) FROM media WHERE \(condition)"
        return try await database.writer.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    /// Where and when the geotagged photos were taken: the area the map opens on and the ends of its time slider.
    public func mapOverview() async throws -> MapOverview? {
        try await database.writer.read { db in
            let sql = """
                SELECT MIN(\(Self.timestamp)), MAX(\(Self.timestamp)), MIN(media.latitude), MAX(media.latitude),
                    MIN(media.longitude), MAX(media.longitude)
                FROM media WHERE \(Self.located)
                """
            guard let row = try Row.fetchOne(db, sql: sql), let oldest = row[0] as Double?, let newest = row[1] as Double? else {
                return nil
            }
            return MapOverview(
                oldest: Date(timeIntervalSince1970: oldest), newest: Date(timeIntervalSince1970: newest),
                region: MapRegion(minLatitude: row[2], maxLatitude: row[3], minLongitude: row[4], maxLongitude: row[5]))
        }
    }

    // MARK: Writes

    /// Inserts or updates index rows. Rows that are already stored exactly like this are not written again: a sync that
    /// re-reads known items (recent uploads, the overlap of the delta window) then neither rewrites rows and indexes nor
    /// wakes the observers of the timeline.
    public func upsert(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        try database.writer.write { db in
            for chunk in items.chunked(1000) {
                var stored: [FileID: MediaItem] = [:]
                for item in try MediaItem.fetchAll(db, keys: chunk.map(\.fileId)) { stored[item.fileId] = item }
                for item in chunk where stored[item.fileId] != item { try item.upsert(db) }
            }
        }
    }

    public func delete(_ fileIds: [FileID]) throws {
        guard !fileIds.isEmpty else { return }
        try database.writer.write { db in
            for chunk in fileIds.chunked(5000) { _ = try MediaItem.deleteAll(db, keys: chunk) }
        }
    }

    /// Optimistic local update (outbox applies it on the server).
    public func update(_ fileId: FileID, _ change: @Sendable (inout MediaItem) -> Void) throws {
        try database.writer.write { db in
            guard var item = try MediaItem.fetchOne(db, key: fileId) else { return }
            change(&item)
            try item.update(db)
        }
    }

    /// Keeps items that are not in the timeline index (shared albums, other folders, people…) so viewers can show them.
    public func storeCollectionMedia(_ items: [MediaItem]) throws {
        try database.writer.write { db in
            for item in items where try !MediaItem.exists(db, key: item.fileId) {
                try CollectionMediaRecord(fileId: item.fileId, item: item).upsert(db)
            }
        }
    }

    /// Empties the timeline index and the sync state (the timeline folders changed). Albums and their content stay:
    /// they do not depend on the folders, and offline albums are defined by them.
    public func deleteIndex() throws {
        try database.writer.write { db in
            try db.execute(sql: SearchAlbums.dropTriggersSQL)
            try db.execute(sql: SearchIndex.dropSQL)
            try db.execute(sql: "DELETE FROM media; DELETE FROM syncState; DELETE FROM reconcileUnseen; DELETE FROM reconcileSuspect")
            try db.execute(sql: SearchIndex.createSQL)
            try db.execute(sql: SearchAlbums.triggersSQL)
        }
    }

    public func deleteAll() throws {
        try database.writer.write { db in
            // Without the triggers the tables are emptied in one step each instead of row by row.
            try db.execute(sql: SearchAlbums.dropTriggersSQL)
            try db.execute(sql: SearchIndex.dropSQL)
            try db.execute(
                sql:
                    "DELETE FROM media; DELETE FROM albumItem; DELETE FROM album; DELETE FROM syncState; DELETE FROM reconcileUnseen; DELETE FROM reconcileSuspect"
            )
            try db.execute(sql: SearchIndex.createSQL)
            try db.execute(sql: SearchAlbums.triggersSQL)
        }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

extension AsyncValueObservation {
    /// Wraps a GRDB observation so modules that don't import GRDB can consume it.
    public func stream() -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in self { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
