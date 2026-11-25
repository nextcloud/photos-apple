// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The command palette (⌘K, SPEC §16.2): one field that goes anywhere and does anything — destinations, albums, people,
/// places, tags, years, commands, and searches typed in words ("Lisbon 2019", "favourites of Anna").
///
/// This is the part without UI: what an entry is, what typed words ask for, and the order of the entries.
public enum CommandPalette {
    /// What choosing an entry does.
    public enum Action: Hashable, Sendable {
        /// A place of the app (`AppDestination`'s raw value).
        case go(String)
        case openAlbum(id: String)
        case openPerson(String)
        case openPlace(String)
        case openTag(String)
        /// The search screen with these chips.
        case search([SearchFilter])
        /// A command of the app (`Command`).
        case command(Command)
        /// Adds the selected photos to the album.
        case addToAlbum(id: String, title: String)
        /// Gives the selected photos this many stars (0 clears the rating).
        case rate(Int)
        /// A page of the Mac's Settings window, or the settings screen elsewhere.
        case settings(String)
    }

    /// Commands. Those marked `needsSelection` act on the selected photos (or the photo the viewer shows).
    public enum Command: String, CaseIterable, Hashable, Sendable {
        case newAlbum, upload, importLibrary, importCard, openPublicLink, syncNow
        case toggleFavorite, addToAlbum, addToNewAlbum, delete, export, edit, editDateAndLocation, rotateLeft, rotateRight
        case getInfo, slideshow, compare, pick, reject, unflag, open

        public var needsSelection: Bool {
            switch self {
            case .newAlbum, .upload, .importLibrary, .importCard, .openPublicLink, .syncNow: false
            case .slideshow: false
            default: true
            }
        }
    }

    /// What kind of thing an entry is; the list says it at the end of the row.
    public enum Kind: Int, Hashable, Sendable, Comparable {
        case search, command, destination, album, person, place, tag, year, settings

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One entry of the palette.
    public struct Item: Hashable, Sendable, Identifiable {
        /// Stable across launches (recent entries are remembered by it).
        public var id: String
        public var title: String
        public var subtitle: String?
        public var systemImage: String
        /// Other words it is found by ("upload" for "Import Library…", "rename" for an album).
        public var keywords: [String]
        public var kind: Kind
        public var action: Action

        public init(
            id: String, title: String, subtitle: String? = nil, systemImage: String, keywords: [String] = [], kind: Kind, action: Action
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.keywords = keywords
            self.kind = kind
            self.action = action
        }

        public var needsSelection: Bool {
            switch action {
            case .command(let command): command.needsSelection
            case .addToAlbum, .rate: true
            default: false
            }
        }
    }

    // MARK: Intents

    /// What the words ask for beyond a name.
    public enum Intent: Equatable, Sendable {
        /// "add to Summer", "add to album Summer", "put in Summer": the selection into an album whose title matches.
        case addToAlbum(String)
        /// "rate 4", "4 stars", "★★★★": the selection's rating.
        case rate(Int)
    }

    public static func intent(_ query: String) -> Intent? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, typed.allSatisfy({ $0 == "★" }), typed.count <= 5 { return .rate(typed.count) }
        let words = FuzzyMatch.words(query)
        guard let first = words.first else { return nil }
        let rest: [String]
        if first == "add", words.count > 1, ["to", "into"].contains(words[1]) {
            rest = Array(words.dropFirst(2))
        } else if ["put", "move", "copy"].contains(first), words.count > 1, ["in", "into", "to"].contains(words[1]) {
            rest = Array(words.dropFirst(2))
        } else if first == "add", words.count > 1, !["to", "into"].contains(words[1]) {
            // "add summer".
            rest = Array(words.dropFirst())
        } else {
            rest = []
        }
        let album = rest.first == "album" ? Array(rest.dropFirst()) : rest
        if !album.isEmpty { return .addToAlbum(album.joined(separator: " ")) }
        if first == "rate", words.count > 1, let stars = Int(words[1]), (0...5).contains(stars) { return .rate(stars) }
        if words.count == 2, let stars = Int(words[0]), (0...5).contains(stars), ["star", "stars"].contains(words[1]) {
            return .rate(stars)
        }
        return nil
    }

    // MARK: Ranking

    /// The score of a name typed in full (`FuzzyMatch`: every word, and nothing more).
    static let exactScore = 1.05

    /// How many entries the list shows at most.
    public static let limit = 40
    /// How many recent entries are remembered.
    public static let recentLimit = 8

    /// The entries for `query`, best first.
    /// - Parameters:
    ///   - items: everything the palette knows (destinations, albums, people, places, tags, years, commands).
    ///   - recents: ids of recently chosen entries, newest first: shown first when nothing is typed, and a little
    ///     higher than others when something is.
    ///   - hasSelection: whether commands that act on a selection can run; without one they are left out.
    ///   - interpretation: the typed words read as a search (`NaturalSearch`); with two or more chips it is the first
    ///     entry ("Lisbon · 2019").
    ///   - makeSearchItem: the entry that searches for chips (its title is the UI's).
    public static func rank(
        _ query: String, items: [Item], recents: [String], hasSelection: Bool, interpretation: NaturalSearch.Interpretation? = nil,
        extra: [Item] = []
    ) -> [Item] {
        let usable = (items + extra).filter { hasSelection || !$0.needsSelection }
        let typed = FuzzyMatch.words(query)
        if typed.isEmpty {
            let byId = Dictionary(usable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recent = recents.compactMap { byId[$0] }
            let recentIds = Set(recent.map(\.id))
            // Then: what acts on the selection, then the main places.
            let selectionCommands = hasSelection ? usable.filter { $0.needsSelection && $0.kind == .command } : []
            let places = usable.filter { $0.kind == .destination }
            var seen = recentIds
            var result = recent
            for item in selectionCommands + places where seen.insert(item.id).inserted { result.append(item) }
            return Array(result.prefix(limit))
        }
        var scored: [(item: Item, score: Double)] = []
        for item in usable {
            guard var score = FuzzyMatch.score(words: typed, name: item.title, keywords: item.keywords) else { continue }
            if let position = recents.firstIndex(of: item.id) {
                score += 0.12 * (1 - Double(position) / Double(max(recentLimit, recents.count)))
            }
            // Commands on a selection come first while there is one; entries added for the typed words (an album to add
            // to) are what was asked for.
            if hasSelection, item.needsSelection { score += 0.04 }
            if extra.contains(where: { $0.id == item.id }) { score += 0.3 }
            scored.append((item, score))
        }
        if let interpretation,
            interpretation.filters.filter(\.isStructured).count >= 2 || (interpretation.isStructured && interpretation.text != nil)
        {
            // Several chips: what the words say as a whole beats every single name.
            // Unless a name is exactly what was typed ("Lisbon 2025" the album): then the search comes right after it.
            let best = scored.map(\.score).max() ?? 0
            scored.append((searchItem(interpretation.filters, title: nil), best >= exactScore ? best - 0.01 : max(best, 1) + 0.2))
        }
        let ordered = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.item.kind != b.item.kind { return a.item.kind < b.item.kind }
            return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }
        var seen = Set<String>()
        return ordered.map(\.item).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// The entry that searches for chips. Its title is the chips' labels ("Lisbon · 2019") unless one is given.
    public static func searchItem(_ filters: [SearchFilter], title: String?) -> Item {
        Item(
            id: "search:" + filters.map(\.id).joined(separator: "|"), title: title ?? filters.map(\.label).joined(separator: " · "),
            systemImage: "magnifyingglass", kind: .search, action: .search(filters))
    }

    /// The entries to add the selection to albums whose title matches `name`, best first (at most 5).
    public static func albumTargets(_ name: String, albums: [(id: String, title: String)], make: (String, String) -> Item) -> [Item] {
        let typed = FuzzyMatch.words(name)
        let scored: [(Item, Double)] = albums.compactMap { album in
            FuzzyMatch.score(words: typed, name: album.title).map { (make(album.id, album.title), $0) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }

    /// `recents` with `id` on top, at most `recentLimit`.
    public static func remembering(_ id: String, in recents: [String]) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(recentLimit))
    }
}
