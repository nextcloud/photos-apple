// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The files of one or more exports the user picked: unpacked folders, ZIP parts (read in place, never unpacked as a
/// whole), or folders holding them. Exports from several services can be picked together; the source adapters
/// (`ImportPlanner`) tell them apart by their files.
public struct ExportFiles: Sendable {
    /// One file of an export.
    public struct File: Hashable, Sendable {
        /// Path below the export's root (`Google Photos/Trip/IMG_1.jpg`), the same whichever ZIP part holds it.
        public var path: String
        public var size: UInt64
        /// Index into `archives` for a file inside a ZIP part.
        var archive: Int?
        var entry: ZipReader.Entry?
        /// Location on disk for a file of an unpacked export.
        var url: URL?

        public init(path: String, size: UInt64) {
            self.path = path
            self.size = size
        }

        init(path: String, size: UInt64, archive: Int? = nil, entry: ZipReader.Entry? = nil, url: URL? = nil) {
            self.path = path
            self.size = size
            self.archive = archive
            self.entry = entry
            self.url = url
        }

        public var name: String { (path as NSString).lastPathComponent }
        public var directory: String { (path as NSString).deletingLastPathComponent }
        /// The lowercased extension.
        public var pathExtension: String { (name as NSString).pathExtension.lowercased() }
    }

    public let archives: [ZipReader]
    public let files: [File]
    /// ZIP files found inside ZIP parts (Apple puts its shared albums into one), unpacked here; removed by `cleanUp()`.
    public let unpackedDirectory: URL?

    /// Files by their last path component, lowercased (for resolving the paths export indexes refer to).
    private let byName: [String: [Int]]

    init(archives: [ZipReader] = [], files: [File], unpackedDirectory: URL? = nil) {
        self.archives = archives
        self.files = files
        self.unpackedDirectory = unpackedDirectory
        var byName: [String: [Int]] = [:]
        for (index, file) in files.enumerated() { byName[file.name.lowercased(), default: []].append(index) }
        self.byName = byName
    }

    /// ZIPs inside ZIPs bigger than this are not unpacked (they would need that much space twice).
    static let maxNestedZip: UInt64 = 8 << 30

    /// Opens what the user picked: folders (searched for files and ZIP parts) and ZIP files.
    ///
    /// - Parameter scratch: where ZIP files found inside ZIP parts are unpacked (one level deep); without it they are
    ///   left out.
    public static func open(_ urls: [URL], scratch: URL? = nil) throws -> ExportFiles {
        var archives: [ZipReader] = []
        var files: [File] = []
        var nested: [(archive: Int, entry: ZipReader.Entry)] = []
        func addZip(_ url: URL, prefix: String = "") throws {
            let reader = try ZipReader(url: url)
            let index = archives.count
            archives.append(reader)
            for entry in reader.entries where !entry.isDirectory {
                if entry.path.lowercased().hasSuffix(".zip") {
                    if prefix.isEmpty { nested.append((index, entry)) }
                    continue
                }
                files.append(File(path: relativePath(prefix + entry.path), size: entry.size, archive: index, entry: entry))
            }
        }
        for url in urls {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if url.pathExtension.lowercased() == "zip" {
                    try addZip(url)
                } else {
                    // A single photo or index file picked on its own.
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    files.append(File(path: url.lastPathComponent, size: UInt64(size), url: url))
                }
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
        var unpacked: URL?
        if !nested.isEmpty, let scratch {
            let directory = scratch.appending(path: "Nested-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            unpacked = directory
            for (archive, entry) in nested where entry.size <= maxNestedZip {
                try Task.checkCancellation()
                let target = directory.appending(path: "\(UUID().uuidString).zip")
                try archives[archive].extract(entry, to: target)
                // The inner ZIP's files count as being in the folder that held it.
                let holder = (entry.path as NSString).deletingLastPathComponent
                try addZip(target, prefix: holder.isEmpty ? "" : holder + "/")
            }
        }
        return ExportFiles(archives: archives, files: files, unpackedDirectory: unpacked)
    }

    /// Removes what `open` unpacked.
    public func cleanUp() {
        if let unpackedDirectory { try? FileManager.default.removeItem(at: unpackedDirectory) }
    }

    /// Strips everything up to `Takeout/` so the parts of a split Google export agree on the paths.
    static func relativePath(_ path: String) -> String {
        let clean = path.split(separator: "/").map(String.init)
        if let index = clean.firstIndex(where: { $0 == "Takeout" }) { return clean[(index + 1)...].joined(separator: "/") }
        return clean.joined(separator: "/")
    }

    /// The file an export's index refers to (`your_facebook_activity/posts/media/Trip_123/456_n.jpg`,
    /// `media/posts/202310/1801.jpg`). Such paths are relative to the export's root, which may lie below the folder or
    /// ZIP the user picked. Links to the web (`https://…`) are not files; query strings are dropped.
    public func file(forReference reference: String) -> Int? {
        var path = reference
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return nil }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.split(separator: "/").map(String.init).joined(separator: "/")
        guard !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        guard let candidates = byName[name] else { return nil }
        let lowered = path.lowercased()
        return candidates.first { files[$0].path.lowercased() == lowered }
            ?? candidates.first { files[$0].path.lowercased().hasSuffix("/" + lowered) }
    }

    public func data(of file: File, limit: UInt64 = 4 << 20) throws -> Data {
        if let archive = file.archive, let entry = file.entry { return try archives[archive].data(of: entry, limit: limit) }
        guard let url = file.url, file.size <= limit else { throw ZipReader.ZipError.corrupt(file.path) }
        return try Data(contentsOf: url)
    }

    /// A file on disk with the content: the export's own file, or one unpacked into `directory` (the caller removes it).
    /// One file at a time is unpacked, so an export of any size needs no more free space than its biggest video.
    public func materialize(_ file: File, in directory: URL) throws -> (url: URL, isTemporary: Bool) {
        if let url = file.url { return (url, false) }
        guard let archive = file.archive, let entry = file.entry else { throw ZipReader.ZipError.corrupt(file.path) }
        let folder = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: file.name)
        do {
            try archives[archive].extract(entry, to: target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (target, true)
    }

    /// Photos and videos the server's Photos app shows; other files of an export (HTML, JSON, CSV) are left out.
    public static func kind(of name: String) -> MediaKind? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        let mime = MimeTypes.mimeType(forExtension: ext)
        return mime == "application/octet-stream" ? nil : MimeTypes.kind(of: mime)
    }

    /// Files of an export that describe it (indexes, web pages), not photos the import left out.
    static let documentExtensions: Set<String> = ["json", "csv", "html", "htm", "txt", "css", "js", "md", "xml", "pdf", "vcf", "ics"]
}
