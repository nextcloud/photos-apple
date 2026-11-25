// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Forgiving matching of typed words against names, for the command palette (SPEC §16.2): "lis" finds "Lisbon",
/// "lsbn" and "lisbn" too, "sum 19" finds "Summer 2019". Case and diacritics are ignored.
///
/// Every typed word must match one word of the name or of its keywords; a match scores
///  - 1.0 the whole word, 0.9 the start of a word, 0.75 the start of the name ("newal" for "New album"),
///  - 0.6 inside a word,
///  - 0.45 one typo in a word of at least four letters (a letter missing, added, changed or two swapped),
///  - 0.3 the letters in order with gaps (an abbreviation, "lsbn"), less the more scattered they are.
/// Keywords count three quarters of the name. The score of a name is the mean of its words' scores, with a small bonus
/// when the words come in the name's order; nil when a word matches nothing.
public enum FuzzyMatch {
    /// Lower case without diacritics, for comparing.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The words of a text: letters and digits, folded. "Women's Day" → ["women", "s", "day"].
    public static func words(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The score of `query` for a name with keywords (0…1.1), nil when it does not match.
    public static func score(_ query: String, name: String, keywords: [String] = []) -> Double? {
        score(words: words(query), name: name, keywords: keywords)
    }

    /// As `score(_:name:keywords:)` for words that are already folded.
    public static func score(words typed: [String], name: String, keywords: [String] = []) -> Double? {
        guard !typed.isEmpty else { return nil }
        let nameWords = words(name)
        let keywordWords = keywords.flatMap(words)
        let joined = nameWords.joined()
        var total = 0.0
        var positions: [Int] = []
        for word in typed {
            var best = 0.0
            var position = Int.max
            for (index, candidate) in nameWords.enumerated() {
                let value = wordScore(word, candidate)
                if value > best {
                    best = value
                    position = index
                }
            }
            // The start of the whole name, across its words: "newal" for "New album".
            if best < 0.75, nameWords.count > 1, joined.hasPrefix(word), word.count >= 3 {
                best = 0.75
                position = 0
            }
            for candidate in keywordWords {
                best = max(best, wordScore(word, candidate) * 0.75)
            }
            guard best > 0 else { return nil }
            total += best
            positions.append(position)
        }
        var result = total / Double(typed.count)
        // Words typed in the name's order rank above the same words in another order.
        let known = positions.filter { $0 != .max }
        if known.count > 1, known == known.sorted() { result += 0.05 }
        // A name the query covers completely ("lisbon" for "Lisbon") ranks above a longer one ("Lisbon airport").
        if typed.count == nameWords.count, typed == nameWords { result += 0.05 }
        // Of two names that match alike, the one with fewer other words first ("Lisbon" before "Lisbon 2025").
        result -= 0.01 * Double(min(max(nameWords.count - typed.count, 0), 4))
        return result
    }

    /// How well one typed word matches one word of a name.
    static func wordScore(_ typed: String, _ word: String) -> Double {
        if typed == word { return 1 }
        if word.hasPrefix(typed) { return 0.9 }
        if typed.count >= 2, word.contains(typed) { return 0.6 }
        if typed.count >= 4, isOneEditApart(typed, word) { return 0.45 }
        if typed.count >= 3, let spread = subsequenceSpread(typed, in: word) {
            // "lsbn" in "lisbon": 4 letters over 6 → 0.3 × 4/6.
            return 0.3 * Double(typed.count) / Double(spread)
        }
        return 0
    }

    /// Whether the two differ by one letter missing, added or changed, or two neighbours swapped. A word that only
    /// starts with a typo'd version of the typed one counts too ("lisbn" in "lisbon").
    static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a)
        let y = Array(b)
        if abs(x.count - y.count) > 1 {
            // A longer word: compare with its start of the same length (and one more), as a prefix.
            guard y.count > x.count else { return false }
            return isOneEditApart(a, String(y.prefix(x.count))) || isOneEditApart(a, String(y.prefix(x.count + 1)))
        }
        var i = 0
        var j = 0
        var edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count {
                i += 1
            } else if x.count < y.count {
                j += 1
            } else if i + 1 < x.count, j + 1 < y.count, x[i] == y[j + 1], x[i + 1] == y[j] {
                // Two neighbours swapped.
                i += 2
                j += 2
            } else {
                i += 1
                j += 1
            }
        }
        edits += (x.count - i) + (y.count - j)
        return edits <= 1
    }

    /// The length of the shortest stretch of `word` from its first letter that has the letters of `typed` in order,
    /// nil when they are not all there. Abbreviations start where the word starts.
    static func subsequenceSpread(_ typed: String, in word: String) -> Int? {
        let letters = Array(word)
        guard let first = typed.first, letters.first == first else { return nil }
        var index = 0
        var last = 0
        for character in typed {
            while index < letters.count, letters[index] != character { index += 1 }
            guard index < letters.count else { return nil }
            last = index
            index += 1
        }
        return last + 1
    }
}
