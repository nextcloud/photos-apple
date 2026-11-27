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
    /// A folder of the user's files in the folder browser ("Show in folder").
    case folder(path: String)
    /// The photos of a place (`Place.name`), a person (`Person.name`) or a tag (`SystemTag.name`), opened by a link.
    case place(name: String)
    case person(name: String)
    case tag(name: String)
    /// A memory (`Memory.id`), opened by a link or Handoff (SPEC §22.2).
    case memory(id: String)
}

/// What a `nextcloudphotos://` link opens (SPEC §4.8): a destination, an album, a photo, a place, a person, a tag, a folder
/// or a search.
///
/// The routes mirror the web app's (`/apps/photos/<route>`), so a link of the web app maps onto one of the app:
/// - `nextcloudphotos://<destination>` — `library`, `albums`, `memories`, … (the raw values of the app's destinations;
///   the web app's route names `timeline`, `thisday`, `sharedalbums`, `faces`, `shared`, `maps` are accepted too).
/// - `nextcloudphotos://albums/<name>`, `…/sharedalbums/<name>` (web) and `…/album/<name>`, `…/album/shared/<name>`
///   (earlier links). A full album id (`own:<name>`, `shared:<name>`) is accepted after `album/` as well.
/// - `nextcloudphotos://places/<name>`, `…/faces/<name>`, `…/tags/<name>`, `…/folders/<path>`
/// - `nextcloudphotos://photo/<fileId>`, `nextcloudphotos://search/<text>`
/// - `nextcloudphotos://memories/<id>` (a memory, `Memory.id`; the TV app's Top Shelf links have the same form) and
///   `nextcloudphotos://library/<fileId>` (the Library scrolled to that photo; Handoff of the Library's position, SPEC §22.2)
///
/// A link that names an account puts it in front of the route, as the user and server of a URL
/// (`nextcloudphotos://<user>@<host>[:port][/<server path>]/<route>`, `IncomingLink`).
public enum DeepLink: Hashable, Sendable {
    case destination(String)
    case album(id: String)
    case photo(fileId: FileID)
    case place(name: String)
    case person(name: String)
    case tag(name: String)
    /// A folder of the user's files, an absolute path (`/Photos/2024`).
    case folder(path: String)
    /// The search with this text.
    case search(String)
    /// A memory (`Memory.id`, e.g. `years-3`, `trip-1714000000`, `recap-2024`).
    case memory(id: String)
    /// The Library scrolled to this photo (where the user was on another device).
    case library(at: FileID)

    public static let scheme = "nextcloudphotos"

    /// Route names of the web app that differ from the app's destination names.
    static let aliases = [
        "timeline": "library", "thisday": "onThisDay", "sharedalbums": "sharedAlbums", "faces": "people", "shared": "sharedWithYou",
        "maps": "map",
    ]

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.user(percentEncoded: false) == nil,
            let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        // `pathComponents` decodes percent escapes, so an album name may contain "/" as %2F.
        self.init(route: [host] + Self.parts(of: url))
    }

    /// Parses the compact form produced by `request` (`"albums"`, `"album/own:Trip"`, `"photo/42"`), as handed around inside
    /// the app (`AppModel.requestedDestination`).
    public init?(request: String) {
        let parts = request.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return nil }
        let rest: String? = parts.count > 1 ? parts[1] : nil
        switch head {
        // The rest is one name or path, which may contain "/".
        case "place": self = .place(name: rest ?? "")
        case "person": self = .person(name: rest ?? "")
        case "tag": self = .tag(name: rest ?? "")
        case "folder": self = .folder(path: "/" + (rest ?? ""))
        case "search": self = .search(rest ?? "")
        default:
            self.init(route: [head] + (rest.map { [$0] } ?? []))
            return
        }
        if case .place(let name) = self, name.isEmpty { return nil }
        if case .person(let name) = self, name.isEmpty { return nil }
        if case .tag(let name) = self, name.isEmpty { return nil }
    }

    /// The path of a URL without the leading "/" (decoded).
    static func parts(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    /// A route as a list of decoded path segments: `["albums", "Trip"]`, `["folders", "Photos", "2024"]`.
    init?(route parts: [String]) {
        guard let head = parts.first?.lowercased() else { return nil }
        let rest = Array(parts.dropFirst())
        let joined = rest.joined(separator: "/")
        switch head {
        case "album":
            guard let first = rest.first else { return nil }
            let id: String
            if rest.count == 1 {
                id = first.hasPrefix("own:") || first.hasPrefix("shared:") ? first : "own:\(first)"
            } else if first == "shared" {
                id = "shared:" + rest.dropFirst().joined(separator: "/")
            } else {
                id = "own:" + joined
            }
            guard id.count > id.prefix(while: { $0 != ":" }).count + 1 else { return nil }
            self = .album(id: id)
        case "albums" where !rest.isEmpty:
            self = .album(id: "own:" + joined)
        case "sharedalbums" where !rest.isEmpty:
            self = .album(id: "shared:" + joined)
        case "places" where !rest.isEmpty:
            self = .place(name: joined)
        case "faces" where !rest.isEmpty:
            // The web app's list of faces without a person.
            self = rest == ["unassigned"] ? .destination("people") : .person(name: joined)
        case "tags" where !rest.isEmpty:
            self = .tag(name: joined)
        case "folders" where !rest.isEmpty:
            self = .folder(path: "/" + joined)
        case "shared":
            // A folder shared with the user opens the list of shared folders: their paths are the sharer's.
            self = .destination("sharedWithYou")
        case "search":
            guard !joined.isEmpty else {
                self = .destination("search")
                return
            }
            self = .search(joined)
        case "photo":
            guard rest.count == 1, let fileId = FileID(rest[0]), fileId > 0 else { return nil }
            self = .photo(fileId: fileId)
        case "memories" where !rest.isEmpty:
            self = .memory(id: joined)
        case "library", "timeline":
            if rest.isEmpty {
                self = .destination("library")
                return
            }
            guard rest.count == 1, let fileId = FileID(rest[0]), fileId > 0 else { return nil }
            self = .library(at: fileId)
        default:
            guard rest.isEmpty else { return nil }
            // The case of the app's own destination names is kept (`onThisDay`).
            self = .destination(Self.aliases[head] ?? parts[0])
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
        case .place(let name): "place/\(name)"
        case .person(let name): "person/\(name)"
        case .tag(let name): "tag/\(name)"
        case .folder(let path): "folder/\(path.drop(while: { $0 == "/" }))"
        case .search(let text): "search/\(text)"
        case .memory(let id): "memories/\(id)"
        case .library(let fileId): "library/\(fileId)"
        }
    }

    /// The route as the path segments of a link (the web app's names), e.g. `["albums", "Trip"]`.
    public var routeSegments: [String] {
        switch self {
        case .destination(let name):
            return [name]
        case .album(let id):
            let name = String(id.drop(while: { $0 != ":" }).dropFirst())
            return [id.hasPrefix("shared:") ? "sharedalbums" : "albums", name]
        case .photo(let fileId): return ["photo", String(fileId)]
        case .place(let name): return ["places", name]
        case .person(let name): return ["faces", name]
        case .tag(let name): return ["tags", name]
        case .folder(let path):
            let parts = path.split(separator: "/").map(String.init)
            return parts.isEmpty ? ["folders"] : ["folders"] + parts
        case .search(let text): return ["search", text]
        case .memory(let id): return ["memories", id]
        case .library(let fileId): return ["library", String(fileId)]
        }
    }

    /// A link to this route for one account: `nextcloudphotos://<user>@<host>[:port][/<server path>]/<route>`
    /// (`IncomingLink.resolve` reads it back). Spotlight items and App Intent entities carry it, so they open the right
    /// account's album or person.
    public func url(for account: Account) -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.percentEncodedUser = Self.encode(account.userId, allowed: .urlUserAllowed)
        components.host = account.serverURL.host(percentEncoded: false)
        components.port = account.serverURL.port
        let serverPath = account.serverURL.pathComponents.filter { $0 != "/" }
        // Each segment on its own: a "/" inside a name stays part of the name.
        let segments = (serverPath + routeSegments).map { Self.encode($0, allowed: .urlPathAllowed) }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        return components.url
    }

    private static func encode(_ value: String, allowed: CharacterSet) -> String {
        var set = allowed
        set.remove(charactersIn: "/@:?#")
        return value.addingPercentEncoding(withAllowedCharacters: set) ?? value
    }
}

/// A link from outside (another app, Spotlight, the clipboard) with what it means on this device (SPEC §4.8): a route for
/// the account shown, a route for another logged-in account (the app asks before it switches), an account that is not
/// logged in here, or a public album.
///
/// Accepted forms:
/// - `nextcloudphotos://<route>` — for the account shown (`DeepLink`).
/// - `nextcloudphotos://<user>@<host>[:port][/<server path>]/<route>` — for that account.
/// - `https://<host>[/<server path>][/index.php]/apps/photos/<route>` — a page of the web app of an account's server;
///   `…/apps/photos/public/<token>` is a public album, which needs no account.
public enum IncomingLink: Equatable, Sendable {
    /// Open the route in the account shown.
    case open(DeepLink)
    /// The route belongs to another logged-in account (several when a web link names a server with more than one of them).
    case switchAccount([AccountID], DeepLink)
    /// No account on this device matches; `account` names what the link asks for (`user@host` or the server).
    case unknownAccount(String)
    case publicAlbum(serverURL: URL, token: String)

    /// - Parameters:
    ///   - accounts: the accounts logged in on this device.
    ///   - active: the account shown.
    public static func resolve(_ url: URL, accounts: [Account], active: AccountID?) -> IncomingLink? {
        switch url.scheme?.lowercased() {
        case DeepLink.scheme:
            guard let user = url.user(percentEncoded: false) else { return DeepLink(url: url).map(IncomingLink.open) }
            return resolveAccountLink(url, user: user, accounts: accounts, active: active)
        case "https", "http":
            return resolveWebLink(url, accounts: accounts, active: active)
        default:
            return nil
        }
    }

    private static func resolveAccountLink(_ url: URL, user: String, accounts: [Account], active: AccountID?) -> IncomingLink? {
        let parts = DeepLink.parts(of: url)
        let host = serverName(url)
        // The account whose user and server match; of two on the same host, the one with the longer server path.
        let candidates = accounts.filter { account in
            (account.userId == user || account.loginName == user) && serverName(account.serverURL) == host
                && parts.starts(with: serverPath(account))
        }
        guard let account = candidates.max(by: { serverPath($0).count < serverPath($1).count }) else {
            return .unknownAccount("\(user)@\(host)")
        }
        let route = Array(parts.dropFirst(serverPath(account).count))
        guard let link = route.isEmpty ? .destination("library") : DeepLink(route: route) else { return nil }
        return account.id == active ? .open(link) : .switchAccount([account.id], link)
    }

    private static func resolveWebLink(_ url: URL, accounts: [Account], active: AccountID?) -> IncomingLink? {
        let parts = DeepLink.parts(of: url)
        guard let index = (0..<max(parts.count - 1, 0)).first(where: { parts[$0] == "apps" && parts[$0 + 1] == "photos" }) else {
            return nil
        }
        var base = Array(parts[..<index])
        if base.last == "index.php" { base.removeLast() }
        let route = Array(parts[(index + 2)...])
        if route.first == "public" {
            guard route.count >= 2, !route[1].isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.percentEncodedPath =
                base.isEmpty
                ? "" : "/" + base.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
            components.query = nil
            components.fragment = nil
            guard let serverURL = components.url else { return nil }
            return .publicAlbum(serverURL: serverURL, token: route[1])
        }
        let host = serverName(url)
        let matches = accounts.filter { serverName($0.serverURL) == host && serverPath($0) == base }
        guard !matches.isEmpty else {
            return .unknownAccount(([host] + base).joined(separator: "/"))
        }
        // The web app's start page is the timeline.
        guard let link = route.isEmpty ? .destination("library") : DeepLink(route: route) else { return nil }
        if let active, matches.contains(where: { $0.id == active }) { return .open(link) }
        return .switchAccount(matches.map(\.id), link)
    }

    /// Host and port, lower-cased: `cloud.example.com`, `localhost:8089`. The scheme is not compared (an account added with
    /// https:// is the same account in an http:// link of a proxy).
    static func serverName(_ url: URL) -> String {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func serverPath(_ account: Account) -> [String] {
        account.serverURL.pathComponents.filter { $0 != "/" }
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
