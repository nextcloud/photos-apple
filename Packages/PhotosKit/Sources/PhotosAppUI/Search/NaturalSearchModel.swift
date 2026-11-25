// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import FoundationModels
import PhotosDomain

/// Reads a search typed in words with Apple Intelligence's on-device language model (SPEC §16.2), to add what the
/// parser on its own does not know ("seaside", "my sister Anna", "pics from the trip to the coast"). The answer is
/// checked against what the library knows: names that are not people or places of the library, and dates that are not
/// dates, are dropped. Nothing leaves the device.
enum NaturalSearchModel {
    @Generable
    struct Request {
        @Guide(description: "\"videos\" for videos only, \"photos\" for still photos only, else \"any\"")
        var mediaType: String
        @Guide(description: "Names of people the photos show, only from the list of known people")
        var people: [String]
        @Guide(description: "Places the photos were taken at, only from the list of known places")
        var places: [String]
        @Guide(description: "Things or scenes the photos show, as simple English nouns such as beach, dog, sunset, snow")
        var things: [String]
        @Guide(description: "First day of the time asked for, YYYY-MM-DD, or empty")
        var startDate: String
        @Guide(description: "Last day of the time asked for, YYYY-MM-DD, or empty")
        var endDate: String
        @Guide(description: "true only when favourites are asked for")
        var favoritesOnly: Bool
        @Guide(description: "Least number of stars asked for, 0 to 5", .range(0...5))
        var minimumRating: Int
    }

    /// Whether the model can be used on this device now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func prompt(_ query: String, vocabulary: NaturalSearch.Vocabulary, today: Date) -> String {
        """
        Today is \(today.formatted(.iso8601.year().month().day())). Turn the search into photo filters. Leave out what \
        it does not ask for.
        Known people: \(vocabulary.people.prefix(200).joined(separator: ", ")).
        Known places: \(vocabulary.places.prefix(300).joined(separator: ", ")).
        Search: \(query)
        """
    }

    /// The chips the model reads in `query`, checked against `vocabulary`.
    static func filters(for query: String, vocabulary: NaturalSearch.Vocabulary, now: Date = Date()) async throws -> [SearchFilter] {
        let session = LanguageModelSession(instructions: "You turn searches of a personal photo library into filters.")
        let answer = try await session.respond(
            to: prompt(query, vocabulary: vocabulary, today: now), generating: Request.self,
            options: GenerationOptions(temperature: 0)
        ).content
        return validated(
            mediaType: answer.mediaType, people: answer.people, places: answer.places, things: answer.things, start: answer.startDate,
            end: answer.endDate, favorites: answer.favoritesOnly, rating: answer.minimumRating, vocabulary: vocabulary)
    }

    /// What the model said, as chips the library can answer.
    static func validated(
        mediaType: String, people: [String], places: [String], things: [String], start: String, end: String, favorites: Bool,
        rating: Int, vocabulary: NaturalSearch.Vocabulary, calendar: Calendar = .current, locale: Locale = .current
    ) -> [SearchFilter] {
        var result: [SearchFilter] = []
        switch mediaType.lowercased() {
        case "videos", "video": result.append(.videos)
        case "photos", "photo": result.append(.photos)
        default: break
        }
        func known(_ names: [String], in list: [String]) -> [String] {
            let byFolded = Dictionary(list.map { (FuzzyMatch.fold($0), $0) }, uniquingKeysWith: { first, _ in first })
            return names.compactMap { byFolded[FuzzyMatch.fold($0.trimmingCharacters(in: .whitespaces))] }
        }
        result += known(people, in: vocabulary.people).map { .person($0) }
        result += known(places, in: vocabulary.places).map { .place($0) }
        for thing in things.prefix(3) {
            let words = FuzzyMatch.words(thing)
            // A noun or two, not a sentence; words already understood as people or places are not things.
            guard (1...2).contains(words.count), words.allSatisfy({ $0.count >= 3 && !NaturalSearch.fillers.contains($0) }) else {
                continue
            }
            let label = words.joined(separator: " ")
            if result.contains(where: { $0.label.lowercased() == label }) { continue }
            result.append(.label(label))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = calendar.timeZone
        if let first = formatter.date(from: start) {
            let last = formatter.date(from: end.isEmpty ? start : end) ?? first
            let from = calendar.startOfDay(for: min(first, last))
            if let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(first, last))), to > from {
                let context = SearchDates.Context(calendar: calendar, locale: locale)
                result.append(.dateRange(start: from, end: to, label: SearchDates.describe(from..<to, context: context)))
            }
        }
        if favorites { result.append(.favorites) }
        if (1...5).contains(rating) { result.append(.rating(atLeast: rating)) }
        return result
    }
}
