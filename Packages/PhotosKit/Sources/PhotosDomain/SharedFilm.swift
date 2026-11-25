// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A film or slideshow watched together over SharePlay (SPEC §16.6). Only *what* to play travels through Apple's
/// SharePlay channel (end-to-end encrypted): the timeline, the files' ids and the Nextcloud they are on. Never a photo, a
/// preview or the user's music: every participant loads the pictures from Nextcloud with their own account, so they see
/// only what is shared with them there, and each device makes the style's music itself.
public struct SharedFilm: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A memory film.
        case memory
        /// A slideshow of an album, a place or a selection, played as a film so it can be in step everywhere.
        case slideshow
    }

    /// What a participant needs to ask their Nextcloud for a picture.
    public struct Picture: Codable, Hashable, Sendable {
        public var fileId: FileID
        public var etag: String
        public var mimeType: String
        public var hasPreview: Bool

        public init(fileId: FileID, etag: String, mimeType: String, hasPreview: Bool) {
            self.fileId = fileId
            self.etag = etag
            self.mimeType = mimeType
            self.hasPreview = hasPreview
        }
    }

    /// Changes whenever someone starts sharing: the playback coordinator's item.
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// The Nextcloud the pictures are on (`SharedFilm.serverKey`): participants need an account there.
    public var server: String
    /// The timeline, without places (`FilmPlan.withoutPlaces`): the same on every device.
    public var plan: FilmPlan
    /// The pictures of `plan.shots`, in the same order.
    public var pictures: [Picture]
    /// The style's own music plays on every device; false: silent.
    public var playsScore: Bool

    public init(
        id: String = UUID().uuidString, kind: Kind, title: String, subtitle: String?, server: URL, plan: FilmPlan, pictures: [Picture],
        playsScore: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.server = Self.serverKey(server)
        self.plan = plan.withoutPlaces()
        self.pictures = pictures
        self.playsScore = playsScore
    }

    /// A server's address in one form: scheme, host, port and path, lower-case host, no user, no trailing slash.
    public static func serverKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? url.absoluteString
    }

    /// The host shown to someone who is not signed in to that Nextcloud.
    public var serverName: String {
        URLComponents(string: server)?.host ?? server
    }

    public func isOn(_ serverURL: URL) -> Bool { Self.serverKey(serverURL) == server }

    /// SharePlay carries the activity in a small message; a film is a highlight of at most `FilmPlan.shotLimit` pictures,
    /// and a slideshow is cut to the same number.
    public static let pictureLimit = 200
}

/// What a participant tells the others when the film has loaded: how many of its pictures they can see.
public struct SharedFilmReport: Codable, Hashable, Sendable {
    public enum Problem: String, Codable, Hashable, Sendable {
        /// Not signed in to that Nextcloud on this device.
        case noAccount
        /// Signed in, but some or all pictures are not shared with them.
        case notShared
    }

    public var visible: Int
    public var total: Int
    public var problem: Problem?

    public init(visible: Int, total: Int, problem: Problem?) {
        self.visible = visible
        self.total = total
        self.problem = problem
    }

    public var seesEverything: Bool { problem == nil && visible >= total }
}

/// The reports of the others, summed up for the people watching: how many cannot see some or all of the pictures.
public struct SharedFilmAudience: Hashable, Sendable {
    /// People who see every picture.
    public var complete = 0
    /// People who see some.
    public var partial = 0
    /// People who see none (not shared, or not signed in to that Nextcloud).
    public var blind = 0

    public init(_ reports: [SharedFilmReport]) {
        for report in reports {
            if report.seesEverything {
                complete += 1
            } else if report.visible > 0 {
                partial += 1
            } else {
                blind += 1
            }
        }
    }

    public var everyoneSeesEverything: Bool { partial == 0 && blind == 0 }
}

/// Keeping a film in step with the others (SPEC §16.6): the playback coordinator says "be at `itemTime` when the host
/// clock reads `hostTime`".
public enum FilmSync {
    /// Where the film is now, and how long to wait before it moves on (a start planned for a moment from now): at
    /// `hostTime` it is at `itemTime`, playing at `rate`.
    public static func position(itemTime: Double, hostTime: Double?, now: Double, rate: Double = 1) -> (time: Double, delay: Double) {
        guard let hostTime, hostTime.isFinite else { return (max(0, itemTime), 0) }
        if hostTime > now { return (max(0, itemTime), hostTime - now) }
        return (max(0, itemTime + (now - hostTime) * rate), 0)
    }
}
