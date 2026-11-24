// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// Album titles in the full-text index (SPEC SR-3): a photo in the album "Hawaii 2024" is found by "hawaii", whether the
/// album is the user's own or shared with them. Only albums whose content was read are known to contain a photo
/// (`albumItem`); public links that were opened are not part of the user's library and are left out.
///
/// The index text is `SearchLabels.textSQL` plus the titles. Migration `v4-search-albums` replaces the triggers of
/// `v3-search-labels` (same names, so `SearchLabels.dropTriggersSQL` keeps dropping them) and adds the ones on `albumItem`
/// and `album`; `SearchLabels` stays as it was for its migration.
enum SearchAlbums {
    /// The titles of the albums a file is in.
    static func titlesSQL(_ row: String) -> String {
        """
        (SELECT group_concat(album.title, ' ') FROM albumItem JOIN album ON album.id = albumItem.albumId \
        WHERE albumItem.fileId = \(row).fileId AND album.kind IN ('own', 'shared'))
        """
    }

    /// The indexed text of a media row with its labels and album titles; `row` is `media`, `NEW` or `OLD`.
    static func textSQL(_ row: String) -> String {
        "concat_ws(' ', \(SearchLabels.textSQL(row)), \(titlesSQL(row)))"
    }

    /// Writes the index row of one file again (nothing when the file is not in `media`).
    static func refreshSQL(_ fileId: String) -> String {
        """
        DELETE FROM searchIndex WHERE rowid = \(fileId);
        INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media WHERE media.fileId = \(fileId);
        """
    }

    /// Writes the index rows of every file of an album again.
    static func refreshAlbumSQL(_ albumId: String) -> String {
        """
        DELETE FROM searchIndex WHERE rowid IN (SELECT fileId FROM albumItem WHERE albumId = \(albumId));
        INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media
            WHERE media.fileId IN (SELECT fileId FROM albumItem WHERE albumId = \(albumId));
        """
    }

    /// Every trigger of `SearchLabels.triggersSQL` with the album titles in the text, and the triggers on the album tables.
    /// Changing an album's content writes the index rows of the files that came or went; renaming an album (or another
    /// kind) writes those of its files. A deleted album takes its `albumItem` rows with it (foreign key), whose delete
    /// trigger writes the rows without the title.
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
        CREATE TRIGGER albumItem_search_insert AFTER INSERT ON albumItem BEGIN \(refreshSQL("NEW.fileId")) END;
        CREATE TRIGGER albumItem_search_delete AFTER DELETE ON albumItem BEGIN \(refreshSQL("OLD.fileId")) END;
        CREATE TRIGGER album_search_update AFTER UPDATE OF title, kind ON album
        WHEN OLD.title IS NOT NEW.title OR OLD.kind IS NOT NEW.kind
        BEGIN \(refreshAlbumSQL("NEW.id")) END;
        """

    /// Drops every trigger of `triggersSQL`.
    static let dropTriggersSQL = """
        \(SearchLabels.dropTriggersSQL);
        DROP TRIGGER IF EXISTS albumItem_search_insert;
        DROP TRIGGER IF EXISTS albumItem_search_delete;
        DROP TRIGGER IF EXISTS album_search_update
        """

    /// Migration `v4-search-albums`: the new triggers, and the index rows of the files that are in an album written
    /// again (the others have no album title, their text is unchanged).
    static func migrate(_ db: Database) throws {
        try db.execute(sql: dropTriggersSQL)
        try db.execute(sql: triggersSQL)
        try db.execute(
            sql: """
                DELETE FROM searchIndex WHERE rowid IN (SELECT DISTINCT fileId FROM albumItem);
                INSERT INTO searchIndex(rowid, text) SELECT media.fileId, \(textSQL("media")) FROM media
                    WHERE media.fileId IN (SELECT DISTINCT fileId FROM albumItem);
                """)
    }
}
