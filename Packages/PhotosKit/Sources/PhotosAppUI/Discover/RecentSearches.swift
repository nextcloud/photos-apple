// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosCore
import PhotosDomain
import PhotosModel

/// The last searches of an account, newest first (SPEC §7.7). Kept in the account's directory, so they go with the
/// account when it is removed.
struct RecentSearches: Equatable {
    static let limit = 8

    /// One search: its filter chips.
    private(set) var entries: [[SearchFilter]] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Puts a search on top. The same filters in another order are the same search.
    mutating func add(_ filters: [SearchFilter]) {
        guard !filters.isEmpty else { return }
        let key = Self.key(filters)
        entries.removeAll { Self.key($0) == key }
        entries.insert(filters, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    mutating func remove(_ filters: [SearchFilter]) {
        let key = Self.key(filters)
        entries.removeAll { Self.key($0) == key }
    }

    mutating func clear() { entries = [] }

    static func key(_ filters: [SearchFilter]) -> String { filters.map(\.id).sorted().joined(separator: "\n") }

    /// What a search is called in the list.
    static func title(_ filters: [SearchFilter]) -> String { filters.map(\.label).joined(separator: ", ") }

    // MARK: Storage

    /// A filter as it is written to disk.
    struct Stored: Codable, Equatable {
        var kind: String
        var text: String?
        var id: String?
        var start: Double?
        var end: Double?

        init(_ filter: SearchFilter) {
            switch filter {
            case .place(let name): (kind, text) = ("place", name)
            case .person(let name): (kind, text) = ("person", name)
            case .tag(let tagId, let name): (kind, text, id) = ("tag", name, String(tagId))
            case .album(let albumId, let title): (kind, text, id) = ("album", title, albumId)
            case .dateRange(let from, let to, let label):
                (kind, text, start, end) = ("date", label, from.timeIntervalSince1970, to.timeIntervalSince1970)
            case .text(let value): (kind, text) = ("text", value)
            case .favorites: kind = "favorites"
            case .videos: kind = "videos"
            }
        }

        /// Nil for a kind written by a newer version of the app.
        var filter: SearchFilter? {
            switch kind {
            case "place": text.map { .place($0) }
            case "person": text.map { .person($0) }
            case "tag": if let text, let id, let tagId = Int(id) { .tag(id: tagId, name: text) } else { nil }
            case "album": if let text, let id { .album(id: id, title: text) } else { nil }
            case "date":
                if let text, let start, let end {
                    .dateRange(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), label: text)
                } else {
                    nil
                }
            case "text": text.map { .text($0) }
            case "favorites": .favorites
            case "videos": .videos
            default: nil
            }
        }
    }

    init(entries: [[SearchFilter]] = []) {
        for filters in entries.reversed() { add(filters) }
    }

    init(data: Data) {
        let stored = (try? JSONDecoder().decode([[Stored]].self, from: data)) ?? []
        // A search with a filter this version does not know would mean something else without it: leave it out.
        let known: [[SearchFilter]] = stored.compactMap { search in
            let filters = search.compactMap(\.filter)
            return filters.count == search.count ? filters : nil
        }
        self.init(entries: known)
    }

    var data: Data { (try? JSONEncoder().encode(entries.map { $0.map(Stored.init) })) ?? Data("[]".utf8) }

    static func file(account: AccountID, layout: StorageLayout) -> URL {
        layout.accountDirectory(account).appending(path: "recent-searches.json")
    }

    static func load(account: AccountID, layout: StorageLayout) -> RecentSearches {
        guard let data = try? Data(contentsOf: file(account: account, layout: layout)) else { return RecentSearches() }
        return RecentSearches(data: data)
    }

    func save(account: AccountID, layout: StorageLayout) {
        let file = Self.file(account: account, layout: layout)
        if isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// What Return in the search field searches for.
enum SearchCommit {
    /// The top suggestion that is not a filter yet, else the typed text as a free-text search.
    static func filter(for typed: String, suggestions: [SearchFilter], active: [SearchFilter]) -> SearchFilter? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let top = suggestions.first(where: { !active.contains($0) }) { return top }
        let free = SearchFilter.text(text)
        return active.contains(free) ? nil : free
    }
}

/// Return in a search field. The field belongs to the window (the Mac's toolbar) or the tab; the search screen, which
/// knows the suggestions, listens here.
@MainActor
@Observable
final class SearchSubmission {
    static let shared = SearchSubmission()
    private(set) var count = 0

    func submit() { count += 1 }
}
