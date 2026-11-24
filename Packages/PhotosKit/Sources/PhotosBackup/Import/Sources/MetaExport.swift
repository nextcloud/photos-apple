// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What Facebook's and Instagram's "Download your information" exports (JSON format) have in common: index files name
/// the media by a path relative to the export's root (`uri`), with `creation_timestamp` (when it was posted, Unix
/// seconds), a caption, and `media_metadata.photo_metadata.exif_data[]` (capture time, position), and the text is
/// UTF-8 whose bytes were written as `\u00XX` escapes.
///
/// The index files changed names and folders over the years (`photos_and_videos/album/0.json`,
/// `your_facebook_activity/posts/album/0.json`, `content/posts_1.json`, `your_instagram_activity/media/posts_1.json`),
/// but the media objects did not: the reader walks every index file below the export's known folders and takes every
/// object with a `uri` to a photo or video, with the post or album around it. Messages are left out: their photos are
/// mostly other people's.
enum MetaExport {
    enum Flavor {
        case facebook, instagram

        var source: ImportSourceKind { self == .facebook ? .facebook : .instagram }

        /// Folders only this service's export has; an index file below one of them belongs to it.
        var markers: Set<String> {
            switch self {
            case .facebook: ["your_facebook_activity", "your_activity_across_facebook", "photos_and_videos"]
            case .instagram: ["your_instagram_activity"]
            }
        }
    }

    /// Folders with conversations: their photos are not the user's to import.
    static let messageFolders: Set<String> = [
        "messages", "inbox", "message_requests", "archived_threads", "filtered_threads", "e2ee_cutover",
    ]
    /// Keys whose objects are not media of their own (a video's still, subtitles, other sizes of the same photo).
    static let skippedKeys: Set<String> = ["thumbnail", "subtitles", "media_variants", "dubbing_info", "music_genre"]

    /// The surroundings of a media object: the post or album it is in.
    struct Context {
        var caption: String?
        var posted: Int64?
        var album: String?
        var latitude: Double?
        var longitude: Double?
        var hidden = false
    }

    /// A media object found in an index file.
    struct Found {
        var uri: String
        var metadata: ImportMetadata
        var album: String?
        var deleted: Bool
    }

    /// Turns Meta's escaped UTF-8 (`CafÃ©`) back into text (`Café`). Text that is not of that kind stays as it is.
    static func fixText(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.unicodeScalars.count)
        var needsFix = false
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { return text }
            if scalar.value >= 0x80 { needsFix = true }
            bytes.append(UInt8(scalar.value))
        }
        guard needsFix, let fixed = String(validating: bytes, as: UTF8.self) else { return text }
        return fixed
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String).map(fixText)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// A Unix time that can be a capture or posting time (Facebook writes nonsense such as `-62169958800` for unknown ones).
    static func timestamp(_ value: Any?) -> Int64? {
        guard let seconds = number(value), seconds > 86_400, seconds < Date().timeIntervalSince1970 + 86_400 * 2 else { return nil }
        return Int64(seconds)
    }

    /// EXIF's `2023:10:07 16:52:20`, local time without an offset (Instagram's `date_time_original`).
    static func exifDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func validPosition(_ latitude: Double?, _ longitude: Double?) -> (Double, Double)? {
        guard let latitude, let longitude, !(latitude == 0 && longitude == 0), abs(latitude) <= 90, abs(longitude) <= 180 else {
            return nil
        }
        return (latitude, longitude)
    }

    /// The details of one media object: `exif_data` elements are merged (Instagram splits position and camera data),
    /// the capture time wins over the posting time.
    static func metadata(of object: [String: Any], context: Context, flavor: Flavor) -> ImportMetadata {
        var metadata = ImportMetadata()
        var exif: [String: Any] = [:]
        if let media = object["media_metadata"] as? [String: Any] {
            for key in ["photo_metadata", "video_metadata"] {
                guard let part = media[key] as? [String: Any] else { continue }
                if let elements = part["exif_data"] as? [[String: Any]] {
                    for element in elements { exif.merge(element) { first, _ in first } }
                }
                // 2018–2019 exports: the values directly in `photo_metadata`.
                exif.merge(part.filter { $0.key != "exif_data" }) { first, _ in first }
            }
        }
        if let taken = timestamp(exif["taken_timestamp"]) {
            metadata.takenAt = Date(timeIntervalSince1970: TimeInterval(taken))
        } else if let date = exifDate(exif["date_time_original"]) {
            metadata.takenAt = date
        } else if let posted = timestamp(object["creation_timestamp"]) ?? context.posted {
            metadata.takenAt = Date(timeIntervalSince1970: TimeInterval(posted))
            metadata.timeSource = .posted
        }
        if let (latitude, longitude) = validPosition(number(exif["latitude"]), number(exif["longitude"]))
            ?? validPosition(context.latitude, context.longitude)
        {
            metadata.latitude = latitude
            metadata.longitude = longitude
        }
        switch flavor {
        case .facebook:
            // A photo's `title` is the album's name, not a caption.
            metadata.caption = string(object["description"]) ?? context.caption
        case .instagram:
            // A post with several photos has its caption on the post, a single photo on itself.
            metadata.caption = context.caption ?? string(object["title"])
        }
        metadata.hidden = context.hidden
        if let width = number(exif["original_width"]), let height = number(exif["original_height"]), width > 0, height > 0 {
            metadata.originalWidth = Int(width)
            metadata.originalHeight = Int(height)
        }
        return metadata
    }

    /// The place a Facebook post was checked in at (`attachments[].data[].place.coordinate`).
    static func place(of post: [String: Any]) -> (Double, Double)? {
        for attachment in post["attachments"] as? [[String: Any]] ?? [] {
            for data in attachment["data"] as? [[String: Any]] ?? [] {
                if let place = data["place"] as? [String: Any], let coordinate = place["coordinate"] as? [String: Any],
                    let position = validPosition(number(coordinate["latitude"]), number(coordinate["longitude"]))
                {
                    return position
                }
            }
        }
        return nil
    }

    /// Every `uri` below a value (the files of a video's still or subtitles: part of the export, not photos of their own).
    static func references(in value: Any, into result: inout [String]) {
        if let array = value as? [Any] {
            for element in array { references(in: element, into: &result) }
        } else if let object = value as? [String: Any] {
            if let uri = object["uri"] as? String { result.append(uri) }
            for child in object.values { references(in: child, into: &result) }
        }
    }

    /// Walks an index file and collects its media objects; `ignored` gets the files that belong to them without being
    /// media of their own.
    static func walk(
        _ value: Any, context: Context, flavor: Flavor, deleted: Bool, into found: inout [Found], ignored: inout [String]
    ) {
        if let array = value as? [Any] {
            for element in array { walk(element, context: context, flavor: flavor, deleted: deleted, into: &found, ignored: &ignored) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        if let uri = object["uri"] as? String, ExportFiles.kind(of: uri) != nil {
            found.append(
                Found(uri: uri, metadata: metadata(of: object, context: context, flavor: flavor), album: context.album, deleted: deleted))
            for key in skippedKeys { if let child = object[key] { references(in: child, into: &ignored) } }
            return
        }
        var context = context
        // A Facebook post: its text and place; an Instagram post with several photos: its caption and time.
        if let data = object["data"] as? [[String: Any]], let text = data.lazy.compactMap({ string($0["post"]) }).first {
            context.caption = text
        }
        if object["media"] is [Any] {
            if let title = string(object["title"]) { context.caption = title }
        }
        if let posted = timestamp(object["creation_timestamp"]) ?? timestamp(object["timestamp"]) { context.posted = posted }
        if let (latitude, longitude) = place(of: object) {
            context.latitude = latitude
            context.longitude = longitude
        }
        for (key, child) in object {
            if skippedKeys.contains(key) {
                references(in: child, into: &ignored)
            } else {
                walk(child, context: context, flavor: flavor, deleted: deleted, into: &found, ignored: &ignored)
            }
        }
    }

    /// Whether a path lies below one of the flavour's marker folders, and the export's root (what comes before it).
    static func root(of path: String, flavor: Flavor) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(where: { flavor.markers.contains($0.lowercased()) }) else { return nil }
        return components[..<index].joined(separator: "/")
    }

    static func isInMessages(_ path: String) -> Bool {
        path.split(separator: "/").contains { messageFolders.contains($0.lowercased()) }
    }

    /// A conversation folder of a Meta export (`messages/inbox/<thread>/photos`), recognised outside the export's own
    /// folders too (the 2021–2022 Instagram export has none).
    static func isConversation(_ path: String) -> Bool {
        let components = Set(path.lowercased().split(separator: "/").map(String.init))
        return components.contains("messages") && !components.isDisjoint(with: messageFolders.subtracting(["messages"]))
    }

    /// Reads the index files of one flavour, given which of them it is responsible for and how each is labelled.
    ///
    /// - Parameter describe: for an index file's path below the root, the album its photos go to, whether they are deleted
    ///   or hidden, or nil when it is not an index of the user's own media.
    static func read(
        _ files: ExportFiles, unclaimed: [Int], flavor: Flavor, roots: Set<String>,
        describe: (String, [String: Any]?) -> (album: String?, deleted: Bool, hidden: Bool)?
    ) throws -> ImportFindings {
        var found = ImportFindings()
        guard !roots.isEmpty else { return found }
        func belongs(_ path: String) -> String? {
            for root in roots where root.isEmpty || path.hasPrefix(root + "/") {
                return root.isEmpty ? path : String(path.dropFirst(root.count + 1))
            }
            return nil
        }
        var objects: [Found] = []
        var ignored: [String] = []
        let unclaimedSet = Set(unclaimed)
        for position in unclaimed {
            try Task.checkCancellation()
            let file = files.files[position]
            guard let relative = belongs(file.path), file.pathExtension == "json", !isInMessages(relative) else { continue }
            guard file.size <= 64 << 20 else { continue }
            guard let data = try? files.data(of: file, limit: 64 << 20), let json = try? JSONSerialization.jsonObject(with: data) else {
                found.claimed.insert(position)
                found.skip(.unreadableIndex, file.name)
                continue
            }
            guard let label = describe(relative, json as? [String: Any]) else { continue }
            found.claimed.insert(position)
            var context = Context()
            context.album = label.album
            context.hidden = label.hidden
            walk(json, context: context, flavor: flavor, deleted: label.deleted, into: &objects, ignored: &ignored)
        }
        for uri in ignored {
            if let position = files.file(forReference: uri), unclaimedSet.contains(position) { found.claimed.insert(position) }
        }
        var index: [String: Int] = [:]
        var used = Set<Int>()
        for object in objects {
            guard let position = files.file(forReference: object.uri), unclaimedSet.contains(position) || used.contains(position) else {
                if files.file(forReference: object.uri) == nil, !object.uri.hasPrefix("http") {
                    found.skip(object.deleted ? .deleted : .missingFile, (object.uri as NSString).lastPathComponent)
                }
                continue
            }
            let file = files.files[position]
            found.claimed.insert(position)
            if object.deleted {
                if used.insert(position).inserted { found.skip(.deleted, file.name) }
                continue
            }
            used.insert(position)
            let id = ImportItem.key(source: flavor.source, name: file.path, size: file.size, takenAt: nil)
            if let album = object.album { found.addAlbum(album, source: flavor.source) }
            if let existing = index[id] {
                // The same file named twice (an album's cover, a post that shows an album photo): one item, every album.
                if let album = object.album, !found.items[existing].albums.contains(album) { found.items[existing].albums.append(album) }
                found.items[existing].metadata.merge(object.metadata)
                continue
            }
            found.add(
                ImportItem(
                    id: id, origin: .file(file), name: file.name, size: file.size, kind: ExportFiles.kind(of: file.name) ?? .image,
                    source: flavor.source, metadata: object.metadata, albums: object.album.map { [$0] } ?? []),
                index: &index)
        }
        // The rest below the export's folders: photos in messages are not the user's own; others (a media folder no
        // index names) are imported without details.
        for position in unclaimed where !found.claimed.contains(position) {
            let file = files.files[position]
            // Only below the service's own folders: an export at the top of a ZIP has the root "", and other exports
            // chosen with it must stay alone.
            guard let relative = belongs(file.path), root(of: file.path, flavor: flavor) != nil else { continue }
            guard let kind = ExportFiles.kind(of: file.name) else { continue }
            found.claimed.insert(position)
            if isInMessages(relative) {
                found.skip(.messages, file.name)
                continue
            }
            found.withoutDetails += 1
            found.add(
                ImportItem(
                    id: ImportItem.key(source: flavor.source, name: file.path, size: file.size, takenAt: nil), origin: .file(file),
                    name: file.name, size: file.size, kind: kind, source: flavor.source),
                index: &index)
        }
        return found
    }
}

/// Facebook's "Download your information" in JSON format: albums (`posts/album/<n>.json`, named), posts with photos and
/// videos (caption: the photo's description or the post's text; place: the post's check-in), uncategorized photos,
/// videos, stories. The posting time is used where the export kept no capture time.
enum FacebookExport: ExportAdapter {
    static let source = ImportSourceKind.facebook

    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings {
        let flavor = MetaExport.Flavor.facebook
        // An export's root: the folder holding `your_facebook_activity` (or the older folders).
        let roots = Set(
            unclaimed.compactMap { position -> String? in
                let file = files.files[position]
                guard file.pathExtension == "json" else { return nil }
                return MetaExport.root(of: file.path, flavor: flavor)
            })
        return try MetaExport.read(files, unclaimed: unclaimed, flavor: flavor, roots: roots) { path, object in
            describe(path, object)
        }
    }

    static func describe(_ path: String, _ object: [String: Any]?) -> (album: String?, deleted: Bool, hidden: Bool)? {
        let components = path.lowercased().split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        let folder = components.dropLast().last ?? ""
        if folder == "album" {
            return (MetaExport.string(object?["name"]), false, false)
        }
        if name.hasPrefix("trash") || name.hasPrefix("recently_deleted") { return (nil, true, false) }
        if name.hasPrefix("archive") { return (nil, false, true) }
        // Posts, uncategorized photos, videos, stories, profile and cover photos, group posts: the user's own media.
        let ownMedia = [
            "your_posts", "your_uncategorized_photos", "your_videos", "archived_stories", "your_stories", "profile_", "your_group",
        ]
        if ownMedia.contains(where: { name.hasPrefix($0) }) || components.contains("posts") || components.contains("stories") {
            return (nil, false, false)
        }
        return nil
    }
}

/// Instagram's "Download your information" in JSON format: posts (`posts_1.json`, caption on the post when it has several
/// photos), stories, reels, profile pictures, archived posts (to the archive), recently deleted (left out), and the
/// 2018–2020 `media.json` (`photos`/`videos`/`stories`/`profile` with `taken_at` and `caption`).
enum InstagramExport: ExportAdapter {
    static let source = ImportSourceKind.instagram

    /// Album names for the kinds of media Instagram keeps apart. Not translated: the albums are on the server and shared
    /// by every device, like the service's own words.
    static let storiesAlbum = "Instagram Stories"
    static let reelsAlbum = "Instagram Reels"
    static let profileAlbum = "Instagram Profile Pictures"

    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings {
        let flavor = MetaExport.Flavor.instagram
        var roots = Set<String>()
        var legacy: [Int] = []
        for position in unclaimed {
            let file = files.files[position]
            guard file.pathExtension == "json" else { continue }
            if let root = MetaExport.root(of: file.path, flavor: flavor) {
                roots.insert(root)
            } else if file.name.lowercased().wholeMatch(of: /media(-\d+)?\.json/) != nil {
                legacy.append(position)
            } else if file.directory.lowercased().hasSuffix("content"), file.name.lowercased().hasPrefix("posts_") {
                // 2021–2022: `content/posts_1.json` at the root, no `your_instagram_activity`.
                let directory = file.directory
                roots.insert((directory as NSString).deletingLastPathComponent)
            }
        }
        var found = try MetaExport.read(files, unclaimed: unclaimed, flavor: flavor, roots: roots) { path, _ in describe(path) }
        if !legacy.isEmpty { try readLegacy(files, unclaimed: unclaimed, indexes: legacy, into: &found) }
        return found
    }

    static func describe(_ path: String) -> (album: String?, deleted: Bool, hidden: Bool)? {
        let components = path.lowercased().split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        guard components.contains("content") || components.contains("media") || name.hasPrefix("posts_") else { return nil }
        if name.hasPrefix("recently_deleted") { return (nil, true, false) }
        if name.hasPrefix("stories") { return (storiesAlbum, false, false) }
        if name.hasPrefix("reels") || name.hasPrefix("igtv") { return (reelsAlbum, false, false) }
        if name.hasPrefix("profile_photos") { return (profileAlbum, false, false) }
        if name.hasPrefix("archived_posts") { return (nil, false, true) }
        if name.hasPrefix("posts_") || name.hasPrefix("other_content") { return (nil, false, false) }
        return nil
    }

    /// The 2018–2020 export: `media.json` (or `media-1.json`…) next to `photos/`, `videos/`, `stories/`, `profile/`.
    static func readLegacy(_ files: ExportFiles, unclaimed: [Int], indexes: [Int], into found: inout ImportFindings) throws {
        let formatter = ISO8601DateFormatter()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "UTC")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var index: [String: Int] = [:]
        for (offset, item) in found.items.enumerated() { index[item.id] = offset }
        let available = Set(unclaimed).subtracting(found.claimed)
        for position in indexes {
            let file = files.files[position]
            guard let data = try? files.data(of: file, limit: 64 << 20),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                found.skip(.unreadableIndex, file.name)
                continue
            }
            found.claimed.insert(position)
            let root = file.directory
            for (key, album) in [("photos", nil), ("videos", nil), ("stories", storiesAlbum), ("profile", profileAlbum)]
                as [(String, String?)]
            {
                for entry in object[key] as? [[String: Any]] ?? [] {
                    guard let path = entry["path"] as? String, ExportFiles.kind(of: path) != nil else { continue }
                    let reference = root.isEmpty ? path : root + "/" + path
                    guard let media = files.file(forReference: reference), available.contains(media) else {
                        if files.file(forReference: reference) == nil { found.skip(.missingFile, (path as NSString).lastPathComponent) }
                        continue
                    }
                    found.claimed.insert(media)
                    let mediaFile = files.files[media]
                    var metadata = ImportMetadata()
                    if let text = entry["taken_at"] as? String, let date = formatter.date(from: text) ?? local.date(from: text) {
                        metadata.takenAt = date
                        metadata.timeSource = .posted
                    }
                    metadata.caption = MetaExport.string(entry["caption"])
                    if let album { found.addAlbum(album, source: source) }
                    found.add(
                        ImportItem(
                            id: ImportItem.key(source: source, name: mediaFile.path, size: mediaFile.size, takenAt: nil),
                            origin: .file(mediaFile), name: mediaFile.name, size: mediaFile.size,
                            kind: ExportFiles.kind(of: mediaFile.name) ?? .image, source: source, metadata: metadata,
                            albums: album.map { [$0] } ?? []),
                        index: &index)
                }
            }
        }
    }
}
