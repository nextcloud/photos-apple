// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// Labels in the full-text index (SPEC SR-3): the names of a file's system tags, of the people in it (Recognize) and the
/// labels this device recognised in its preview (`visionLabel`, never uploaded) are searched like its name and place, so
/// "dog" finds photos tagged "dog" without the server.
///
/// The index text of a file is computed from its `media` row and these tables. Triggers on every one of them keep it
/// current; migration `v3-search-labels` installs them in place of the triggers of `v2-large-library`, whose SQL
/// (`SearchIndex.textSQL`, `SearchIndex.triggersSQL`) stays as it was for that migration.
enum SearchLabels {
    /// The indexed text of a media row with its labels; `row` is `media`, `NEW` or `OLD`.
    static func textSQL(_ row: String) -> String {
        let folder = "nullif(rtrim(rtrim(\(row).path, replace(\(row).path, '/', '')), '/'), '')"
        let tags =
            "(SELECT group_concat(tag.name, ' ') FROM tagItem JOIN tag ON tag.id = tagItem.tagId WHERE tagItem.fileId = \(row).fileId)"
        // Unnamed Recognize clusters are numbers: nothing anyone searches for.
        let people =
            "(SELECT group_concat(person, ' ') FROM (SELECT DISTINCT person FROM personItem WHERE personItem.fileId = \(row).fileId AND person GLOB '*[^0-9]*'))"
        let vision = "(SELECT labels FROM visionLabel WHERE visionLabel.fileId = \(row).fileId)"
        return "concat_ws(' ', \(row).name, \(row).place, \(row).placeCountry, \(row).caption, \(folder), \(tags), \(people), \(vision))"
    }

    /// Writes the index row of one file again (nothing when the file is not in `media`).
    static func refreshSQL(_ fileId: String) -> String {
        """
        DELETE FROM searchIndex WHERE rowid = \(fileId);
        INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media WHERE media.fileId = \(fileId);
        """
    }

    /// The triggers on `media` (same names as those of v2, so `SearchIndex.dropSQL` drops them) and on the label tables.
    static let triggersSQL = """
        CREATE TRIGGER media_search_insert AFTER INSERT ON media BEGIN
            INSERT INTO searchIndex(rowid, text) VALUES (NEW.fileId, \(textSQL("NEW")));
        END;
        CREATE TRIGGER media_search_update AFTER UPDATE OF name, path, place, placeCountry, caption ON media
        WHEN OLD.name IS NOT NEW.name OR OLD.path IS NOT NEW.path OR OLD.place IS NOT NEW.place
            OR OLD.placeCountry IS NOT NEW.placeCountry OR OLD.caption IS NOT NEW.caption
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
        """

    /// Drops every trigger of `triggersSQL` (the media ones too).
    static let dropTriggersSQL = """
        DROP TRIGGER IF EXISTS media_search_insert;
        DROP TRIGGER IF EXISTS media_search_update;
        DROP TRIGGER IF EXISTS media_search_delete;
        DROP TRIGGER IF EXISTS tagItem_search_insert;
        DROP TRIGGER IF EXISTS tagItem_search_delete;
        DROP TRIGGER IF EXISTS tag_search_rename;
        DROP TRIGGER IF EXISTS personItem_search_insert;
        DROP TRIGGER IF EXISTS personItem_search_delete;
        DROP TRIGGER IF EXISTS personItem_search_update;
        DROP TRIGGER IF EXISTS visionLabel_search_insert;
        DROP TRIGGER IF EXISTS visionLabel_search_update;
        DROP TRIGGER IF EXISTS visionLabel_search_delete
        """

    /// Migration `v3-search-labels`. Additive: the label tables were never written before this version (tags and people
    /// were only read from the server), so the existing index text is already right and is not rebuilt.
    static func migrate(_ db: Database) throws {
        try db.create(table: "visionLabel") { t in
            t.primaryKey("fileId", .integer)
            // The preview the labels were computed from; another ETag means another picture.
            t.column("etag", .text).notNull()
            // Space-separated, lower case, English (the classifier's identifiers).
            t.column("labels", .text).notNull()
            t.column("labeledAt", .double).notNull()
        }
        try db.execute(sql: dropTriggersSQL)
        try db.execute(sql: triggersSQL)
        // Membership lookups by file: index text and the tag sheet of a selection.
        try db.create(index: "tagItem_file", on: "tagItem", columns: ["fileId"])
    }
}
