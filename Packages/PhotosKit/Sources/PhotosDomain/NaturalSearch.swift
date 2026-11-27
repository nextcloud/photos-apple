// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Turns what people type into filter chips, on the device and without a language model (SPEC §16.2):
/// "videos of Anna at the beach last summer" → Videos · Anna · beach · Summer 2026.
///
/// Read from left to right; at each word the longest of these wins:
///  1. a date (`SearchDates`),
///  2. a rating ("5 stars", "4+ stars", "★★★", "rated 3"),
///  3. a media kind or favourites ("videos", "photos only", "favourites"),
///  4. a name the library knows: a person (also by first name when only one person has it), a place, a tag, an album
///     (only next to the word "album"), a camera (also by its model alone: "x100v") or lens, or something photos show
///     (the labels this device recognised, and common words),
///  5. a filler word ("of", "at", "the", "photos"…), which is dropped.
/// The words that are left become one free-text chip, so plain text keeps working as before. A person comes first after
/// "with" or "of", a place after "in", "at" or "from".
public enum NaturalSearch {
    public struct Vocabulary: Sendable {
        public var places: [String]
        public var people: [String]
        public var tags: [(id: Int, name: String)]
        public var albums: [(id: String, title: String)]
        /// Things photos show, as the on-device labels name them (English, lower case): "dog", "beach".
        public var labels: [String]
        /// Cameras and lenses the photos were taken with (SPEC §22.3).
        public var cameras: [String]
        public var lenses: [String]

        public init(
            places: [String] = [], people: [String] = [], tags: [(id: Int, name: String)] = [], albums: [(id: String, title: String)] = [],
            labels: [String] = [], cameras: [String] = [], lenses: [String] = []
        ) {
            self.places = places
            self.people = people
            self.tags = tags
            self.albums = albums
            self.labels = labels
            self.cameras = cameras
            self.lenses = lenses
        }

        public init(_ suggestions: SearchSuggestions.Vocabulary, labels: [String] = []) {
            self.init(
                places: suggestions.places, people: suggestions.people, tags: suggestions.tags, albums: suggestions.albums, labels: labels,
                cameras: suggestions.cameras, lenses: suggestions.lenses)
        }
    }

    /// What was understood.
    public struct Interpretation: Equatable, Sendable {
        public var filters: [SearchFilter]

        public init(filters: [SearchFilter]) {
            self.filters = filters
        }

        /// Whether anything more than free text was understood.
        public var isStructured: Bool { filters.contains(where: \.isStructured) }
        /// The free text that is left, if any.
        public var text: String? {
            for filter in filters { if case .text(let text) = filter { return text } }
            return nil
        }
    }

    /// Words that only join the others.
    public static let fillers: Set<String> = [
        "a", "an", "the", "of", "with", "and", "&", "at", "in", "on", "from", "during", "near", "around", "by", "my", "our", "me",
        "us", "show", "find", "all", "any", "some", "photos", "photo", "pictures", "picture", "pics", "pic", "images", "image",
        "shots", "shot", "taken", "that", "which", "were", "was", "is", "are", "to", "for", "where", "when", "who", "while",
        "having", "had", "has", "doing", "being", "together", "everything", "stuff", "things", "or",
    ]

    /// Words for favourites.
    static let favoriteWords: Set<String> = [
        "favorite", "favorites", "favourite", "favourites", "faves", "fave", "fav", "favs", "loved", "hearted", "liked",
    ]
    static let videoWords: Set<String> = ["video", "videos", "movie", "movies", "clip", "clips", "film", "films", "footage"]
    static let stillWords: Set<String> = ["still", "stills"]
    static let personPrepositions: Set<String> = ["with", "of", "featuring", "and"]
    static let placePrepositions: Set<String> = ["in", "at", "from", "near", "around", "to"]

    /// Things photos often show, so that a typed one becomes a "shows" chip even before this device has recognised
    /// anything. The on-device labels add to these.
    public static let commonLabels: Set<String> = [
        "animal", "baby", "beach", "bicycle", "bike", "bird", "boat", "book", "bridge", "building", "cake", "car", "castle",
        "cat", "child", "children", "church", "city", "cliff", "cloud", "clouds", "coast", "concert", "desert", "dog",
        "drink", "fireworks", "flower", "flowers", "food", "forest", "garden", "glacier", "grass", "harbor", "hiking", "horse",
        "ice", "island", "kitchen", "lake", "landscape", "leaf", "leaves", "lighthouse", "monument", "moon", "mountain", "museum",
        "night", "ocean", "park", "party", "pizza", "plant", "pool", "portrait", "rain", "restaurant", "river", "road", "sand",
        "sea", "selfie", "screenshot", "sky", "skyline", "snow", "sport", "stadium", "street", "sun", "sunrise", "sunset",
        "swimming", "temple", "train", "tree", "trees", "valley", "waterfall", "water", "wedding", "wildlife", "window", "winter",
        "document", "receipt", "car", "plane", "airplane", "aircraft", "skiing", "surfing", "camping", "tent", "puppy", "kitten",
    ]

    /// Reads `query` (see the type's documentation).
    public static func interpret(
        _ query: String, vocabulary: Vocabulary, context: SearchDates.Context = SearchDates.Context()
    ) -> Interpretation {
        let original = tokens(query)
        let words = original.map(fold)
        var filters: [SearchFilter] = []
        var leftover: [String] = []
        let names = NameIndex(vocabulary)
        var index = 0
        func add(_ filter: SearchFilter) {
            if !filters.contains(filter) { filters.append(filter) }
        }
        while index < words.count {
            let word = words[index]
            let previous = index > 0 ? words[index - 1] : nil
            // "album Summer": the album, not the season.
            if word == "album" || word == "albums", index + 1 < words.count,
                case let (filter, length)? = names.match(words, at: index + 1, previous: word), case .album = filter
            {
                add(filter)
                index += 1 + length
                continue
            }
            let name = names.match(words, at: index, previous: previous)
            let date = SearchDates.match(words, at: index, context: context)
            if case let (filter, length)? = name, date == nil || NameIndex.wins(filter, length: length, over: date, previous: previous) {
                add(filter)
                index += length
                continue
            }
            if let date {
                add(date.filter)
                index += date.length
                continue
            }
            if case let (stars, length)? = rating(words, at: index) {
                filters.removeAll { if case .rating = $0 { true } else { false } }
                add(.rating(atLeast: stars))
                index += length
                continue
            }
            if favoriteWords.contains(word) {
                add(.favorites)
                index += 1
                continue
            }
            if videoWords.contains(word) {
                add(.videos)
                index += 1
                continue
            }
            if let length = stillPhotos(words, at: index) {
                add(.photos)
                index += length
                continue
            }
            if fillers.contains(word) || word.isEmpty {
                index += 1
                continue
            }
            if let label = names.label(word) {
                add(.label(label))
                index += 1
                continue
            }
            leftover.append(original[index])
            index += 1
        }
        if !leftover.isEmpty { filters.append(.text(leftover.joined(separator: " "))) }
        return Interpretation(filters: filters)
    }

    /// What a language model understood, added to what `interpret` read: the parser's dates and names stay (they are
    /// exact); the model adds what the parser did not have ("seaside" → beach, a person called by a nickname). When it
    /// added something and the parser had words left over, the model is taken to have understood them and the free
    /// text goes.
    public static func merge(_ parsed: Interpretation, model: [SearchFilter]) -> Interpretation {
        var result = parsed.filters.filter(\.isStructured)
        func kind(_ filter: SearchFilter) -> String {
            switch filter {
            case .dateRange: "date"
            case .videos, .photos: "media"
            case .rating: "rating"
            default: filter.id
            }
        }
        let present = Set(result.map(kind))
        var added = false
        for filter in model where filter.isStructured && !present.contains(kind(filter)) && !result.contains(filter) {
            result.append(filter)
            added = true
        }
        if let text = parsed.text, !added { result.append(.text(text)) }
        return Interpretation(filters: result)
    }

    // MARK: Words

    /// The words of the query as typed, without the punctuation around them. Typographic apostrophes become plain ones.
    static func tokens(_ query: String) -> [String] {
        query.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "?" || $0 == "!" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”()[].:")) }
            .filter { !$0.isEmpty }
    }

    static func fold(_ word: String) -> String { FuzzyMatch.fold(word) }

    /// "anna's" → "anna".
    static func withoutPossessive(_ word: String) -> String {
        if word.hasSuffix("'s") { return String(word.dropLast(2)) }
        if word.hasSuffix("s'") { return String(word.dropLast(1)) }
        return word
    }

    /// The singular of an English plural: "beaches" → "beach", "puppies" → "puppy", "dogs" → "dog".
    static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        for ending in ["ches", "shes", "sses", "xes"] where word.hasSuffix(ending) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }

    /// "5 stars", "5-star", "five star", "4+ stars", "★★★", "rated 3", "3 stars or more", "at least 4 stars".
    static func rating(_ words: [String], at index: Int) -> (Int, Int)? {
        let word = words[index]
        if !word.isEmpty, word.allSatisfy({ $0 == "★" || $0 == "*" || $0 == "+" }), word.contains(where: { $0 != "+" }) {
            let stars = word.filter { $0 != "+" }.count
            return (1...5).contains(stars) ? (stars, 1) : nil
        }
        var start = index
        var length = 0
        if word == "rated", index + 1 < words.count, let n = SearchDates.number(words[index + 1]), (1...5).contains(n) {
            var used = 2
            if index + 2 < words.count, ["star", "stars"].contains(words[index + 2]) { used = 3 }
            return (n, used)
        }
        if word == "at", index + 2 < words.count, words[index + 1] == "least" {
            start = index + 2
            length = 2
        }
        guard start < words.count else { return nil }
        let first = words[start]
        // "5-star", "4+".
        let compact = first.replacingOccurrences(of: "-star", with: "").replacingOccurrences(of: "-stars", with: "")
        let digits = compact.hasSuffix("+") ? String(compact.dropLast()) : compact
        guard let n = SearchDates.number(digits), (1...5).contains(n), digits != "a", digits != "an" else { return nil }
        if first.hasSuffix("-star") || first.hasSuffix("-stars") {
            return (n, length + 1)
        }
        guard start + 1 < words.count, ["star", "stars", "★"].contains(words[start + 1]) else { return nil }
        length += 2
        // "3 stars or more", "3 stars or better", "3 stars and up".
        if start + 3 < words.count, ["or", "and"].contains(words[start + 2]), ["more", "better", "up", "above"].contains(words[start + 3]) {
            length += 2
        }
        return (n, length)
    }

    /// "photos only", "only photos", "still photos", "stills".
    static func stillPhotos(_ words: [String], at index: Int) -> Int? {
        let photoWords: Set<String> = ["photos", "photo", "pictures", "pics", "images"]
        let word = words[index]
        if stillWords.contains(word) {
            if index + 1 < words.count, photoWords.contains(words[index + 1]) { return 2 }
            return 1
        }
        if word == "only", index + 1 < words.count, photoWords.contains(words[index + 1]) { return 2 }
        if photoWords.contains(word), index + 1 < words.count, words[index + 1] == "only" { return 2 }
        if word == "no", index + 1 < words.count, videoWords.contains(words[index + 1]) { return 2 }
        return nil
    }

    // MARK: Names

    /// The names the library knows, by their first word.
    struct NameIndex {
        enum Kind: Int {
            case person, place, tag, album, camera
        }

        struct Entry {
            var words: [String]
            var filter: SearchFilter
            var kind: Kind
        }

        var byFirstWord: [String: [Entry]] = [:]
        var labels: Set<String>

        init(_ vocabulary: Vocabulary) {
            labels = commonLabels.union(vocabulary.labels.map(NaturalSearch.fold))
            var firstNames: [String: [String]] = [:]
            for person in vocabulary.people {
                insert(person, .person(person), .person)
                if let first = FuzzyMatch.words(person).first, FuzzyMatch.words(person).count > 1 {
                    firstNames[first, default: []].append(person)
                }
            }
            // A first name stands for the person when only one person has it.
            for (first, people) in firstNames
            where people.count == 1 && byFirstWord[first]?.contains(where: { $0.words.count == 1 }) != true {
                byFirstWord[first, default: []].append(Entry(words: [first], filter: .person(people[0]), kind: .person))
            }
            for place in vocabulary.places { insert(place, .place(place), .place) }
            for tag in vocabulary.tags { insert(tag.name, .tag(id: tag.id, name: tag.name), .tag) }
            for album in vocabulary.albums { insert(album.title, .album(id: album.id, title: album.title), .album) }
            // A camera also by its model alone ("x100v", "eos r5"), when no other camera has that model name.
            var models: [[String]: [String]] = [:]
            for camera in vocabulary.cameras {
                insert(camera, .camera(camera), .camera)
                let words = FuzzyMatch.words(camera)
                if words.count > 1 { models[Array(words.dropFirst()), default: []].append(camera) }
            }
            for (words, cameras) in models where cameras.count == 1 {
                byFirstWord[words[0], default: []].append(Entry(words: words, filter: .camera(cameras[0]), kind: .camera))
            }
            for lens in vocabulary.lenses { insert(lens, .lens(lens), .camera) }
        }

        mutating func insert(_ name: String, _ filter: SearchFilter, _ kind: Kind) {
            let words = FuzzyMatch.words(name)
            guard let first = words.first else { return }
            byFirstWord[first, default: []].append(Entry(words: words, filter: filter, kind: kind))
        }

        /// The longest known name at `index`. Albums only right after or before the word "album".
        func match(_ typed: [String], at index: Int, previous: String?) -> (SearchFilter, Int)? {
            // Names are compared word by word without punctuation: "anna's" → "anna", "são" → "sao".
            let words = typed[index...].map { FuzzyMatch.words(NaturalSearch.withoutPossessive($0)).joined(separator: " ") }
            guard let first = words.first, !first.isEmpty else { return nil }
            let afterAlbum = previous == "album" || previous == "albums"
            let candidates = (byFirstWord[first] ?? []).filter { entry in
                guard entry.words.count <= words.count else { return false }
                // An album counts only next to the word "album" ("Lisbon 2025" the album must not hide Lisbon the place).
                if entry.kind == .album, !afterAlbum,
                    !(index + entry.words.count < typed.count && ["album", "albums"].contains(typed[index + entry.words.count]))
                {
                    return false
                }
                return Array(words.prefix(entry.words.count)).flatMap { $0.split(separator: " ").map(String.init) } == entry.words
            }
            guard !candidates.isEmpty else { return nil }
            let longest = candidates.map(\.words.count).max() ?? 0
            let best = candidates.filter { $0.words.count == longest }
            let beforeAlbum = index + longest < typed.count && ["album", "albums"].contains(typed[index + longest])
            func rank(_ entry: Entry) -> Int {
                switch entry.kind {
                case .album: return afterAlbum || beforeAlbum ? -1 : 100
                case .person: return personPrepositions.contains(previous ?? "") ? 0 : 1
                case .place: return placePrepositions.contains(previous ?? "") ? 0 : 2
                case .tag: return 3
                case .camera: return 4
                }
            }
            guard let chosen = best.min(by: { rank($0) < rank($1) }), rank(chosen) < 100 else { return nil }
            // "summer album": the word "album" goes with it.
            let length = chosen.kind == .album && beforeAlbum ? longest + 1 : longest
            return (chosen.filter, length)
        }

        /// Whether a name wins over a date at the same place: an album next to the word "album", a person after "with"
        /// ("with Jan", not January), a place after "in", or a name that is longer.
        static func wins(_ filter: SearchFilter, length: Int, over date: SearchDates.Match?, previous: String?) -> Bool {
            guard let date else { return true }
            if length > date.length { return true }
            switch filter {
            case .album: return true
            case .person: return personPrepositions.contains(previous ?? "")
            case .place: return placePrepositions.contains(previous ?? "")
            default: return false
            }
        }

        /// The label a word stands for: itself or its singular, when photos are known to show it.
        func label(_ word: String) -> String? {
            if labels.contains(word) { return word }
            let one = NaturalSearch.singular(word)
            return labels.contains(one) ? one : nil
        }
    }
}
