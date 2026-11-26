// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

extension SimilarityStore {
    /// The series of similar shots across the library (Clean up, SPEC §19.3): the indexed current versions of visible
    /// photos, in time order, read with a cursor and grouped on the way, so only one series is in memory at a time.
    public func similarShots(
        threshold: Float = Similarity.seriesThreshold, gap: TimeInterval = Similarity.seriesGap
    ) async throws -> [SimilarShots.Group] {
        try await database.writer.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT media.fileId, media.timestamp, media.isFavorite, media.size, media.name, media.path, media.permissions,
                        similarity.quality, similarity.sketch
                    FROM similarity JOIN media ON media.fileId = similarity.fileId AND media.etag = similarity.etag
                    WHERE similarity.sketch IS NOT NULL AND media.kind = 'image' AND media.isLivePhotoVideo = 0
                        AND media.isArchived = 0
                    ORDER BY media.timestamp, media.fileId
                    """)
            var builder = SimilarShots.Builder(threshold: threshold, gap: gap)
            while let row = try rows.next() {
                let sketch: Data = row["sketch"]
                let path: String = row["path"]
                let quality: Double? = row["quality"]
                let permissions: String = row["permissions"]
                builder.add(
                    SimilarShots.Photo(
                        id: row["fileId"], date: Date(timeIntervalSince1970: row["timestamp"]), vector: Self.bytes(sketch).map(Float.init),
                        quality: quality.map { Float($0) }, isFavorite: row["isFavorite"], size: row["size"], name: row["name"],
                        directory: (path as NSString).deletingLastPathComponent,
                        canDelete: Permissions(rawValue: permissions).canDelete))
            }
            return builder.finish()
        }
    }
}
