// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A search filter chip (SPEC SR-1/SR-2).
public enum SearchFilter: Hashable, Sendable, Identifiable {
    case place(String)
    case person(String)
    case tag(id: Int, name: String)
    case album(id: String, title: String)
    case dateRange(start: Date, end: Date, label: String)
    case text(String)
    case favorites
    case videos

    public var id: String {
        switch self {
        case .place(let name): "place:\(name)"
        case .person(let name): "person:\(name)"
        case .tag(let id, _): "tag:\(id)"
        case .album(let id, _): "album:\(id)"
        case .dateRange(let start, let end, _): "date:\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
        case .text(let text): "text:\(text)"
        case .favorites: "favorites"
        case .videos: "videos"
        }
    }

    public var label: String {
        switch self {
        case .place(let name), .person(let name), .text(let name): name
        case .tag(_, let name): name
        case .album(_, let title): title
        case .dateRange(_, _, let label): label
        case .favorites: String(localized: "Favorites", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        }
    }
}

/// Suggestion groups for the search field (web: searchSuggestions.ts).
public enum SearchSuggestions {
    public static let perGroup = 6

    public struct Vocabulary: Sendable {
        public var places: [String]
        public var people: [String]
        public var tags: [(id: Int, name: String)]
        public var albums: [(id: String, title: String)]

        public init(
            places: [String] = [], people: [String] = [], tags: [(id: Int, name: String)] = [], albums: [(id: String, title: String)] = []
        ) {
            self.places = places
            self.people = people
            self.tags = tags
            self.albums = albums
        }
    }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Prefix matches first, then substring matches, at most 6.
    static func matches(_ names: [String], _ query: String) -> [String] {
        let q = fold(query)
        let folded = names.map { ($0, fold($0)) }
        let prefix = folded.filter { $0.1.hasPrefix(q) }.map(\.0)
        let contains = folded.filter { !$0.1.hasPrefix(q) && $0.1.contains(q) }.map(\.0)
        return Array((prefix.sorted() + contains.sorted()).prefix(perGroup))
    }

    public static func suggestions(
        for query: String, vocabulary: Vocabulary, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    )
        -> [SearchFilter]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [SearchFilter] = []
        result += dateFilters(trimmed, now: now, calendar: calendar, locale: locale)
        result += matches(vocabulary.places, trimmed).map { .place($0) }
        result += matches(vocabulary.people, trimmed).map { .person($0) }
        let tagNames = matches(vocabulary.tags.map(\.name), trimmed)
        result += tagNames.compactMap { name in vocabulary.tags.first { $0.name == name }.map { .tag(id: $0.id, name: name) } }
        let albumTitles = matches(vocabulary.albums.map(\.title), trimmed)
        result += albumTitles.compactMap { title in vocabulary.albums.first { $0.title == title }.map { .album(id: $0.id, title: title) } }
        result.append(.text(trimmed))
        return result
    }

    /// "2023" → that year; "jun 2023" / "june" → months (without year: the last 3 years in which that month has started).
    public static func dateFilters(_ query: String, now: Date, calendar: Calendar, locale: Locale) -> [SearchFilter] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let year = words.compactMap { Int($0) }.first { $0 >= 1900 && $0 <= calendar.component(.year, from: now) }
        let monthWord = words.first { Int($0) == nil }
        var month: Int?
        if let monthWord, monthWord.count >= 3 {
            let symbols = DateFormatter()
            symbols.locale = locale
            let names = (symbols.monthSymbols ?? []).map { fold($0) }
            let short = (symbols.shortMonthSymbols ?? []).map { fold($0.replacingOccurrences(of: ".", with: "")) }
            let word = fold(monthWord)
            month = names.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 } ?? short.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 }
        }
        func range(year: Int, month: Int?) -> SearchFilter? {
            guard let start = calendar.date(from: DateComponents(year: year, month: month ?? 1, day: 1)),
                let end = calendar.date(byAdding: month == nil ? .year : .month, value: 1, to: start)
            else { return nil }
            let label =
                month == nil
                ? String(year) : start.formatted(Date.FormatStyle(locale: locale).month(.wide).year())
            return .dateRange(start: start, end: end, label: label)
        }
        if let month {
            if let year { return range(year: year, month: month).map { [$0] } ?? [] }
            let currentYear = calendar.component(.year, from: now)
            let currentMonth = calendar.component(.month, from: now)
            let firstYear = month <= currentMonth ? currentYear : currentYear - 1
            return (0..<3).compactMap { range(year: firstYear - $0, month: month) }
        }
        if let year, words.count == 1 { return range(year: year, month: nil).map { [$0] } ?? [] }
        return []
    }
}
