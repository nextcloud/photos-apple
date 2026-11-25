// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// Photo descriptions in the full-text index (SPEC §16.2): a photo described as "A dog running on a beach at sunset" is
/// found by "running" or "sunset", like its name and labels. Only descriptions of the photo's current version count.
///
/// The index text is `SearchAlbums.textSQL` plus the description. Migration `v6-search-descriptions` creates the table,
/// replaces the triggers of `v4-search-albums` (same names, so `SearchAlbums.dropTriggersSQL` keeps dropping them) and
/// adds the ones on `photoDescription`; `SearchAlbums` stays as it was for its migration. No index row changes in the
/// migration: there are no descriptions yet.
enum SearchDescriptions {
    /// The description of a file's current version.
    static func descriptionSQL(_ row: String) -> String {
        "(SELECT text FROM photoDescription WHERE photoDescription.fileId = \(row).fileId AND photoDescription.etag = \(row).etag)"
    }

    /// The indexed text of a media row with its labels, album titles and description; `row` is `media`, `NEW` or `OLD`.
    static func textSQL(_ row: String) -> String {
        "concat_ws(' ', \(SearchAlbums.textSQL(row)), \(descriptionSQL(row)))"
    }

    /// Writes the index row of one file again (nothing when the file is not in `media`).
    static func refreshSQL(_ fileId: String) -> String {
        """
        DELETE FROM searchIndex WHERE rowid = \(fileId);
        INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media WHERE media.fileId = \(fileId);
        """
    }

    static func refreshAlbumSQL(_ albumId: String) -> String {
        """
        DELETE FROM searchIndex WHERE rowid IN (SELECT fileId FROM albumItem WHERE albumId = \(albumId));
        INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media
            WHERE media.fileId IN (SELECT fileId FROM albumItem WHERE albumId = \(albumId));
        """
    }

    /// Every trigger of `SearchAlbums.triggersSQL` with the description in the text, the triggers on `photoDescription`,
    /// and the one that removes a deleted photo's description. A new version of a file (another ETag) has no
    /// description until it is described again, so the media trigger also fires on `etag`.
    static let triggersSQL = """
        CREATE TRIGGER media_search_insert AFTER INSERT ON media BEGIN
            INSERT INTO searchIndex(rowid, text) VALUES (NEW.fileId, \(textSQL("NEW")));
        END;
        CREATE TRIGGER media_search_update AFTER UPDATE OF name, path, place, placeCountry, caption, etag ON media
        WHEN OLD.name IS NOT NEW.name OR OLD.path IS NOT NEW.path OR OLD.place IS NOT NEW.place
            OR OLD.placeCountry IS NOT NEW.placeCountry OR OLD.caption IS NOT NEW.caption OR OLD.etag IS NOT NEW.etag
        BEGIN
            DELETE FROM searchIndex WHERE rowid = NEW.fileId;
            INSERT INTO searchIndex(rowid, text) VALUES (NEW.fileId, \(textSQL("NEW")));
        END;
        CREATE TRIGGER media_search_delete AFTER DELETE ON media BEGIN
            DELETE FROM searchIndex WHERE rowid = OLD.fileId;
        END;
        CREATE TRIGGER tagItem_search_insert AFTER INSERT ON tagItem BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER tagItem_search_delete AFTER DELETE ON tagItem BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER tag_search_rename AFTER UPDATE OF name ON tag WHEN OLD.name IS NOT NEW.name BEGIN
            DELETE FROM searchIndex WHERE rowid IN (SELECT fileId FROM tagItem WHERE tagId = NEW.id);
            INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media
                WHERE media.fileId IN (SELECT fileId FROM tagItem WHERE tagId = NEW.id);
        END;
        CREATE TRIGGER personItem_search_insert AFTER INSERT ON personItem BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER personItem_search_delete AFTER DELETE ON personItem BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER personItem_search_update AFTER UPDATE OF person ON personItem BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER visionLabel_search_insert AFTER INSERT ON visionLabel BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER visionLabel_search_update AFTER UPDATE OF labels ON visionLabel BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER visionLabel_search_delete AFTER DELETE ON visionLabel BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER albumItem_search_insert AFTER INSERT ON albumItem BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER albumItem_search_delete AFTER DELETE ON albumItem BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER album_search_update AFTER UPDATE OF title, kind ON album
        WHEN OLD.title IS NOT NEW.title OR OLD.kind IS NOT NEW.kind
        BEGIN \(refreshAlbumSQL("NEW.id")) END;
        CREATE TRIGGER photoDescription_search_insert AFTER INSERT ON photoDescription BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER photoDescription_search_update AFTER UPDATE OF text, etag ON photoDescription BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER photoDescription_search_delete AFTER DELETE ON photoDescription BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER media_description_delete AFTER DELETE ON media BEGIN
            DELETE FROM photoDescription WHERE fileId = OLD.fileId;
        END;
        """

    /// Drops every trigger of `triggersSQL`.
    static let dropTriggersSQL = """
        \(SearchAlbums.dropTriggersSQL);
        DROP TRIGGER IF EXISTS photoDescription_search_insert;
        DROP TRIGGER IF EXISTS photoDescription_search_update;
        DROP TRIGGER IF EXISTS photoDescription_search_delete;
        DROP TRIGGER IF EXISTS media_description_delete
        """

    /// Migration `v6-search-descriptions`.
    static func migrate(_ db: Database) throws {
        try db.create(table: "photoDescription") { t in
            t.primaryKey("fileId", .integer)
            // The version described; another ETag means another picture.
            t.column("etag", .text).notNull()
            // Nil: the photo could not be described (not tried again until its file changes).
            t.column("text", .text)
            // BCP 47 language of the text ("en", "de").
            t.column("language", .text)
            // `PhotoDescription.Source`.
            t.column("source", .text).notNull()
            t.column("describedAt", .double).notNull()
        }
        try db.execute(sql: dropTriggersSQL)
        try db.execute(sql: triggersSQL)
    }
}
