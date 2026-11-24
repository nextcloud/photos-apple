// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Everything needed to talk to one account's server.
public struct ServerConnection: Sendable, Hashable {
    /// Base URL without trailing slash.
    public var serverURL: URL
    public var userId: String
    public var loginName: String
    public var appPassword: String
    public var userAgent: String

    public init(serverURL: URL, userId: String, loginName: String, appPassword: String, userAgent: String) {
        self.serverURL = ServerConnection.normalized(serverURL)
        self.userId = userId
        self.loginName = loginName
        self.appPassword = appPassword
        self.userAgent = userAgent
    }

    public var authorizationHeader: String {
        "Basic " + Data("\(loginName):\(appPassword)".utf8).base64EncodedString()
    }

    /// Headers sent with every authenticated request. `OCS-APIRequest: true` also satisfies the CSRF check of classic app routes.
    public var standardHeaders: [String: String] {
        [
            "Authorization": authorizationHeader,
            "User-Agent": userAgent,
            "OCS-APIRequest": "true",
        ]
    }

    // MARK: URLs

    /// `https://host/remote.php/dav`
    public var davRoot: URL { serverURL.appending(path: "remote.php/dav") }

    /// Absolute URL for a path relative to the server, e.g. `index.php/apps/photos/api/v1/preview/1`.
    public func url(_ relative: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        let base =
            components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath =
            base + "/" + relative.split(separator: "/").map { Self.encodeSegment(String($0)) }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// DAV URL for a path below `/remote.php/dav`, e.g. `files/alice/Photos/x.jpg`. Each segment is percent-encoded.
    public func davURL(_ path: String) -> URL {
        url("remote.php/dav/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .appendingTrailingSlashIfNeeded(path.hasSuffix("/"))
    }

    /// `/remote.php/dav/files/<uid><path>`
    public func filesURL(_ path: String) -> URL { davURL("files/\(userId)/\(path)") }

    /// Where the original of an item is: a path in the user's files (`/Photos/a.jpg`), or the DAV path of a collection child
    /// (`photos/<uid>/sharedalbums/<album>/<child>`, without a leading slash; `MediaItem.collectionChildMountType`).
    public func originalURL(path: String) -> URL { path.hasPrefix("/") ? filesURL(path) : davURL(path) }

    /// DAV href (relative to the DAV root) of a user file, used in SEARCH scopes: `/files/<uid><path>`.
    public func filesHref(_ path: String) -> String {
        let clean = path.hasPrefix("/") ? path : "/" + path
        return "/files/\(userId)\(clean == "/" ? "" : clean)"
    }

    /// The href prefix of user files in responses: `/<server path>/remote.php/dav/files/<uid>`.
    public var filesHrefPrefix: String {
        let base = serverURL.path(percentEncoded: false)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(trimmed)/remote.php/dav/files/\(userId)"
    }

    /// Converts a decoded response href to a path relative to the user's files root (`/Photos/x.jpg`).
    public func userPath(fromHref href: String) -> String? {
        let prefix = filesHrefPrefix
        guard href.hasPrefix(prefix) else { return nil }
        let rest = String(href.dropFirst(prefix.count))
        let trimmed = rest.hasSuffix("/") && rest.count > 1 ? String(rest.dropLast()) : rest
        return trimmed.isEmpty ? "/" : trimmed
    }

    // MARK: Helpers

    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;?#%[]@!$&'()*+,=")
        return set
    }()

    public static func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    public static func normalized(_ url: URL) -> URL {
        var string = url.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for suffix in ["/index.php", "/status.php"] where string.hasSuffix(suffix) {
            string.removeLast(suffix.count)
        }
        return URL(string: string) ?? url
    }
}

extension URL {
    func appendingTrailingSlashIfNeeded(_ needed: Bool) -> URL {
        guard needed, !absoluteString.hasSuffix("/") else { return self }
        return URL(string: absoluteString + "/") ?? self
    }
}

/// Builds the user agent string (SPEC §5.1.8).
public enum UserAgent {
    public static func make(appVersion: String) -> String {
        #if os(visionOS)
            let platform = "visionOS"
        #elseif os(macOS)
            let platform = "macOS"
        #elseif os(tvOS)
            // The server lists the TV's login under this name (Settings › Security), apart from the iPhone's.
            let platform = "tvOS"
        #else
            let platform = "iOS"
        #endif
        return "Mozilla/5.0 (\(platform)) Nextcloud-Photos/\(appVersion)"
    }
}
