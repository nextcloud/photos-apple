// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

@testable import PhotosModel
@testable import PhotosStore

/// A deterministic, plausible library for performance tests (SPEC §10: "synthetic 100k index").
///
/// The rows look like a real index: twenty years of photos in `/Photos/<year>/<month>`, taken in events of 40, with
/// camera-style file names, 8 % videos, 3 % favourites, half of the items geotagged around forty places, some captions,
/// a few Live Photos with their hidden video halves, and a few archived items.
enum SyntheticLibrary {
    static let places: [(name: String, country: String, latitude: Double, longitude: Double)] = [
        ("Berlin", "Germany", 52.52, 13.40), ("Stuttgart", "Germany", 48.78, 9.18), ("München", "Germany", 48.14, 11.58),
        ("Hamburg", "Germany", 53.55, 9.99), ("Köln", "Germany", 50.94, 6.96), ("Paris", "France", 48.86, 2.35),
        ("Lyon", "France", 45.76, 4.84), ("Nice", "France", 43.70, 7.27), ("Roma", "Italy", 41.90, 12.50),
        ("Firenze", "Italy", 43.77, 11.26), ("Venezia", "Italy", 45.44, 12.32), ("Napoli", "Italy", 40.85, 14.27),
        ("Barcelona", "Spain", 41.39, 2.17), ("Madrid", "Spain", 40.42, -3.70), ("Sevilla", "Spain", 37.39, -5.98),
        ("Lisboa", "Portugal", 38.72, -9.14), ("Porto", "Portugal", 41.15, -8.61), ("London", "United Kingdom", 51.51, -0.13),
        ("Edinburgh", "United Kingdom", 55.95, -3.19), ("Dublin", "Ireland", 53.35, -6.26), ("Amsterdam", "Netherlands", 52.37, 4.90),
        ("Bruxelles", "Belgium", 50.85, 4.35), ("Zürich", "Switzerland", 47.38, 8.54), ("Genève", "Switzerland", 46.20, 6.14),
        ("Wien", "Austria", 48.21, 16.37), ("Salzburg", "Austria", 47.81, 13.04), ("Praha", "Czechia", 50.08, 14.44),
        ("Kraków", "Poland", 50.06, 19.94), ("København", "Denmark", 55.68, 12.57), ("Stockholm", "Sweden", 59.33, 18.07),
        ("Oslo", "Norway", 59.91, 10.75), ("Helsinki", "Finland", 60.17, 24.94), ("Reykjavík", "Iceland", 64.15, -21.94),
        ("New York", "United States", 40.71, -74.01), ("San Francisco", "United States", 37.77, -122.42),
        ("Honolulu", "United States", 21.31, -157.86), ("Tokyo", "Japan", 35.68, 139.69), ("Kyoto", "Japan", 35.01, 135.77),
        ("Sydney", "Australia", -33.87, 151.21), ("Cape Town", "South Africa", -33.92, 18.42),
    ]

    static let captions = [
        "Sunset at the beach", "Birthday party", "Hiking in the mountains", "Family dinner", "Conference talk", "First day of school",
        "Christmas market", "Street food", "Old town at night", "Sailing trip",
    ]

    /// Newest capture time of the synthetic library (2026-11-01 12:00 UTC); items go back about twenty years from here.
    static let newest: Double = 1_793_534_400

    /// A small deterministic generator (SplitMix64), so every run produces the same library.
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// Item number `index` (0 = newest) of a library of `count` items. File ids start at 1000.
    static func item(_ index: Int, of count: Int, generator: inout Generator) -> MediaItem {
        let span: Double = 20 * 365.25 * 86_400
        // Newest first, in events of 40 items (a day out, a trip) that start evenly spread over the years; within an
        // event the items are about 20 minutes apart. With 100 000 items an event starts every 2.9 days.
        let event = index / 40
        let events = max((count + 39) / 40, 1)
        let captured = newest - span * Double(event) / Double(events) - Double(index % 40) * 1200 - Double(generator.int(600))
        let date = Date(timeIntervalSince1970: captured)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let isVideo = generator.int(100) < 8
        let isLive = !isVideo && generator.int(100) < 4
        let stamp = String(
            format: "%04d%02d%02d_%02d%02d%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
        let name = isVideo ? "VID_\(stamp).mp4" : (generator.int(3) == 0 ? "IMG_\(1000 + index % 9000).HEIC" : "IMG_\(stamp).jpg")
        let isArchived = generator.int(200) == 0
        let folder = String(format: "/Photos/%04d/%02d", parts.year!, parts.month!)
        let path = (isArchived ? "/.archive" : "") + folder + "/" + name
        // A place stays the same for runs of ~40 items, like trips do.
        let placeIndex = (index / 40 * 7919) % (places.count * 2)
        let place = placeIndex < places.count ? places[placeIndex] : nil
        let fileId = FileID(1000 + index * 2)
        return MediaItem(
            fileId: fileId, path: path, mimeType: isVideo ? "video/mp4" : (name.hasSuffix("HEIC") ? "image/heic" : "image/jpeg"),
            size: Int64(1_500_000 + generator.int(4_000_000)), etag: String(format: "%016llx", generator.next()),
            modifiedAt: Date(timeIntervalSince1970: captured + 5),
            uploadedAt: Date(timeIntervalSince1970: captured + 3600),
            capturedAt: date,
            captureOffset: 3600,
            width: generator.int(4) == 0 ? 3024 : 4032, height: generator.int(4) == 0 ? 4032 : 3024,
            latitude: place.map { $0.latitude + (generator.unit() - 0.5) * 0.2 },
            longitude: place.map { $0.longitude + (generator.unit() - 0.5) * 0.2 },
            altitude: place == nil ? nil : Double(generator.int(800)),
            place: place?.name, placeCountry: place?.country,
            isFavorite: generator.int(100) < 3,
            permissions: Permissions(rawValue: "RGDNVW"),
            hasPreview: true,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            livePhotoPeer: isLive ? fileId + 1 : nil,
            caption: generator.int(50) == 0 ? captions[generator.int(captions.count)] : nil,
            isArchived: isArchived,
            duration: isVideo ? Double(5 + generator.int(120)) : nil)
    }

    /// The hidden video half of a Live Photo.
    static func liveVideo(for photo: MediaItem) -> MediaItem {
        var video = photo
        video.fileId = photo.fileId + 1
        video.path = (photo.path as NSString).deletingPathExtension + ".mov"
        video.name = (video.path as NSString).lastPathComponent
        video.mimeType = "video/quicktime"
        video.kind = .video
        video.livePhotoPeer = photo.fileId
        video.isLivePhotoVideo = true
        return video
    }

    /// Items `range` of a library of `count` visible items, newest first, in the order an initial sync delivers them.
    static func items(_ range: Range<Int>, of count: Int, seed: UInt64 = 42) -> [MediaItem] {
        var result: [MediaItem] = []
        result.reserveCapacity(range.count + range.count / 20)
        for index in range {
            var generator = Generator(state: seed &+ UInt64(index) &* 0x2545_F491_4F6C_DD1D)
            let item = item(index, of: count, generator: &generator)
            result.append(item)
            if item.livePhotoPeer != nil { result.append(liveVideo(for: item)) }
        }
        return result
    }

    /// A new on-disk database in the temporary directory, filled page by page as the initial sync does.
    /// - Returns: the database, its store and the seconds each page took to upsert.
    static func makeDatabase(count: Int, pageSize: Int = 1000) throws -> (database: AccountDatabase, library: LibraryStore, pageSeconds: [Double]) {
        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        let seconds = try fill(library, count: count, pageSize: pageSize)
        return (database, library, seconds)
    }

    @discardableResult
    static func fill(_ library: LibraryStore, count: Int, pageSize: Int = 1000) throws -> [Double] {
        var seconds: [Double] = []
        var start = 0
        while start < count {
            let end = min(start + pageSize, count)
            let page = items(start..<end, of: count)
            let began = ContinuousClock.now
            try library.upsert(page)
            seconds.append((ContinuousClock.now - began).seconds)
            start = end
        }
        return seconds
    }

    /// Removes the database files of `makeDatabase`.
    static func remove(_ database: AccountDatabase) {
        try? database.writer.close()
        let path = database.url.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    var milliseconds: Double { seconds * 1000 }
}
