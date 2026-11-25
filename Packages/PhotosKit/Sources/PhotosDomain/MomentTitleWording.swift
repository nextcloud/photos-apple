// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the on-device language model is told about a moment, and what of its answer is kept (SPEC §16.1). The model
/// only words a title; it is given nothing but the moment's facts, and an answer that is too long, names a year, or
/// leaves out the place or person the facts are about is thrown away (the rule title stays).
public enum MomentTitleWording {
    public static let maximumCharacters = 40
    public static let maximumWords = 6

    /// The instructions of the session: what a good title is, in the user's language.
    public static func instructions(locale: Locale = .current) -> String {
        let language =
            Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "en") ?? "English"
        return """
            You write short titles for moments of a personal photo library, like "Sunday in Lisbon", "Anna's birthday" or \
            "Hike near Zermatt". A title has at most five words, no date, no year, no emoji, no hashtags and no quotation \
            marks. Use only the names and places given in the facts; never invent any. Write the title in \(language).
            """
    }

    /// The facts of one moment, in English (the model's instructions say which language to answer in).
    public static func prompt(_ facts: MomentFacts, calendar: Calendar = .current) -> String {
        let english = Locale(identifier: "en_US")
        let day = Date.FormatStyle(locale: english, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide).day().month(.wide)
        var lines: [String] = []
        if facts.days == 1 {
            lines.append("When: \(facts.end.formatted(day)), one day")
        } else {
            lines.append("When: \(facts.days) days, \(facts.start.formatted(day)) to \(facts.end.formatted(day))")
        }
        if let place = facts.places.first {
            let others = facts.places.dropFirst().joined(separator: ", ")
            let country = facts.country.map { ", \($0)" } ?? ""
            lines.append(
                "Where: \(place)\(country)\(others.isEmpty ? "" : " (also \(others))")\(facts.isAway ? ", away from home" : ", at home")")
        }
        if !facts.people.isEmpty { lines.append("People: \(facts.people.joined(separator: ", "))") }
        if !facts.activities.isEmpty { lines.append("Seen in the photos: \(facts.activities.map(Self.words).joined(separator: ", "))") }
        lines.append("Write one title for this moment.")
        return lines.joined(separator: "\n")
    }

    static func words(_ activity: MomentActivity) -> String {
        switch activity {
        case .birthday: "a birthday cake"
        case .wedding: "a wedding"
        case .christmas: "Christmas decorations"
        case .hike: "hiking"
        case .mountains: "mountains"
        case .beach: "a beach"
        case .skiing: "skiing"
        case .snow: "snow"
        case .concert: "a concert"
        case .camping: "camping"
        }
    }

    /// The model's answer made into a title, or nil when it is not one this app shows.
    public static func cleaned(_ answer: String, facts: MomentFacts) -> String? {
        var title = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = CharacterSet(charactersIn: "\"'“”„‚‘’«»「」*")
        title = title.trimmingCharacters(in: quotes.union(.whitespaces))
        if title.hasSuffix(".") || title.hasSuffix("!") { title.removeLast() }
        title = title.trimmingCharacters(in: quotes.union(.whitespaces))
        guard !title.isEmpty, title.count <= maximumCharacters, !title.contains(where: \.isNewline) else { return nil }
        guard title.split(whereSeparator: \.isWhitespace).count <= maximumWords else { return nil }
        guard !title.contains("#"), !title.contains("@"), !title.unicodeScalars.contains(where: Self.isEmoji) else { return nil }
        // A year or a date is the header's job (and often wrong).
        guard title.range(of: #"\d{3,}|\d+[./]\d+"#, options: .regularExpression) == nil else { return nil }
        // The moment's main person (for a birthday) or place must be in it: otherwise the model wandered off.
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func mentions(_ name: String) -> Bool {
            folded.contains(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
        if facts.activities.first == .birthday, let person = facts.people.first {
            return mentions(person) ? title : nil
        }
        if facts.isAway, !facts.places.isEmpty, facts.activities.first != .christmas {
            return facts.places.contains(where: mentions) || facts.people.contains(where: mentions) ? title : nil
        }
        if facts.places.isEmpty || !facts.isAway, !facts.people.isEmpty, facts.activities.isEmpty {
            return facts.people.contains(where: mentions) ? title : nil
        }
        return title
    }

    static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
    }
}
