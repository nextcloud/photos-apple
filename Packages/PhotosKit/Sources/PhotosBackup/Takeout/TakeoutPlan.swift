// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhotosModel

/// The files of a Google Takeout export: an unpacked folder, one or more of its ZIP parts, or a folder holding them.
public struct TakeoutSource: Sendable {
    /// One file of the export.
    public struct File: Hashable, Sendable {
        /// Path below the export's root (`Google Photos/Trip/IMG_1.jpg`), the same whichever ZIP part holds it.
        public var path: String
        public var size: UInt64
        /// Index into `archives` for a file inside a ZIP part.
        var archive: Int?
        var entry: ZipReader.Entry?
        /// Location on disk for a file of an unpacked export.
        var url: URL?

        public var name: String { (path as NSString).lastPathComponent }
        public var directory: String { (path as NSString).deletingLastPathComponent }
    }

    public let archives: [ZipReader]
    public let files: [File]

    /// Opens what the user picked: folders (searched for files and ZIP parts) and ZIP files.
    public static func open(_ urls: [URL]) throws -> TakeoutSource {
        var archives: [ZipReader] = []
        var files: [File] = []
        func addZip(_ url: URL) throws {
            let reader = try ZipReader(url: url)
            let index = archives.count
            archives.append(reader)
            for entry in reader.entries where !entry.isDirectory {
                files.append(File(path: relativePath(entry.path), size: entry.size, archive: index, entry: entry))
            }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                try addZip(url)
                continue
            }
            let base = url.standardizedFileURL.path
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                if file.pathExtension.lowercased() == "zip" {
                    try addZip(file)
                    continue
                }
                var relative = file.standardizedFileURL.path
                if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
                files.append(
                    File(
                        path: relativePath((url.lastPathComponent as NSString).appendingPathComponent(relative)),
                        size: UInt64(values?.fileSize ?? 0), url: file))
            }
        }
        return TakeoutSource(archives: archives, files: files)
    }

    /// Strips everything up to `Takeout/` so the parts of a split export agree on the paths.
    static func relativePath(_ path: String) -> String {
        let clean = path.split(separator: "/").map(String.init)
        if let index = clean.firstIndex(where: { $0 == "Takeout" }) { return clean[(index + 1)...].joined(separator: "/") }
        return clean.joined(separator: "/")
    }

    public func data(of file: File, limit: UInt64 = 4 << 20) throws -> Data {
        if let archive = file.archive, let entry = file.entry { return try archives[archive].data(of: entry, limit: limit) }
        guard let url = file.url, file.size <= limit else { throw ZipReader.ZipError.corrupt(file.path) }
        return try Data(contentsOf: url)
    }

    /// A file on disk with the content: the export's own file, or one unpacked into `directory` (the caller removes it).
    public func materialize(_ file: File, in directory: URL) throws -> (url: URL, isTemporary: Bool) {
        if let url = file.url { return (url, false) }
        guard let archive = file.archive, let entry = file.entry else { throw ZipReader.ZipError.corrupt(file.path) }
        let target = directory.appending(path: UUID().uuidString + "-" + file.name)
        try archives[archive].extract(entry, to: target)
        return (target, true)
    }
}

/// One photo or video to import, with what its sidecar says and the albums it is in.
public struct TakeoutItem: Hashable, Sendable, Identifiable {
    /// Stable across runs of the same export (name, size and capture time), for resuming.
    public var id: String
    public var file: TakeoutSource.File
    public var kind: MediaKind
    public var metadata: TakeoutMetadata?
    /// Album titles, from the album folders the file is in.
    public var albums: [String]

    public var name: String { file.name }
    public var takenAt: Date? { metadata?.takenAt }
}

/// What an export holds, ready to import.
public struct TakeoutPlan: Sendable {
    public var items: [TakeoutItem]
    /// Album titles in the order they first appear.
    public var albums: [String]
    /// Photos and videos without a sidecar (they keep the date in their own metadata).
    public var withoutSidecar: Int
    /// Copies of the same file in a year folder and album folders, imported once.
    public var duplicatesInExport: Int
    /// Files in the trash folder of the export, not imported.
    public var skippedTrash: Int
    /// Identifies the export for the resume journal.
    public var key: String

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.file.size } }

    /// Folders that are not albums although they are not year folders either.
    static let plainFolders: Set<String> = [
        "archive", "archiv", "archives", "archivio", "archivo", "archief", "failed videos",
    ]
    /// The folder of the export that holds the others.
    static let rootFolders: Set<String> = ["google photos", "google fotos", "google foto", "takeout"]
    /// The export's trash; deleted photos are not imported.
    static let trashFolders: Set<String> = [
        "trash", "bin", "papierkorb", "corbeille", "papelera", "cestino", "prullenbak", "kosz", "lixeira", "lixo",
    ]

    /// "Photos from 2019", "Fotos von 2019", "Photos de 2019": words and a year, nothing else.
    static func isYearFolder(_ name: String) -> Bool {
        name.wholeMatch(of: /\D*(19|20)\d{2}/) != nil
    }

    /// Builds the plan. Reads every sidecar and album description (small JSON files), nothing else.
    public static func build(_ source: TakeoutSource) throws -> TakeoutPlan {
        let byFolder = Dictionary(grouping: source.files, by: \.directory)
        var items: [String: TakeoutItem] = [:]
        var order: [String] = []
        var albums: [String] = []
        var withoutSidecar = 0
        var duplicates = 0
        var skippedTrash = 0
        for folder in byFolder.keys.sorted() {
            try Task.checkCancellation()
            let files = byFolder[folder] ?? []
            let folderName = (folder as NSString).lastPathComponent
            let media = files.filter { kind(of: $0.name) != nil }
            if trashFolders.contains(folderName.lowercased()) {
                skippedTrash += media.count
                continue
            }
            guard !media.isEmpty else { continue }
            let jsons = files.filter { TakeoutSidecars.isSidecarName($0.name) && $0.size <= TakeoutSidecars.maxSidecarSize }
            let index = TakeoutSidecars.index(jsons.map(\.name))
            let jsonByName = Dictionary(jsons.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            // An album folder: one that describes itself with a title, or any other folder that is not a year folder, the
            // export's root or a special folder.
            var album: String?
            let lowercased = folderName.lowercased()
            let isPlain = isYearFolder(folderName) || plainFolders.contains(lowercased) || rootFolders.contains(lowercased)
            let used = Set(media.compactMap { TakeoutSidecars.sidecar(for: $0.name, in: index) })
            for json in jsons where !isPlain && !used.contains(json.name) {
                if let data = try? source.data(of: json), TakeoutSidecars.parse(data)?.takenAt == nil,
                    let title = TakeoutSidecars.albumTitle(data)
                {
                    album = title
                    break
                }
            }
            if album == nil, !folder.isEmpty, !isPlain { album = folderName }
            if let album, !albums.contains(album) { albums.append(album) }
            for file in media.sorted(by: { $0.name < $1.name }) {
                var metadata: TakeoutMetadata?
                if let sidecarName = TakeoutSidecars.sidecar(for: file.name, in: index), let sidecar = jsonByName[sidecarName] {
                    metadata = (try? source.data(of: sidecar)).flatMap(TakeoutSidecars.parse)
                }
                let key = itemKey(name: file.name, size: file.size, takenAt: metadata?.takenAt)
                if var existing = items[key] {
                    duplicates += 1
                    if let album, !existing.albums.contains(album) { existing.albums.append(album) }
                    if existing.metadata == nil { existing.metadata = metadata }
                    items[key] = existing
                    continue
                }
                if metadata == nil { withoutSidecar += 1 }
                items[key] = TakeoutItem(
                    id: key, file: file, kind: kind(of: file.name) ?? .image, metadata: metadata, albums: album.map { [$0] } ?? [])
                order.append(key)
            }
        }
        let sorted = order.compactMap { items[$0] }.sorted {
            ($0.takenAt ?? .distantPast, $0.id) < ($1.takenAt ?? .distantPast, $1.id)
        }
        let digest = SHA256.hash(data: Data(sorted.map(\.id).joined(separator: "\n").utf8))
        return TakeoutPlan(
            items: sorted, albums: albums, withoutSidecar: withoutSidecar, duplicatesInExport: duplicates, skippedTrash: skippedTrash,
            key: digest.prefix(12).map { String(format: "%02x", $0) }.joined())
    }

    static func itemKey(name: String, size: UInt64, takenAt: Date?) -> String {
        "\(name.lowercased())|\(size)|\(takenAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "-")"
    }

    /// Photos and videos the server's Photos app shows; other files of the export (HTML, JSON) are left out.
    static func kind(of name: String) -> MediaKind? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        let mime = MimeTypes.mimeType(forExtension: ext)
        return mime == "application/octet-stream" ? nil : MimeTypes.kind(of: mime)
    }
}
