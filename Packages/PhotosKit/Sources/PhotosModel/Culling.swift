// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Pick, reject or neither: the flag of a photo while culling (SPEC §15.2).
public enum CullingFlag: String, Codable, Sendable, CaseIterable {
    case none, pick, reject
}

/// The rating and flag of one photo. Kept on the server as collaborative system tags (`CullingTags`), so every device
/// and the web see the same.
public struct CullingMark: Hashable, Sendable, Codable {
    /// 0 (unrated) to 5 stars.
    public var rating: Int
    public var flag: CullingFlag

    public init(rating: Int = 0, flag: CullingFlag = .none) {
        self.rating = min(max(rating, 0), CullingTags.maxRating)
        self.flag = flag
    }

    public static let none = CullingMark()

    public var isEmpty: Bool { rating == 0 && flag == .none }
}

/// The system tags that hold ratings and flags. The names are the same on every device and in every language (the
/// server knows nothing else of them); the app shows them in the user's language.
public enum CullingTags {
    public static let maxRating = 5
    /// "Pick" and "Rejected", as Lightroom calls the two flags.
    public static let pick = "Pick"
    public static let rejected = "Rejected"
    static let star: Character = "★"

    /// "★", "★★" … "★★★★★".
    public static func ratingName(_ stars: Int) -> String { String(repeating: star, count: min(max(stars, 1), maxRating)) }

    public static let ratingNames: [String] = (1...maxRating).map(ratingName)
    /// Every name the app reads and writes.
    public static let allNames: [String] = ratingNames + [pick, rejected]

    /// What a tag stands for.
    public enum Meaning: Hashable, Sendable {
        case rating(Int)
        case flag(CullingFlag)
    }

    /// The meaning of a tag, nil for any other tag. "pick" and "PICK" count as "Pick": an existing tag of that name
    /// (another case) is reused when the server creates them.
    public static func meaning(of name: String) -> Meaning? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.count <= maxRating, trimmed.allSatisfy({ $0 == star }) { return .rating(trimmed.count) }
        switch trimmed.lowercased() {
        case pick.lowercased(): return .flag(.pick)
        case rejected.lowercased(): return .flag(.reject)
        default: return nil
        }
    }

    /// The tag name of a meaning (`flag(.none)` has none).
    public static func name(of meaning: Meaning) -> String? {
        switch meaning {
        case .rating(let stars): stars > 0 ? ratingName(stars) : nil
        case .flag(.pick): pick
        case .flag(.reject): rejected
        case .flag(.none): nil
        }
    }

    /// The mark that the tags of a file make. Several ratings (set on two devices at once): the highest counts. Pick and
    /// Rejected together: Pick counts, so "Delete Rejected" never deletes a photo someone picked.
    public static func mark(fromTagNames names: some Sequence<String>) -> CullingMark {
        var rating = 0
        var picked = false
        var rejected = false
        for name in names {
            switch meaning(of: name) {
            case .rating(let stars)?: rating = max(rating, stars)
            case .flag(.pick)?: picked = true
            case .flag(.reject)?: rejected = true
            default: break
            }
        }
        return CullingMark(rating: rating, flag: picked ? .pick : (rejected ? .reject : .none))
    }

    /// The tag meanings that make up a mark.
    public static func meanings(of mark: CullingMark) -> Set<Meaning> {
        var result: Set<Meaning> = []
        if mark.rating > 0 { result.insert(.rating(mark.rating)) }
        if mark.flag != .none { result.insert(.flag(mark.flag)) }
        return result
    }

    /// What has to change on a file whose culling tags are `current` (names as the server has them) so that it carries
    /// `target`: the names to remove (as they are) and the meanings to add.
    public static func changes(from current: some Sequence<String>, to target: CullingMark) -> (
        remove: Set<String>, add: Set<Meaning>
    ) {
        let wanted = meanings(of: target)
        var remove: Set<String> = []
        var present: Set<Meaning> = []
        for name in current {
            guard let meaning = meaning(of: name) else { continue }
            if wanted.contains(meaning) && !present.contains(meaning) {
                present.insert(meaning)
            } else {
                remove.insert(name)
            }
        }
        return (remove, wanted.subtracting(present))
    }
}

/// A culling key or menu command.
public enum CullingCommand: Hashable, Sendable {
    /// 0 clears the rating.
    case rate(Int)
    case flag(CullingFlag)

    /// The keys photographers know from Lightroom and Photo Mechanic: P pick, X reject, U unflag, 1–5 stars, 0 none.
    public init?(key: Character) {
        switch key {
        case "p", "P": self = .flag(.pick)
        case "x", "X": self = .flag(.reject)
        case "u", "U": self = .flag(.none)
        case "0"..."5": self = .rate(Int(String(key)) ?? 0)
        default: return nil
        }
    }

    /// The keys `init(key:)` understands, lower case.
    public static let keys: [Character] = ["p", "x", "u", "0", "1", "2", "3", "4", "5"]

    /// The mark after this command; the part it does not touch stays.
    public func applied(to mark: CullingMark) -> CullingMark {
        var result = mark
        switch self {
        case .rate(let stars): result.rating = min(max(stars, 0), CullingTags.maxRating)
        case .flag(let flag): result.flag = flag
        }
        return result
    }
}

/// Which photos a grid shows while culling.
public enum CullingFilter: Hashable, Sendable, Codable {
    case all
    case picks
    case rejected
    /// Neither picked nor rejected: what is still to be looked at.
    case unflagged
    /// Everything but the rejected ones.
    case notRejected
    /// At least this many stars (1–5).
    case rating(atLeast: Int)
    case unrated

    /// Whether a photo with this mark is shown (`CullingStore` asks the same of the database).
    public func matches(_ mark: CullingMark) -> Bool {
        switch self {
        case .all: true
        case .picks: mark.flag == .pick
        case .rejected: mark.flag == .reject
        case .unflagged: mark.flag == .none
        case .notRejected: mark.flag != .reject
        case .rating(let stars): mark.rating >= stars
        case .unrated: mark.rating == 0
        }
    }
}
