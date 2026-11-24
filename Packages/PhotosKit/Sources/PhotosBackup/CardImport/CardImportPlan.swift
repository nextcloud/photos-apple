// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A photo or video on a memory card or camera (SPEC §15.2, import).
public struct CardItem: Identifiable, Hashable, Sendable, Codable {
    /// Stable for the card: the device and the file's path on it.
    public var id: String
    public var name: String
    /// The folder on the card (`DCIM/100CANON`): RAW and JPEG of one shot are paired within a folder.
    public var folder: String
    public var size: Int64
    /// The capture time the camera wrote (EXIF), else the file's date.
    public var capturedAt: Date?
    public var kind: MediaKind

    public init(id: String, name: String, folder: String, size: Int64, capturedAt: Date?, kind: MediaKind) {
        self.id = id
        self.name = name
        self.folder = folder
        self.size = size
        self.capturedAt = capturedAt
        self.kind = kind
    }

    public var isRaw: Bool { BackupMatcher.isRawName(name) }

    /// The name without extension, for pairing (`IMG_0042`).
    public var stem: String { (name as NSString).deletingPathExtension }

    /// The file as the backup matcher sees a device file.
    var resource: LocalResource {
        LocalResource(
            localIdentifier: id, kind: kind, createdAt: capturedAt ?? .distantPast, originalName: name, byteSize: size,
            rendition: isRaw ? .raw : .original)
    }

    /// File types a card import takes: photos, RAW and videos; not the camera's own files (`.THM`, `.XMP`, `.CTG`…).
    public static func isMedia(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !name.hasPrefix(".") else { return false }
        return BackupMatcher.rawExtensions.contains(ext) || mediaExtensions.contains(ext)
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "webp", "avif", "gif",
        "mov", "mp4", "m4v", "mts", "m2ts", "avi", "insv", "insp", "360",
    ]

    public static func kind(ofName name: String) -> MediaKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "mts", "m2ts", "avi", "insv", "360"].contains(ext) ? .video : .image
    }
}

/// The files of one shot that go together: RAW + JPEG (+ HEIF) of the same name in the same folder. Selected,
/// skipped and filed into a folder as one, so the pair is never split across days or left half imported.
public struct CardGroup: Identifiable, Hashable, Sendable {
    public var items: [CardItem]

    public var id: String { items.first?.id ?? "" }

    /// The earliest capture time of the group (its folder is chosen by it).
    public var capturedAt: Date? { items.compactMap(\.capturedAt).min() }

    /// The file the import sheet shows: the JPEG/HEIF of a pair (RAW previews are slow), else the first.
    public var leader: CardItem { items.first { !$0.isRaw && $0.kind == .image } ?? items[0] }

    public var hasRaw: Bool { items.contains(where: \.isRaw) }
    public var size: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Groups by folder and name (case-insensitive), newest shot first.
    public static func groups(_ items: [CardItem]) -> [CardGroup] {
        var order: [String] = []
        var byKey: [String: [CardItem]] = [:]
        for item in items {
            let key = item.folder.lowercased() + "/" + item.stem.lowercased()
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        let groups = order.compactMap { key in
            byKey[key].map { members in
                // JPEG/HEIF first, RAW after: the order the files are listed and uploaded in.
                CardGroup(items: members.sorted { ($0.isRaw ? 1 : 0, $0.name) < ($1.isRaw ? 1 : 0, $1.name) })
            }
        }
        return groups.sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
    }
}

/// Where imported files go: a folder pattern with date parts, e.g. `Photos/{yyyy}/{yyyy-MM-dd}` (SPEC §15.2).
public struct DestinationPattern: Hashable, Sendable, Codable {
    public var pattern: String

    public init(_ pattern: String) { self.pattern = pattern }

    public static let `default` = DestinationPattern("/Photos/{yyyy}/{yyyy-MM-dd}")

    /// Patterns to choose from.
    public static let suggestions = [
        "/Photos/{yyyy}/{yyyy-MM-dd}", "/Photos/{yyyy}/{MM}", "/Photos/{yyyy-MM-dd}", "/Photos/{yyyy}/{yyyy-MM-dd} {camera}",
        "/Photos/Imports/{yyyy-MM-dd}",
    ]

    /// Letters a date part may use: year, month, day (and the separators between them).
    static let dateCharacters = Set("yMd-_. ")

    /// The folder for a shot of `date` (nil: the date part becomes "Unknown date"), with `camera` for `{camera}`. Always
    /// starts with "/"; `..` and empty parts are dropped, and a `/` in a value cannot make a new folder level.
    public func folder(for date: Date?, camera: String? = nil, timeZone: TimeZone = .current) -> String {
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let token = String(rest[rest.index(after: open)..<close])
            result += Self.value(of: token, date: date, camera: camera, timeZone: timeZone)
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        let parts = result.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && $0 != ".." && $0 != "."
        }
        return "/" + parts.joined(separator: "/")
    }

    static func value(of token: String, date: Date?, camera: String?, timeZone: TimeZone) -> String {
        if token.lowercased() == "camera" {
            let name = (camera ?? "").replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            return name.isEmpty
                ? String(localized: "Camera", bundle: .module, comment: "Import folder name part when the camera has no name.") : name
        }
        guard !token.isEmpty, token.allSatisfy({ dateCharacters.contains($0) }) else { return "{\(token)}" }
        guard let date else {
            return String(localized: "Unknown date", bundle: .module, comment: "Import folder name for files without a date.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = token
        return formatter.string(from: date)
    }

    /// The pattern can be used: it names a folder below the root and its braces are known parts.
    public var isValid: Bool {
        let sample = folder(for: Date(timeIntervalSince1970: 0), camera: "X", timeZone: TimeZone(identifier: "UTC")!)
        return sample != "/" && !sample.contains("{") && !sample.contains("}")
    }
}

/// What earlier imports brought to the server, so "new only" knows a card's files without asking the server again
/// (SPEC §15.2). Kept per account; a file is known by name, size and capture second.
public struct CardImportLedger: Codable, Sendable, Equatable {
    /// Key → path on the server.
    public var entries: [String: String] = [:]

    public init() {}

    public static func key(_ item: CardItem) -> String {
        "\(item.name.lowercased())|\(item.size)|\(Int64((item.capturedAt ?? .distantPast).timeIntervalSince1970))"
    }

    public func contains(_ item: CardItem) -> Bool { entries[Self.key(item)] != nil }

    public mutating func record(_ item: CardItem, path: String) { entries[Self.key(item)] = path }

    public static func load(from url: URL) -> CardImportLedger {
        guard let data = try? Data(contentsOf: url) else { return CardImportLedger() }
        return (try? JSONDecoder().decode(CardImportLedger.self, from: data)) ?? CardImportLedger()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
