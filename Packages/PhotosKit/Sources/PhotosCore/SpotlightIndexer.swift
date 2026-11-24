// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreSpotlight
import CryptoKit
import Foundation
import GRDB
import OSLog
import PhotosDomain
import PhotosModel
import PhotosStore
import UniformTypeIdentifiers

/// One album, person or place in Spotlight (SPEC §7.23). Its link (`DeepLink.url(for:)`) is the item's identifier: a tap
/// on the result opens it in its account (after asking, when another account is shown).
public struct SpotlightEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case album, person, place
    }

    public var kind: Kind
    public var title: String
    /// A second line: the album's location, the place's country.
    public var detail: String?
    public var link: DeepLink
}

/// What of an account may go into Spotlight. Photos themselves are not indexed (SPEC §7.23: v1 indexes collections).
///
/// Nothing that is hidden or archived reaches the index:
/// - nothing at all while app lock is on (Spotlight shows its results on the lock screen and outside the app);
/// - no person hidden on this device and no unnamed person;
/// - a place only when a photo there is in the library and not archived (archived photos keep their place);
/// - no public-link albums (they are not the user's).
/// No thumbnails are indexed: an album cover can be a photo that was archived since.
public enum SpotlightContent {
    /// The library's collections as the account's database has them.
    public struct Library: Sendable {
        public var albums: [Album] = []
        /// Named people with their photo counts (`person` table, filled by the search labels).
        public var people: [String] = []
        /// Places of photos in the library that are not archived, with their country code.
        public var places: [(name: String, countryCode: String?)] = []

        public init(albums: [Album] = [], people: [String] = [], places: [(name: String, countryCode: String?)] = []) {
            self.albums = albums
            self.people = people
            self.places = places
        }
    }

    public static func entries(
        _ library: Library, hiddenPeople: Set<String>, appLockEnabled: Bool, locale: Locale = .current
    ) -> [SpotlightEntry] {
        guard !appLockEnabled else { return [] }
        var entries: [SpotlightEntry] = []
        for album in library.albums where album.kind != .publicLink {
            let title = album.title.isEmpty ? album.name : album.title
            entries.append(
                SpotlightEntry(
                    kind: .album, title: title, detail: album.location.isEmpty ? nil : album.location, link: .album(id: album.id)))
        }
        for name in library.people where Int(name) == nil && !hiddenPeople.contains(name) {
            entries.append(SpotlightEntry(kind: .person, title: name, detail: nil, link: .person(name: name)))
        }
        for place in library.places {
            let country = place.countryCode.flatMap { locale.localizedString(forRegionCode: $0) }
            entries.append(SpotlightEntry(kind: .place, title: place.name, detail: country, link: .place(name: place.name)))
        }
        return entries
    }

    /// Reads what can be indexed from an account's database.
    public static func library(_ database: AccountDatabase, collections: CollectionStore) throws -> Library {
        let albums = try collections.albums(.own) + collections.albums(.shared)
        return try database.writer.read { db in
            let people = try String.fetchAll(
                db, sql: "SELECT name FROM person WHERE name GLOB '*[^0-9]*' AND itemCount != 0 ORDER BY itemCount DESC")
            let places = try Row.fetchAll(
                db,
                sql: """
                    SELECT place, max(placeCountry) AS country FROM media
                    WHERE place IS NOT NULL AND place != '' AND isArchived = 0 AND isLivePhotoVideo = 0
                    GROUP BY place ORDER BY count(*) DESC
                    """
            ).map { row -> (name: String, countryCode: String?) in (row["place"], row["country"]) }
            return Library(albums: albums, people: people, places: places)
        }
    }
}

/// People hidden on this device (Recognize cannot hide a person on the server). The People screen writes the list
/// (`HiddenPeople`); Spotlight and the App Intents leave these people out.
public enum HiddenPeopleFile {
    public static func url(in accountDirectory: URL) -> URL { accountDirectory.appending(path: "hidden-people.json") }

    public static func names(in accountDirectory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url(in: accountDirectory)), let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }
}

/// Keeps the Spotlight items of the accounts (Core Spotlight, one domain per account). An account's items are replaced as
/// a whole when its library changed, and deleted when the account is logged out or wiped (`AppModel.purge`); all items go
/// while app lock is on.
public actor SpotlightIndexer {
    public static let shared = SpotlightIndexer(index: .default())

    private let index: CSSearchableIndex?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "spotlight")

    /// - Parameter index: nil in tests: nothing is sent to Spotlight.
    init(index: CSSearchableIndex?) {
        self.index = CSSearchableIndex.isIndexingAvailable() ? index : nil
    }

    /// The Spotlight domain of an account. A digest of the account id: domains are hierarchical with "." (deleting
    /// `a.b` would delete `a.b.c` too), and an id contains the server address.
    public static func domain(_ id: AccountID) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        return "account-\(digest)"
    }

    /// The Spotlight items of these entries.
    static func items(_ entries: [SpotlightEntry], account: Account) -> [CSSearchableItem] {
        entries.compactMap { entry in
            guard let url = entry.link.url(for: account) else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = entry.title
            attributes.displayName = entry.title
            attributes.contentDescription = [kindName(entry.kind), entry.detail].compactMap { $0 }.joined(separator: " · ")
            attributes.keywords = [entry.title] + (entry.detail.map { [$0] } ?? [])
            let item = CSSearchableItem(
                uniqueIdentifier: url.absoluteString, domainIdentifier: domain(account.id), attributeSet: attributes)
            // Removed again by the next pass when it is gone; the date only keeps a forgotten item from staying for ever.
            item.expirationDate = Date().addingTimeInterval(60 * 24 * 3600)
            return item
        }
    }

    static func kindName(_ kind: SpotlightEntry.Kind) -> String {
        switch kind {
        case .album: String(localized: "Album", bundle: .module, comment: "Spotlight: kind of a result that is an album.")
        case .person: String(localized: "Person", bundle: .module, comment: "Spotlight: kind of a result that is a person.")
        case .place: String(localized: "Place", bundle: .module, comment: "Spotlight: kind of a result that is a place.")
        }
    }

    /// Replaces the account's items with these entries.
    public func update(_ account: Account, entries: [SpotlightEntry]) async {
        guard let index else { return }
        let domain = Self.domain(account.id)
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
            let items = Self.items(entries, account: account)
            if !items.isEmpty { try await index.indexSearchableItems(items) }
            logger.info("spotlight: \(items.count) items indexed")
        } catch {
            logger.error("spotlight: indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes an account's items (logout, remote wipe).
    public func remove(_ id: AccountID) async {
        guard let index else { return }
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain(id)])
        } catch {
            logger.error("spotlight: removing an account failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes every item of the app (app lock turned on).
    public func removeAll() async {
        guard let index else { return }
        do {
            try await index.deleteAllSearchableItems()
        } catch {
            logger.error("spotlight: removing all items failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
