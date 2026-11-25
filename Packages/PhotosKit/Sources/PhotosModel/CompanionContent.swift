// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the Apple TV app leaves for its Top Shelf extension (SPEC §15.3): the recent memories with a cover image each. The
/// TV app writes it into the App Group (`TopShelfManifest.directoryName`) after a sync; the extension only reads it, so it
/// needs no account, no password and no network.
public struct TopShelfManifest: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        /// The memory's id (`Memory.id`), also the last part of `link`.
        public var id: String
        public var title: String
        /// The dates or the "years ago" line under the title.
        public var subtitle: String?
        /// The cover's file name in the manifest's directory (JPEG).
        public var imageFile: String
        /// Opens the memory in the TV app (`nextcloudphotos://memories/<id>`).
        public var link: URL
        /// Plays the memory as a slideshow at once (`nextcloudphotos://memories/<id>/play`).
        public var playLink: URL

        public init(id: String, title: String, subtitle: String?, imageFile: String, link: URL, playLink: URL) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.imageFile = imageFile
            self.link = link
            self.playLink = playLink
        }
    }

    /// When the TV app wrote it.
    public var generated: Date
    public var items: [Item]

    public init(generated: Date, items: [Item]) {
        self.generated = generated
        self.items = items
    }

    /// The directory in the App Group that holds `manifest.json` and the covers.
    public static let directoryName = "TopShelf"
    public static let fileName = "manifest.json"
}

/// What the iPhone app sends to the Apple Watch app (SPEC §15.3): today's photos as small JPEGs and this description of
/// them. The watch never signs in to the server; it shows what the phone sent last (WatchConnectivity).
public struct WatchDigest: Codable, Hashable, Sendable {
    public enum Section: String, Codable, Hashable, Sendable, CaseIterable {
        /// From this day in earlier years (or the newest memory when there are none today).
        case onThisDay
        case favorites
    }

    public struct Photo: Codable, Hashable, Sendable, Identifiable {
        public var id: FileID
        public var section: Section
        /// When it was taken.
        public var date: Date
        public var place: String?
        /// The JPEG's file name (unique per file id and ETag, so a changed photo is sent again).
        public var file: String

        public init(id: FileID, section: Section, date: Date, place: String?, file: String) {
            self.id = id
            self.section = section
            self.date = date
            self.place = place
            self.file = file
        }
    }

    /// The day this digest is for (start of the phone's day).
    public var day: Date
    /// "3 years ago" or the memory's title: the heading of `onThisDay`.
    public var onThisDayTitle: String?
    public var photos: [Photo]
    /// The photo of the day for the watch face (one of `photos`).
    public var photoOfTheDay: FileID?
    /// The phone's account is locked by app lock or signed out: the watch shows nothing of the library.
    public var isLocked: Bool

    public init(day: Date, onThisDayTitle: String?, photos: [Photo], photoOfTheDay: FileID?, isLocked: Bool = false) {
        self.day = day
        self.onThisDayTitle = onThisDayTitle
        self.photos = photos
        self.photoOfTheDay = photoOfTheDay
        self.isLocked = isLocked
    }

    public func photos(in section: Section) -> [Photo] { photos.filter { $0.section == section } }

    /// How many years ago a photo of this day was taken, counted in calendar years as "On this day" does: a photo of
    /// 25 November 2024 is "2 years ago" on 24 November 2026.
    public static func yearsAgo(_ date: Date, day: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.year, from: day) - calendar.component(.year, from: date)
    }

    public var photoOfTheDayEntry: Photo? { photos.first { $0.id == photoOfTheDay } }

    /// The files a watch must have for this digest.
    public var files: Set<String> { Set(photos.map(\.file)) }

    /// The JPEG's file name of a photo version.
    public static func fileName(fileId: FileID, etag: String) -> String {
        let safe = etag.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.prefix(32)
        return "\(fileId)-\(String(String.UnicodeScalarView(safe))).jpg"
    }

    /// The directory in the watch app's App Group container.
    public static let directoryName = "WatchDigest"
    public static let fileName = "digest.json"
    /// `transferFile` metadata key: the photo's file name.
    public static let fileKey = "file"
    /// `applicationContext` key: the encoded digest.
    public static let contextKey = "digest"
    /// `transferUserInfo` key from the watch: file names it does not have (re-installed app, lost transfer).
    public static let missingKey = "missing"

    /// A file name as `fileName(fileId:etag:)` makes them. The watch stores only files with such names: what arrives is
    /// never a path that leads out of its folder.
    public static func isValidFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg"), name.count <= 64, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "." }
    }
}
