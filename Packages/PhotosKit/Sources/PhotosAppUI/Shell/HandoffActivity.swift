// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel

// Handoff between iPhone, iPad, Mac and Vision Pro (SPEC §22.2): the window advertises what it shows — the photo in the
// viewer, an album, a memory, a place, a person, a tag, a folder, a destination or the Library's position — as an
// `NSUserActivity` whose payload is the same account link that Spotlight items and widgets carry
// (`nextcloudphotos://<user>@<host>/<route>`, `DeepLink.url(for:)`). The other device opens it through `AppModel.open`,
// so the same rules apply as for every link: the same account opens at once, another logged-in account asks before the
// app switches, and an account that is not logged in there offers the server's web page instead.

/// What one window advertises for Handoff.
public struct HandoffContent: Hashable, Sendable {
    public var link: DeepLink
    /// Shown by the system where it names the activity (and in the app's own question on the other device).
    public var title: String?

    public init(_ link: DeepLink, title: String? = nil) {
        self.link = link
        self.title = title
    }
}

/// The activity's type, payload and web fallback.
public enum HandoffActivity {
    /// Listed under `NSUserActivityTypes` in the app's Info.plist (project.yml). One type for everything the app shows:
    /// the link says what it is.
    public static let type = "com.nextcloud.photos.viewing"
    static let linkKey = "link"
    static let versionKey = "version"
    /// The payload's format; a newer one that an older app cannot read is ignored by it (no link key).
    static let version = 1

    /// The activity's user info for a route of an account: the account link, nothing else (no names of other accounts, no
    /// secrets). Nil when the route cannot be written as a link.
    static func userInfo(for content: HandoffContent, account: Account) -> [String: Any]? {
        guard let link = content.link.url(for: account) else { return nil }
        return [linkKey: link.absoluteString, versionKey: version]
    }

    /// The account link in an activity's user info, if it is one of the app's.
    public static func link(in userInfo: [AnyHashable: Any]?) -> URL? {
        guard let text = userInfo?[linkKey] as? String, let url = URL(string: text), url.scheme?.lowercased() == DeepLink.scheme,
            url.user(percentEncoded: false) != nil
        else { return nil }
        return url
    }

    /// The same place in the server's web app, for a device without the app or without this account: Handoff opens it in
    /// the browser there. Only http(s) (`NSUserActivity.webpageURL` accepts nothing else).
    static func webpageURL(for link: DeepLink, serverURL: URL) -> URL? {
        guard let scheme = serverURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var base = serverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        func encode(_ part: String) -> String {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/?#")
            return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
        }
        let route: [String]
        switch link {
        case .photo(let fileId):
            // The server's short link of a file opens it in its viewer.
            return URL(string: "\(base)/index.php/f/\(fileId)")
        case .album, .place, .person, .tag, .folder:
            route = link.routeSegments
        case .memory(let id):
            route = id.hasPrefix("years-") ? ["thisday"] : []
        case .library, .search:
            route = []
        case .destination(let raw):
            route = webRoute(of: raw).map { [$0] } ?? []
        }
        let path = route.map(encode).joined(separator: "/")
        return URL(string: "\(base)/index.php/apps/photos/\(path)")
    }

    /// The web app's route of a destination of the app, when it has one (its start page is the timeline).
    static func webRoute(of destination: String) -> String? {
        switch destination {
        case "photos", "videos", "favorites", "albums", "tags", "places", "folders": destination
        case "sharedAlbums": "sharedalbums"
        case "onThisDay": "thisday"
        case "people": "faces"
        case "sharedWithYou": "shared"
        case "map": "maps"
        default: nil
        }
    }
}

/// An activity from another device, answered on this one.
public enum HandoffArrival: Equatable, Sendable {
    /// Open it like any link (`AppModel.open`): the account shown, or the question to switch to another logged-in one.
    case open(URL)
    /// No account here is the one the other device shows. `name` is user@server; `webpage` the same place on the web.
    case otherAccount(name: String, webpage: URL?)
    /// Not one of the app's activities, or a link this version cannot read.
    case ignore

    /// - Parameters:
    ///   - accounts: the accounts logged in on this device.
    ///   - active: the account shown.
    public static func resolve(link: URL?, webpage: URL?, accounts: [Account], active: AccountID?) -> HandoffArrival {
        guard let link else { return .ignore }
        guard let resolved = IncomingLink.resolve(link, accounts: accounts, active: active) else { return .ignore }
        if case .unknownAccount(let name) = resolved {
            let web = webpage.flatMap { url in ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil }
            return .otherAccount(name: name, webpage: web)
        }
        return .open(link)
    }
}
