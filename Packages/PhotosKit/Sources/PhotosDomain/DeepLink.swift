// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A screen pushed on top of a destination's root (album content, a single photo).
public enum AppRoute: Hashable, Codable, Sendable {
    /// `Album.id` (`"<kind>:<name>"`).
    case album(id: String)
    case photo(fileId: FileID)
    /// A destination of the app (its raw value) shown inside another one's stack: on iPhone the Collections tab
    /// lists the places that have no tab of their own and pushes them.
    case destination(String)
}

/// What a `nextcloudphotos://` link opens (SPEC §4.8): a destination, an album or a photo.
///
/// - `nextcloudphotos://<destination>` — `library`, `albums`, `memories`, … (the raw values of the app's destinations;
///   the web app's route names `timeline` and `thisday` are accepted too).
/// - `nextcloudphotos://album/<name>` — one of the user's albums; `nextcloudphotos://album/shared/<name>` for a shared album.
///   A full album id (`own:<name>`, `shared:<name>`) is accepted as well.
/// - `nextcloudphotos://photo/<fileId>`
public enum DeepLink: Hashable, Sendable {
    case destination(String)
    case album(id: String)
    case photo(fileId: FileID)

    public static let scheme = "nextcloudphotos"

    /// Route names of the web app that differ from the app's destination names.
    static let aliases = ["timeline": "library", "thisday": "onThisDay", "sharedalbums": "sharedAlbums"]

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        // `pathComponents` decodes percent escapes, so an album name may contain "/" as %2F.
        let parts = url.pathComponents.filter { $0 != "/" }
        self.init(head: host, parts: parts)
    }

    /// Parses the compact form produced by `request` (`"albums"`, `"album/own:Trip"`, `"photo/42"`), as handed around inside
    /// the app (`AppModel.requestedDestination`).
    public init?(request: String) {
        let parts = request.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return nil }
        self.init(head: head, parts: parts.count > 1 ? [parts[1]] : [])
    }

    private init?(head: String, parts: [String]) {
        switch head.lowercased() {
        case "album":
            guard let first = parts.first else { return nil }
            let id: String
            if parts.count == 1 {
                id = first.hasPrefix("own:") || first.hasPrefix("shared:") ? first : "own:\(first)"
            } else if first == "shared" {
                id = "shared:" + parts.dropFirst().joined(separator: "/")
            } else {
                id = "own:" + parts.joined(separator: "/")
            }
            guard id.count > id.prefix(while: { $0 != ":" }).count + 1 else { return nil }
            self = .album(id: id)
        case "photo":
            guard parts.count == 1, let fileId = FileID(parts[0]), fileId > 0 else { return nil }
            self = .photo(fileId: fileId)
        default:
            guard parts.isEmpty else { return nil }
            self = .destination(Self.aliases[head.lowercased()] ?? head)
        }
    }

    /// Whether a `photo/<fileId>` link may open this item. File ids are small numbers that are easy to guess, and a link can
    /// come from any app: it only opens what the library shows anyway. Archived photos need the Archive's own unlock, and the
    /// video half of a Live Photo is never shown on its own; a file the app doesn't know is not looked up.
    public static func mayOpen(_ item: MediaItem?) -> Bool {
        guard let item else { return false }
        return !item.isArchived && !item.isLivePhotoVideo
    }

    /// Compact form for `AppModel.requestedDestination`; `DeepLink(request:)` reads it back.
    public var request: String {
        switch self {
        case .destination(let name): name
        case .album(let id): "album/\(id)"
        case .photo(let fileId): "photo/\(fileId)"
        }
    }
}

/// The part of a window's navigation that is restored with the scene: the selected destination and the album open in it.
public struct NavigationSnapshot: Codable, Equatable, Sendable {
    public var destination: String
    public var routes: [AppRoute]
    /// The account the window showed (`AccountID.rawValue`). The snapshot names albums of that account: it is only restored for
    /// it, and dropped when the account is removed (nil: written by an earlier version).
    public var account: String?

    public init(destination: String, routes: [AppRoute] = [], account: String? = nil) {
        self.destination = destination
        // A single photo is not restored: the viewer needs the list it was opened from.
        self.routes = routes.filter { if case .album = $0 { true } else { false } }
        self.account = account
    }

    public init?(stored: String) {
        guard !stored.isEmpty, let value = try? JSONDecoder().decode(NavigationSnapshot.self, from: Data(stored.utf8)) else { return nil }
        self = NavigationSnapshot(destination: value.destination, routes: value.routes, account: value.account)
    }

    /// Whether a window may restore this snapshot while it shows `account`.
    public func belongs(to account: String) -> Bool { self.account == nil || self.account == account }

    /// Whether the stored snapshot must be dropped because it may name a removed account's albums. One of an earlier version,
    /// which doesn't say whose it is, is dropped too.
    public static func isStale(_ stored: String, accounts: [String]) -> Bool {
        guard let snapshot = NavigationSnapshot(stored: stored) else { return false }
        guard let account = snapshot.account else { return true }
        return !accounts.contains(account)
    }

    public var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// One way to write a date or a range of dates, used wherever the app shows "when" (albums, memories, trips, search filters).
///
/// Foundation's interval formats follow the language while single dates follow the region, so with e.g. English and a German
/// region the app showed "Nov 25 – 26, 2024" next to "24. Nov 2013". Here both ends always use the single-date format.
public enum DateRangeLabel {
    /// `end` is inclusive. Same day: "24. Nov 2013"; same year: "25. Nov – 26. Nov 2024"; else both dates in full.
    public static func string(from start: Date, to end: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let full = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated).year()
        guard end > start, !calendar.isDate(start, inSameDayAs: end) else { return start.formatted(full) }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let short = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        let first = start.formatted(sameYear ? short : full)
        let last = end.formatted(full)
        return String(localized: "\(first) – \(last)", bundle: .module, comment: "A range of dates: first day – last day.")
    }

    /// For a half-open range (`end` exclusive, e.g. search date filters).
    public static func string(for range: Range<Date>, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let last: Date = max(range.lowerBound, range.upperBound.addingTimeInterval(-1))
        return string(from: range.lowerBound, to: last, locale: locale, calendar: calendar)
    }
}
