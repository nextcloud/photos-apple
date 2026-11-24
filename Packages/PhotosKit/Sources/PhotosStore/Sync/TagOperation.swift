// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel
import PhotosNetworking

/// Adds a system tag to a file or removes it (SPEC §7.10), as an outbox operation (`PendingOperation.tag`).
///
/// Everything the outbox needs to know about it is here, so the outbox itself only forwards to it.
public struct TagChange: Codable, Sendable, Hashable {
    public var fileId: FileID
    public var tagId: Int
    /// The tag's name when the change was made: shown in the index (search) before the next tag refresh.
    public var tagName: String
    /// true adds the tag, false removes it.
    public var assign: Bool

    public init(fileId: FileID, tagId: Int, tagName: String, assign: Bool) {
        self.fileId = fileId
        self.tagId = tagId
        self.tagName = tagName
        self.assign = assign
    }

    /// Runs on the server. Tags are addressed by file id, so a moved file needs no lookup; adding a tag a file already
    /// has (409) and removing one it does not have (404) count as done (`PhotosAPI.assignTag`, `unassignTag`).
    func execute(api: PhotosAPI) async throws {
        if assign {
            try await api.assignTag(SystemTag(id: tagId, name: tagName), to: fileId)
        } else {
            try await api.unassignTag(tagId, from: fileId)
        }
    }

    /// The optimistic local effect: the membership (and so the search index) changes at once. The tag's stored count is
    /// marked unknown, so the next tag refresh reads its files from the server again, whether this operation succeeds
    /// or fails for good.
    func applyLocally(db: Database) throws {
        if assign {
            try db.execute(
                sql: "INSERT OR IGNORE INTO tag(id, name, itemCount) VALUES (?, ?, -1)", arguments: [tagId, tagName])
            try db.execute(sql: "INSERT OR IGNORE INTO tagItem(tagId, fileId) VALUES (?, ?)", arguments: [tagId, fileId])
        } else {
            try db.execute(sql: "DELETE FROM tagItem WHERE tagId = ? AND fileId = ?", arguments: [tagId, fileId])
        }
        try db.execute(sql: "UPDATE tag SET itemCount = -1 WHERE id = ?", arguments: [tagId])
    }
}
