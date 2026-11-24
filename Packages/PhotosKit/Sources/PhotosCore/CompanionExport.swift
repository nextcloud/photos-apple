// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

/// Small JPEGs of the library for places that cannot load previews themselves: the Apple TV's Top Shelf and the Apple Watch
/// (SPEC §15.3). Taken from the preview cache, or the server when the preview is not there yet.
public enum CompanionExport {
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "companion")

    /// A JPEG of the item, its long edge at most `maxPixelSize`.
    public static func jpeg(_ item: MediaItem, services: AccountServices, maxPixelSize: Int, quality: Double = 0.75) async -> Data? {
        let bucket = maxPixelSize > 1024 ? 4096 : (maxPixelSize > 256 ? 1024 : 256)
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item), maxPixelSize: maxPixelSize)
        guard let image = await services.images.preview(request) else { return nil }
        // The pipeline decodes no larger than asked, but a cached decode may be larger: scale it down here.
        if max(image.width, image.height) <= maxPixelSize { return ImageDecoding.jpegData(image, quality: quality) }
        guard let data = ImageDecoding.jpegData(image, quality: 1), let small = ImageDecoding.decode(data: data, maxPixelSize: maxPixelSize)
        else { return nil }
        return ImageDecoding.jpegData(small, quality: quality)
    }

    /// Writes `files` into `directory` (file name → contents, nil: already there) and removes every other file but `keep`.
    static func replaceFiles(in directory: URL, writing files: [String: Data], keeping keep: Set<String>) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: directory.appending(path: name), options: .atomic) }
        let wanted = keep.union(files.keys)
        for name in (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [] where !wanted.contains(name) {
            try? manager.removeItem(at: directory.appending(path: name))
        }
    }

    // MARK: Top Shelf (Apple TV)

    /// The Top Shelf's carousel fills the screen: 1920 pixels wide.
    public static let topShelfPixelSize = 1920

    /// The Top Shelf's directory in the App Group.
    public static var topShelfDirectory: URL { AppPaths.container.appending(path: TopShelfManifest.directoryName) }

    /// Writes the Top Shelf's manifest and covers for these memories (`TVShelves.memories` order). Returns whether anything
    /// changed, so the caller tells the system only then. An empty list empties the shelf.
    @discardableResult
    public static func exportTopShelf(
        _ memories: [Memory], services: AccountServices, directory: URL = topShelfDirectory, now: Date = Date()
    ) async -> Bool {
        let shown = Array(memories.prefix(TVShelves.topShelfLimit))
        let previous = try? JSONDecoder().decode(
            TopShelfManifest.self, from: Data(contentsOf: directory.appending(path: TopShelfManifest.fileName)))
        let library = services.library
        let covers = (try? await library.fetchItems(shown.map(\.cover))) ?? [:]
        var items: [TopShelfManifest.Item] = []
        var files: [String: Data] = [:]
        var keep: Set<String> = [TopShelfManifest.fileName]
        for memory in shown {
            guard let cover = covers[memory.cover] else { continue }
            let file = WatchDigest.fileName(fileId: cover.fileId, etag: cover.etag)
            if FileManager.default.fileExists(atPath: directory.appending(path: file).path(percentEncoded: false)) {
                keep.insert(file)
            } else if let data = await jpeg(cover, services: services, maxPixelSize: topShelfPixelSize, quality: 0.8) {
                files[file] = data
            } else {
                continue
            }
            items.append(
                TopShelfManifest.Item(
                    id: memory.id, title: memory.title, subtitle: Memories.dateLine(for: memory), imageFile: file,
                    link: TVRoute.memory(id: memory.id, play: false).url, playLink: TVRoute.memory(id: memory.id, play: true).url))
        }
        guard items != previous?.items else { return false }
        do {
            let manifest = try JSONEncoder().encode(TopShelfManifest(generated: now, items: items))
            files[TopShelfManifest.fileName] = manifest
            try replaceFiles(in: directory, writing: files, keeping: keep)
            return true
        } catch {
            logger.error("top shelf: could not write: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Clears the Top Shelf (logout).
    public static func clearTopShelf(directory: URL = topShelfDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Apple Watch

    /// The size of the watch's photos: sharp on the largest watch at full width, small enough to send dozens a day.
    public static let watchPixelSize = 480

    /// Today's digest for the watch and the JPEGs it names, written into `directory` (the phone's outbox for the watch;
    /// JPEGs that are already there are kept and not made again).
    public static func watchDigest(services: AccountServices, directory: URL, now: Date = Date(), calendar: Calendar = .current) async
        -> WatchDigest
    {
        let day = calendar.startOfDay(for: now)
        let library = services.library
        let onThisDay = (try? library.onThisDayItems(now: now, calendar: calendar)) ?? []
        var fallback: [MediaItem] = []
        var title: String?
        if onThisDay.isEmpty {
            // No "On this day" today: the newest memory (a trip or the year in review) fills the section.
            if let snapshot = try? await library.memories(now: now, calendar: calendar),
                let memory = TVShelves.memories(onThisDay: [], recap: snapshot.recap, trips: snapshot.trips).first
            {
                let byId = (try? await library.fetchItems(Array(memory.items.prefix(200)))) ?? [:]
                fallback = memory.items.compactMap { byId[$0] }
                title = memory.title
            }
        } else {
            // All of one year: "3 years ago"; several years: the watch's own "On this day".
            let years = Set(onThisDay.map { WatchDigest.yearsAgo($0.timestamp, day: now, calendar: calendar) })
            if years.count == 1, let years = years.first, years > 0 { title = Memories.yearsAgoTitle(years) }
        }
        let selection = WatchDigestPlan.select(
            onThisDay: onThisDay, fallbackMemory: fallback, favorites: (try? library.favoriteImages(limit: 40)) ?? [], day: day,
            calendar: calendar)
        var photos: [WatchDigest.Photo] = []
        var files: [String: Data] = [:]
        var keep: Set<String> = []
        let sections: [(WatchDigest.Section, [MediaItem])] = [(.onThisDay, selection.onThisDay), (.favorites, selection.favorites)]
        for (section, items) in sections {
            for item in items {
                let file = WatchDigest.fileName(fileId: item.fileId, etag: item.etag)
                if FileManager.default.fileExists(atPath: directory.appending(path: file).path(percentEncoded: false)) {
                    keep.insert(file)
                } else if let data = await jpeg(item, services: services, maxPixelSize: watchPixelSize) {
                    files[file] = data
                } else {
                    continue
                }
                photos.append(WatchDigest.Photo(id: item.fileId, section: section, date: item.timestamp, place: item.place, file: file))
            }
        }
        let shownIds = Set(photos.map(\.id))
        let photoOfTheDay = selection.photoOfTheDay.map(\.fileId).flatMap { shownIds.contains($0) ? $0 : nil } ?? photos.first?.id
        let digest = WatchDigest(
            day: day, onThisDayTitle: photos.contains { $0.section == .onThisDay } ? title : nil, photos: photos,
            photoOfTheDay: photoOfTheDay)
        do {
            try replaceFiles(in: directory, writing: files, keeping: keep)
        } catch {
            logger.error("watch: could not write photos: \(error.localizedDescription, privacy: .public)")
        }
        return digest
    }
}
