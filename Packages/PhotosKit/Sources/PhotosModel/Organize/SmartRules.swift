// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A rule over photos (SPEC §16.4): conditions combined with All (and), Any (or) and Not. Smart albums and folder rules
/// use the same rules; `SmartRuleEvaluator` (PhotosDomain) decides which photos match.
public indirect enum SmartRule: Hashable, Sendable {
    /// Every rule matches (an empty list matches everything).
    case all([SmartRule])
    /// At least one rule matches (an empty list matches nothing).
    case any([SmartRule])
    case not(SmartRule)
    case condition(SmartCondition)

    /// The rules directly inside a group; nil for a condition or `not`.
    public var children: [SmartRule]? {
        switch self {
        case .all(let rules), .any(let rules): rules
        case .not, .condition: nil
        }
    }

    /// Every condition of the rule, depth first.
    public var conditions: [SmartCondition] {
        switch self {
        case .all(let rules), .any(let rules): rules.flatMap(\.conditions)
        case .not(let rule): rule.conditions
        case .condition(let condition): [condition]
        }
    }

    /// The rule needs the camera details of photos (make, lens, exposure), which the index reads separately.
    public var needsCameraDetails: Bool { conditions.contains { $0.needsCameraDetails } }

    /// The rule cannot be evaluated by this version of the app (a condition written by a newer one).
    public var hasUnsupportedConditions: Bool {
        conditions.contains { if case .unsupported = $0 { true } else { false } }
    }

    /// A rule without any condition (matches every photo).
    public var isEmpty: Bool { conditions.isEmpty }
}

/// Kinds of media a rule can ask for.
public enum SmartMediaType: String, Codable, Hashable, Sendable, CaseIterable {
    case photo, video, livePhoto, screenshot, raw, panorama
}

/// One test on a photo.
public enum SmartCondition: Hashable, Sendable {
    /// A Recognize person, by name.
    case person(String)
    /// The place name the server gave the photo, or its country code.
    case place(String)
    /// A system tag, by name (case-insensitive).
    case tag(String)
    /// An own album, by name.
    case album(String)
    /// At least this many stars (culling ratings, SPEC §15.2).
    case rating(atLeast: Int)
    case flag(CullingFlag)
    case mediaType(SmartMediaType)
    case favorite
    /// The capture time is in `start..<end`.
    case dateRange(start: Date, end: Date)
    /// Taken within the last `days` days.
    case withinLastDays(Int)
    /// Taken more than `days` days ago.
    case olderThanDays(Int)
    /// The file is in this folder or below it (path from the user's root, `/Photos/Camera`).
    case folder(String)
    /// The file name contains the text (case- and diacritic-insensitive).
    case name(String)
    /// The text is in the file name, place, country, caption or folder (what the search's free text looks at).
    case text(String)
    /// Camera make or model contains the text.
    case camera(String)
    /// Lens model contains the text.
    case lens(String)
    /// Focal length in mm (inclusive bounds, either may be open).
    case focalLength(min: Double?, max: Double?)
    /// Aperture as an f-number.
    case aperture(min: Double?, max: Double?)
    case iso(min: Double?, max: Double?)
    /// A condition of a newer app version, kept as written (raw JSON) so saving does not lose it. Never matches.
    case unsupported(String)

    public var needsCameraDetails: Bool {
        switch self {
        case .camera, .lens, .focalLength, .aperture, .iso: true
        default: false
        }
    }
    /// A condition the user has not filled in yet (an empty text, a range without bounds): the builder leaves it out of
    /// the rule instead of letting it match nothing while the user types.
    public var isIncomplete: Bool {
        switch self {
        case .person(let text), .place(let text), .tag(let text), .album(let text), .folder(let text), .name(let text),
            .text(let text), .camera(let text), .lens(let text):
            text.trimmingCharacters(in: .whitespaces).isEmpty
        case .focalLength(let min, let max), .aperture(let min, let max), .iso(let min, let max): min == nil && max == nil
        default: false
        }
    }
}

// MARK: - JSON

/// The JSON form is meant to be read by other clients too: `{"all":[…]}`, `{"any":[…]}`, `{"not":{…}}` and conditions
/// as `{"type":"person","value":"Anna"}`, `{"type":"focalLength","min":10,"max":35}`.
extension SmartRule: Codable {
    enum CodingKeys: String, CodingKey { case all, any, not }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rules = try container.decodeIfPresent([SmartRule].self, forKey: .all) {
            self = .all(rules)
        } else if let rules = try container.decodeIfPresent([SmartRule].self, forKey: .any) {
            self = .any(rules)
        } else if let rule = try container.decodeIfPresent(SmartRule.self, forKey: .not) {
            self = .not(rule)
        } else {
            self = .condition(try SmartCondition(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .all(let rules):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rules, forKey: .all)
        case .any(let rules):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rules, forKey: .any)
        case .not(let rule):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rule, forKey: .not)
        case .condition(let condition):
            try condition.encode(to: encoder)
        }
    }
}

extension SmartCondition: Codable {
    enum CodingKeys: String, CodingKey { case type, value, min, max, start, end, days }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func text() throws -> String { try c.decode(String.self, forKey: .value) }
        func bounds() throws -> (Double?, Double?) {
            (try c.decodeIfPresent(Double.self, forKey: .min), try c.decodeIfPresent(Double.self, forKey: .max))
        }
        switch type {
        case "person": self = .person(try text())
        case "place": self = .place(try text())
        case "tag": self = .tag(try text())
        case "album": self = .album(try text())
        case "rating": self = .rating(atLeast: try c.decode(Int.self, forKey: .min))
        case "flag":
            guard let flag = CullingFlag(rawValue: try text()) else { throw Self.unknown(decoder) }
            self = .flag(flag)
        case "mediaType":
            guard let kind = SmartMediaType(rawValue: try text()) else { throw Self.unknown(decoder) }
            self = .mediaType(kind)
        case "favorite": self = .favorite
        case "dateRange":
            self = .dateRange(
                start: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .start)),
                end: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .end)))
        case "withinLastDays": self = .withinLastDays(try c.decode(Int.self, forKey: .days))
        case "olderThanDays": self = .olderThanDays(try c.decode(Int.self, forKey: .days))
        case "folder": self = .folder(try text())
        case "name": self = .name(try text())
        case "text": self = .text(try text())
        case "camera": self = .camera(try text())
        case "lens": self = .lens(try text())
        case "focalLength":
            let (min, max) = try bounds()
            self = .focalLength(min: min, max: max)
        case "aperture":
            let (min, max) = try bounds()
            self = .aperture(min: min, max: max)
        case "iso":
            let (min, max) = try bounds()
            self = .iso(min: min, max: max)
        default:
            throw Self.unknown(decoder)
        }
    }

    /// Placeholder error; `SmartRule` decoding turns unknown conditions into `.unsupported` (see `decodeLenient`).
    static func unknown(_ decoder: any Decoder) -> any Error {
        DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown smart condition"))
    }

    public func encode(to encoder: any Encoder) throws {
        if case .unsupported(let json) = self {
            // Written back as it came.
            let value = try JSONDecoder().decode(RawJSON.self, from: Data(json.utf8))
            try value.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .person(let value): try c.encode("person", forKey: .type); try c.encode(value, forKey: .value)
        case .place(let value): try c.encode("place", forKey: .type); try c.encode(value, forKey: .value)
        case .tag(let value): try c.encode("tag", forKey: .type); try c.encode(value, forKey: .value)
        case .album(let value): try c.encode("album", forKey: .type); try c.encode(value, forKey: .value)
        case .rating(let stars): try c.encode("rating", forKey: .type); try c.encode(stars, forKey: .min)
        case .flag(let flag): try c.encode("flag", forKey: .type); try c.encode(flag.rawValue, forKey: .value)
        case .mediaType(let kind): try c.encode("mediaType", forKey: .type); try c.encode(kind.rawValue, forKey: .value)
        case .favorite: try c.encode("favorite", forKey: .type)
        case .dateRange(let start, let end):
            try c.encode("dateRange", forKey: .type)
            try c.encode(start.timeIntervalSince1970, forKey: .start)
            try c.encode(end.timeIntervalSince1970, forKey: .end)
        case .withinLastDays(let days): try c.encode("withinLastDays", forKey: .type); try c.encode(days, forKey: .days)
        case .olderThanDays(let days): try c.encode("olderThanDays", forKey: .type); try c.encode(days, forKey: .days)
        case .folder(let value): try c.encode("folder", forKey: .type); try c.encode(value, forKey: .value)
        case .name(let value): try c.encode("name", forKey: .type); try c.encode(value, forKey: .value)
        case .text(let value): try c.encode("text", forKey: .type); try c.encode(value, forKey: .value)
        case .camera(let value): try c.encode("camera", forKey: .type); try c.encode(value, forKey: .value)
        case .lens(let value): try c.encode("lens", forKey: .type); try c.encode(value, forKey: .value)
        case .focalLength(let min, let max):
            try c.encode("focalLength", forKey: .type)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
        case .aperture(let min, let max):
            try c.encode("aperture", forKey: .type)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
        case .iso(let min, let max):
            try c.encode("iso", forKey: .type)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
        case .unsupported: break
        }
    }
}

extension SmartRule {
    /// Decodes a rule, keeping conditions this version does not know as `.unsupported` instead of failing.
    public static func decodeLenient(_ value: RawJSON) -> SmartRule {
        switch value {
        case .object(let object):
            if case .array(let items)? = object["all"] { return .all(items.map(decodeLenient)) }
            if case .array(let items)? = object["any"] { return .any(items.map(decodeLenient)) }
            if let inner = object["not"] { return .not(decodeLenient(inner)) }
            let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
            if let condition = try? JSONDecoder().decode(SmartCondition.self, from: data) { return .condition(condition) }
            return .condition(.unsupported(String(decoding: data, as: UTF8.self)))
        default:
            let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
            return .condition(.unsupported(String(decoding: data, as: UTF8.self)))
        }
    }
}

/// Any JSON value, for keeping what a newer version wrote.
public enum RawJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RawJSON])
    case object([String: RawJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RawJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Synced records

/// A record of a list that devices share through a JSON file in the user's Nextcloud (`SyncedList`): every change
/// stamps `modifiedAt`, and a deletion leaves a tombstone so another device does not bring the record back.
public protocol SyncedRecord: Codable, Hashable, Sendable, Identifiable where ID == String {
    var modifiedAt: Date { get set }
    var isDeleted: Bool { get set }
}

/// A saved smart album made with the rule builder (SPEC §16.4). Synced between devices through
/// `.nextcloud-photos/smart-albums.json`.
public struct SmartAlbumDefinition: SyncedRecord {
    public enum Sort: String, Codable, Hashable, Sendable {
        case newestFirst, oldestFirst
    }

    public var id: String
    public var name: String
    public var rule: SmartRule
    public var sort: Sort
    /// At most this many photos (the newest or oldest, by `sort`); nil for all.
    public var limit: Int?
    public var modifiedAt: Date
    public var isDeleted: Bool

    public init(
        id: String = UUID().uuidString, name: String, rule: SmartRule, sort: Sort = .newestFirst, limit: Int? = nil,
        modifiedAt: Date = Date(), isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rule = rule
        self.sort = sort
        self.limit = limit
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }

    enum CodingKeys: String, CodingKey { case id, name, rule, sort, limit, modifiedAt, deleted }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rule = (try? c.decode(RawJSON.self, forKey: .rule)).map(SmartRule.decodeLenient) ?? .all([])
        sort = (try? c.decode(Sort.self, forKey: .sort)) ?? .newestFirst
        limit = try? c.decodeIfPresent(Int.self, forKey: .limit)
        modifiedAt = Date(timeIntervalSince1970: (try? c.decode(Double.self, forKey: .modifiedAt)) ?? 0)
        isDeleted = (try? c.decode(Bool.self, forKey: .deleted)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rule, forKey: .rule)
        try c.encode(sort, forKey: .sort)
        try c.encodeIfPresent(limit, forKey: .limit)
        try c.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        if isDeleted { try c.encode(true, forKey: .deleted) }
    }
}

// MARK: - From saved searches

extension SmartRule {
    /// The rule of a smart album saved from the search (`AlbumFilters`): any of the places, any of the dates, any of the
    /// texts, any of the tags, all kinds together — what the search evaluates (SPEC SR-2).
    public init(_ filters: AlbumFilters) {
        var groups: [SmartRule] = []
        func group(_ conditions: [SmartCondition]) {
            guard !conditions.isEmpty else { return }
            groups.append(conditions.count == 1 ? .condition(conditions[0]) : .any(conditions.map(SmartRule.condition)))
        }
        group(filters.places.map(SmartCondition.place))
        group(filters.names.map(SmartCondition.text))
        group(filters.dateRanges.map { SmartCondition.dateRange(start: $0.startDate, end: $0.endDateExclusive) })
        group(filters.tags.map(SmartCondition.tag))
        self = .all(groups)
    }
}
