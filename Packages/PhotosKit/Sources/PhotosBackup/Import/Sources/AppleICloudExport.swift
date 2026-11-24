// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Apple's data export of iCloud Photos (privacy.apple.com, "Request a copy of your data"): ZIP parts named
/// `iCloud Photos Part 1 of 72` (translated: `iCloud Fotos Teil 1 von 37`), each with `Photos/` and its own
/// `Photo Details.csv` (`-1`, `-2`… when long), `Recently Deleted/`, and in one of the parts `Albums/` and `Memories/`
/// with one CSV per album listing file names. Shared albums come as folders (`iCloud Shared Albums/My Albums/<album>`),
/// sometimes in ZIP files inside a part, without any details.
///
/// `Photo Details.csv`: `imgName,fileChecksum,favorite,hidden,deleted,originalCreationDate,viewCount,importDate`, flags
/// `yes`/`no`, dates `Tuesday November 19,2024 8:31 AM GMT` (UTC, to the minute). Rows belong to the files of their
/// own folder: the camera's counter repeats, so a name alone does not identify a photo across parts.
enum AppleICloudExport: ExportAdapter {
    static let source = ImportSourceKind.iCloudPhotos

    /// Album lists that are not albums of their own (favourites are imported as favourites).
    static let favoriteLists: Set<String> = ["favorites", "favourites", "favoriten", "favoris", "favoritos", "preferiti", "favorieten"]

    struct Row {
        var name: String
        var favorite: Bool
        var hidden: Bool
        var deleted: Bool
        var created: Date?
    }

    /// A part's top folder: "iCloud Photos Part 1 of 72", "iCloud Fotos Teil 1 von 37", "iCloud-bilder Del 1 av 6".
    static func isPartFolder(_ name: String) -> Bool {
        name.lowercased().hasPrefix("icloud") && name.wholeMatch(of: /.*\D(\d+)\D+(\d+)/) != nil
    }

    static func isSharedAlbumsFolder(_ name: String) -> Bool {
        name.lowercased().hasPrefix("icloud shared albums")
    }

    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings {
        var found = ImportFindings()
        var detailsByFolder: [String: [Row]] = [:]
        var albumLists: [(title: String, names: [String])] = []
        var appleFolders = Set<String>()
        // The CSV files first: they say which folders are Apple's.
        for position in unclaimed {
            try Task.checkCancellation()
            let file = files.files[position]
            let components = file.path.split(separator: "/").map(String.init)
            let isApple = components.contains(where: isPartFolder) || components.contains(where: isSharedAlbumsFolder)
            guard file.pathExtension == "csv", file.size <= 64 << 20 else {
                if isApple { appleFolders.insert(file.directory) }
                continue
            }
            guard let data = try? files.data(of: file, limit: 64 << 20) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let rows = CSV.parse(text)
            guard let header = rows.first?.map({ $0.lowercased() }) else {
                if isApple { found.claimed.insert(position) }
                continue
            }
            let folderName = (file.directory as NSString).lastPathComponent.lowercased()
            if header.first == "imgname", let dateColumn = header.firstIndex(of: "originalcreationdate") {
                found.claimed.insert(position)
                appleFolders.insert(file.directory)
                detailsByFolder[file.directory, default: []] += rows.dropFirst().compactMap { row in
                    self.row(row, header: header, dateColumn: dateColumn)
                }
            } else if header.first == "imgname" || (isApple && header.count <= 2) {
                // `Shared Library Details.csv`, album and memory lists.
                found.claimed.insert(position)
                if folderName == "albums" {
                    let title = MetaExport.fixText((file.name as NSString).deletingPathExtension)
                    let names = rows.dropFirst().compactMap { $0.first?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    albumLists.append((title, names))
                }
            }
        }
        guard !appleFolders.isEmpty else { return found }
        // The media: every photo or video in an Apple folder, with its row of the details of that folder.
        var index: [String: Int] = [:]
        var byName: [String: [Int]] = [:]
        let unclaimedByFolder = Dictionary(grouping: unclaimed.filter { !found.claimed.contains($0) }, by: { files.files[$0].directory })
        for folder in unclaimedByFolder.keys.sorted() {
            let components = folder.split(separator: "/").map(String.init)
            let inPart = components.contains(where: isPartFolder) || components.contains(where: isSharedAlbumsFolder)
            guard appleFolders.contains(folder) || inPart else { continue }
            let positions = unclaimedByFolder[folder] ?? []
            let folderName = (folder as NSString).lastPathComponent
            let deletedFolder = folderName.lowercased() == "recently deleted"
            let sharedAlbum = components.contains(where: isSharedAlbumsFolder) ? folderName : nil
            var rows: [String: Row] = [:]
            for row in detailsByFolder[folder] ?? [] where rows[row.name.lowercased()] == nil { rows[row.name.lowercased()] = row }
            var matched = Set<String>()
            for position in positions.sorted(by: { files.files[$0].name < files.files[$1].name }) {
                let file = files.files[position]
                found.claimed.insert(position)
                guard let kind = ExportFiles.kind(of: file.name) else {
                    if !ExportFiles.documentExtensions.contains(file.pathExtension) { found.skip(.unsupportedType, file.name) }
                    continue
                }
                if deletedFolder {
                    found.skip(.deleted, file.name)
                    continue
                }
                let row = rowFor(file.name, in: rows)
                if let row { matched.insert(row.name.lowercased()) }
                if row?.deleted == true {
                    found.skip(.deleted, file.name)
                    continue
                }
                var metadata = ImportMetadata()
                if let row {
                    metadata.takenAt = row.created
                    metadata.timeSource = .captureMinute
                    metadata.favorite = row.favorite
                    metadata.hidden = row.hidden
                }
                if let sharedAlbum { found.addAlbum(sharedAlbum, source: source) }
                let item = ImportItem(
                    id: ImportItem.key(source: source, name: file.path, size: file.size, takenAt: nil), origin: .file(file),
                    name: file.name,
                    size: file.size, kind: kind, source: source, metadata: metadata, albums: sharedAlbum.map { [$0] } ?? [])
                if found.add(item, index: &index) {
                    if row == nil { found.withoutDetails += 1 }
                    byName[file.name.lowercased(), default: []].append(found.items.count - 1)
                }
            }
            // Rows without a file: with Advanced Data Protection on, the export lists the photos but leaves them out.
            for row in detailsByFolder[folder] ?? [] where !row.deleted && !matched.contains(row.name.lowercased()) {
                found.skip(.listedWithoutFile, row.name)
            }
        }
        // Rows of a details file whose folder has no media at all.
        for (folder, rows) in detailsByFolder where unclaimedByFolder[folder] == nil {
            for row in rows where !row.deleted { found.skip(.listedWithoutFile, row.name) }
        }
        // Albums: the lists name files, possibly of other parts.
        for list in albumLists {
            guard !favoriteLists.contains(list.title.lowercased()) else { continue }
            var any = false
            for name in list.names {
                for position in byName[name.lowercased()] ?? [] where !found.items[position].albums.contains(list.title) {
                    found.items[position].albums.append(list.title)
                    any = true
                }
            }
            if any { found.addAlbum(list.title, source: source) }
        }
        return found
    }

    /// The row of a file; a Live Photo's video renamed for a name clash (`IMG_0861-1.MOV`) may be listed under its first name.
    static func rowFor(_ name: String, in rows: [String: Row]) -> Row? {
        if let row = rows[name.lowercased()] { return row }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if let match = base.wholeMatch(of: /(.+)-\d/) { return rows["\(match.1).\(ext)".lowercased()] }
        return nil
    }

    static func row(_ fields: [String], header: [String], dateColumn: Int) -> Row? {
        guard let name = fields.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        func flag(_ column: String) -> Bool {
            guard let index = header.firstIndex(of: column), index < fields.count else { return false }
            return fields[index].lowercased() == "yes"
        }
        let created = dateColumn < fields.count ? date(fields[dateColumn]) : nil
        return Row(name: name, favorite: flag("favorite"), hidden: flag("hidden"), deleted: flag("deleted"), created: created)
    }

    /// `Tuesday November 19,2024 8:31 AM GMT`; with or without the weekday and the space after the comma.
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{202F}", with: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in [
            "EEEE MMMM d,yyyy h:mm a zzz", "EEEE MMMM d, yyyy h:mm a zzz", "MMMM d,yyyy h:mm a zzz", "EEEE MMMM d,yyyy H:mm zzz",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// A small CSV reader (RFC 4180: quoted fields with commas, doubled quotes and line breaks).
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            quoted = false
                            pending = following
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r": continue
            case "\n":
                row.append(field)
                field = ""
                if row != [""] { rows.append(row) }
                row = []
            case "\u{FEFF}" where field.isEmpty && row.isEmpty && rows.isEmpty: continue
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
