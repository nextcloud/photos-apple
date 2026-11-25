// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A short description of a photo, made on the device (SPEC §16.2): "A dog on a beach at sunset".
///
/// Vision says what is in the picture (`Facts`); where Apple Intelligence is available its language model writes the
/// sentence from the picture and those facts, in the user's language; elsewhere `compose` writes an English one from
/// the facts alone. Both are checked by `cleaned` before they are kept.
public enum PhotoDescription {
    /// What Vision found in a picture.
    public struct Facts: Equatable, Sendable {
        /// The classifier's identifiers with their confidence ("dog", "sunset_sunrise"), most confident first.
        public var labels: [(identifier: String, confidence: Float)]
        public var faceCount: Int
        /// Lines of text in the picture, the largest first.
        public var text: [String]

        public init(labels: [(identifier: String, confidence: Float)] = [], faceCount: Int = 0, text: [String] = []) {
            self.labels = labels.sorted { $0.confidence > $1.confidence }
            self.faceCount = faceCount
            self.text = text
        }

        public static func == (a: Facts, b: Facts) -> Bool {
            a.labels.map(\.identifier) == b.labels.map(\.identifier) && a.labels.map(\.confidence) == b.labels.map(\.confidence)
                && a.faceCount == b.faceCount && a.text == b.text
        }

        /// The labels as words ("sunset_sunrise" → "sunset sunrise").
        public var words: [String] { labels.map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() } }

        /// Whether there is anything to describe.
        public var isEmpty: Bool { labels.isEmpty && faceCount == 0 && text.isEmpty }
    }

    /// How a description was made.
    public enum Source: String, Sendable, Codable {
        /// The language model on this device (Apple Intelligence), from the picture and Vision's facts.
        case languageModel
        /// `compose`, from Vision's facts (English).
        case vision
    }

    /// The longest description kept; a longer one from the language model is cut at a word.
    public static let maximumLength = 140

    // MARK: Composing from facts (English)

    /// Labels too general to say anything ("animal" when "dog" is there, "outdoor", "structure").
    static let general: Set<String> = [
        "animal", "mammal", "canine", "feline", "vehicle", "structure", "outdoor", "indoor", "people", "adult", "person", "clothing",
        "material", "land", "plant", "food", "consumables", "liquid", "water_body", "conveyance", "machine", "textile", "wood_processed",
        "furniture", "housewares", "tool", "container", "decoration", "art", "document", "screenshot", "games", "sport", "recreation",
        "equipment", "accessory", "jewelry", "footwear", "headwear", "bag", "light", "sky", "cloudy", "blue_sky", "grass",
        "foliage", "tree", "shrub", "flower_arrangement", "people_crowd", "interior_room", "wall", "floor", "ceiling", "window",
        "road", "sidewalk", "building", "celebration", "event", "fun", "architecture", "cityscape_view", "daytime", "natural_light", "rock",
        "sand", "dirt",
    ]

    /// Scenes, with how they are said after the subject.
    static let scenes: [String: String] = [
        "beach": "on a beach", "shore": "on the shore", "coast": "on the coast", "ocean": "by the sea", "sea": "by the sea",
        "lake": "by a lake", "river": "by a river", "waterfall": "at a waterfall", "pool": "at a pool", "swimming_pool": "at a pool",
        "mountain": "in the mountains", "hill": "on a hill", "forest": "in a forest", "jungle": "in a jungle", "desert": "in the desert",
        "snow": "in the snow", "glacier": "on a glacier", "field": "in a field", "meadow": "in a meadow", "garden": "in a garden",
        "park": "in a park", "playground": "at a playground", "street": "on a street", "city": "in a city", "cityscape": "in a city",
        "bridge": "on a bridge", "harbour": "in a harbour", "harbor": "in a harbor", "kitchen": "in a kitchen",
        "restaurant": "in a restaurant", "bar": "in a bar", "cafe": "in a café", "living_room": "in a living room",
        "bedroom": "in a bedroom", "office": "in an office", "classroom": "in a classroom", "church": "in a church",
        "museum": "in a museum", "stadium": "at a stadium", "concert": "at a concert", "stage": "on a stage", "airport": "at an airport",
        "train_station": "at a station", "camping": "at a campsite", "tent": "by a tent", "boat": "on a boat", "island": "on an island",
        "canyon": "in a canyon", "volcano": "at a volcano", "cave": "in a cave", "farm": "on a farm", "vineyard": "in a vineyard",
        "wedding": "at a wedding", "party": "at a party", "birthday": "at a birthday", "underwater": "underwater",
    ]

    /// Light and time of day.
    static let times: [String: String] = [
        "sunset_sunrise": "at sunset", "sunset": "at sunset", "sunrise": "at sunrise", "night_sky": "at night", "night": "at night",
        "fireworks": "with fireworks", "rainbow": "with a rainbow", "aurora": "under the northern lights", "fog": "in the fog",
        "rain": "in the rain", "storm": "in a storm",
    ]

    /// Small numbers in words.
    static func count(_ n: Int) -> String {
        ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"][min(max(n, 0), 10)]
    }

    static func article(_ noun: String) -> String {
        guard let first = noun.first else { return noun }
        return ("aeiou".contains(first) ? "an " : "a ") + noun
    }

    /// An English sentence from what Vision found, nil when it found nothing worth saying.
    public static func compose(_ facts: Facts) -> String? {
        let identifiers = facts.labels.filter { $0.confidence >= 0.3 }.map(\.identifier)
        let scene = identifiers.lazy.compactMap { scenes[$0] }.first
        let time = identifiers.lazy.compactMap { times[$0] }.first
        let sceneKeys = Set(scenes.keys).union(times.keys)
        let things = identifiers.filter { !general.contains($0) && !sceneKeys.contains($0) }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
        var subject: String?
        switch facts.faceCount {
        case 0: break
        case 1: subject = "a person"
        case 2...6: subject = "\(count(facts.faceCount)) people"
        default: subject = "a group of people"
        }
        if let thing = things.first {
            subject = subject.map { "\($0) with \(article(thing))" } ?? article(thing)
        }
        var parts: [String] = []
        if let subject { parts.append(subject) }
        if let scene {
            parts.append(
                subject == nil ? scene.replacingOccurrences(of: #"^(on|in|at|by) "#, with: "", options: .regularExpression) : scene)
        }
        if let time { parts.append(time) }
        if let line = facts.text.first(where: { $0.count >= 3 }), parts.isEmpty || facts.text.joined().count >= 12 {
            let quoted = String(line.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(parts.isEmpty ? "text reading “\(quoted)”" : "with the text “\(quoted)”")
        }
        guard !parts.isEmpty else { return nil }
        var sentence = parts.joined(separator: " ")
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        return cleaned(sentence)
    }

    // MARK: Checking

    /// A description as it is kept: one line, no quotes around it, no trailing full stop, at most `maximumLength`
    /// characters (cut at a word). Nil when nothing useful is left (empty, or the model said it cannot see the picture).
    public static func cleaned(_ text: String) -> String? {
        var line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        // Quotes or emphasis around the whole answer.
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "*"]
        while line.count >= 2, let first = line.first, let last = line.last, quotes.contains(first), quotes.contains(last) {
            line = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["Description:", "Caption:", "Image:", "Photo:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        while line.hasSuffix(".") { line.removeLast() }
        guard line.count >= 3 else { return nil }
        let refusals = ["i'm sorry", "i am sorry", "i cannot", "i can't", "as an ai", "unable to"]
        let lowered = line.lowercased()
        if refusals.contains(where: lowered.hasPrefix) { return nil }
        if line.count > maximumLength {
            let cut = line.prefix(maximumLength)
            line = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
            line += "…"
        }
        return line
    }

    /// The words of a description for the search index and the vocabulary of `NaturalSearch`: lower case, without
    /// short filler words.
    public static func searchWords(_ description: String) -> [String] {
        FuzzyMatch.words(description).filter { $0.count >= 3 && !NaturalSearch.fillers.contains($0) }
    }
}
