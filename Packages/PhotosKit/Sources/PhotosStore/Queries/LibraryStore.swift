// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

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

    /// Live updates of the newest item of a grid (the Favorites card's cover, SPEC §20.1); nil when it is empty. One row,
    /// read from the timeline's index; a change that does not change the newest item is not delivered.
    public func observeNewest(_ filter: MediaFilter, excludedFolders: [String] = []) -> AsyncThrowingStream<GridMedia?, any Error> {
        let (sql, arguments) = Self.sql(for: filter, excludedPrefixes: excludedFolders)
        let first = sql + " LIMIT 1"
        return ValueObservation.tracking { db in try Self.fetchGrid(db, sql: first, arguments: arguments).first }
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
