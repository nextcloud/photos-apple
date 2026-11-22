// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A group of photos shown as a memory (SPEC §7.12; web: src/services/memories.ts).
public struct Memory: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case yearsAgo(Int)
        case trip
        case yearRecap(Int)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var start: Date
    public var end: Date
    public var cover: FileID
    public var items: [FileID]
}

public enum Memories {
    // Constants of the web app.
    public static let tripGap: TimeInterval = 2 * 86_400
    public static let tripMinimum = 8
    public static let recapMinimum = 30
    public static let recapHighlights = 60
    public static let onThisDayWindowDays = 3
    public static let onThisDayYears = 20

    /// Whether an item falls within ±3 days of today's month/day in a past year (up to 20 years back).
    public static func isOnThisDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let year = calendar.component(.year, from: now)
        for yearsAgo in 1...onThisDayYears {
            guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: now) else { continue }
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -onThisDayWindowDays, to: anchor)!)
            let end = calendar.date(byAdding: .day, value: onThisDayWindowDays + 1, to: calendar.startOfDay(for: anchor))!
            if date >= start && date < end { return year - calendar.component(.year, from: anchor) }
        }
        return nil
    }

    /// "1 year ago", "2 years ago"… groups (newest first), cover = first favourite else the middle photo.
    public static func onThisDay(_ items: [MediaItem], now: Date = Date(), calendar: Calendar = .current) -> [Memory] {
        var groups: [Int: [MediaItem]] = [:]
        for item in items {
            if let yearsAgo = isOnThisDay(item.timestamp, now: now, calendar: calendar) { groups[yearsAgo, default: []].append(item) }
        }
        return groups.keys.sorted().compactMap { yearsAgo in
            let members = groups[yearsAgo]!.sorted { $0.timestamp < $1.timestamp }
            guard let first = members.first, let last = members.last else { return nil }
            let cover = members.first(where: \.isFavorite) ?? members[members.count / 2]
            return Memory(
                id: "years-\(yearsAgo)", kind: .yearsAgo(yearsAgo),
                title: yearsAgo == 1 ? String(localized: "1 year ago") : String(localized: "\(yearsAgo) years ago"),
                start: first.timestamp, end: last.timestamp, cover: cover.fileId, items: members.map(\.fileId))
        }
    }

    /// Trips: runs without a gap > 2 days, at least 8 photos, most recent first, titled by their places.
    public static func trips(_ items: [MediaItem], locale: Locale = .current) -> [Memory] {
        let sorted = items.sorted { $0.timestamp < $1.timestamp }
        var clusters: [[MediaItem]] = []
        for item in sorted {
            if let last = clusters.last?.last, item.timestamp.timeIntervalSince(last.timestamp) <= tripGap {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }
        return clusters.filter { $0.count >= tripMinimum }.reversed().map { cluster in
            let start = cluster.first!.timestamp
            let end = cluster.last!.timestamp
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let cover = cluster.min { abs($0.timestamp.timeIntervalSince(middle)) < abs($1.timestamp.timeIntervalSince(middle)) }!
            return Memory(
                id: "trip-\(Int(start.timeIntervalSince1970))", kind: .trip, title: tripTitle(cluster, locale: locale), start: start,
                end: end,
                cover: cover.fileId, items: cluster.map(\.fileId))
        }
    }

    /// Most frequent place, plus the second if it has at least half as many photos ("A & B"); else the date range.
    public static func tripTitle(_ cluster: [MediaItem], locale: Locale = .current) -> String {
        var counts: [String: Int] = [:]
        for item in cluster { if let place = item.place, !place.isEmpty { counts[place, default: 0] += 1 } }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if let first = ranked.first {
            if ranked.count > 1, ranked[1].value * 2 >= first.value { return "\(first.key) & \(ranked[1].key)" }
            return first.key
        }
        guard let start = cluster.first?.timestamp, let end = cluster.last?.timestamp else { return "" }
        return (start..<max(end, start.addingTimeInterval(1))).formatted(.interval.day().month().year().locale(locale))
    }

    /// Year recap: the newest year with ≥ 30 photos; 60 highlights, favourites first, then evenly per month.
    public static func yearRecap(_ items: [MediaItem], calendar: Calendar = .current) -> Memory? {
        var byYear: [Int: [MediaItem]] = [:]
        for item in items { byYear[calendar.component(.year, from: item.timestamp), default: []].append(item) }
        guard let year = byYear.keys.sorted(by: >).first(where: { byYear[$0]!.count >= recapMinimum }) else { return nil }
        let photos = byYear[year]!.sorted { $0.timestamp < $1.timestamp }
        var chosen: [MediaItem] = Array(photos.filter(\.isFavorite).prefix(recapHighlights))
        var chosenIds = Set(chosen.map(\.fileId))
        var byMonth: [Int: [MediaItem]] = [:]
        for item in photos where !chosenIds.contains(item.fileId) {
            byMonth[calendar.component(.month, from: item.timestamp), default: []].append(item)
        }
        let months = byMonth.keys.sorted()
        if !months.isEmpty {
            let quota = max(1, (recapHighlights - chosen.count) / months.count)
            for month in months {
                let members = byMonth[month]!
                let step = max(1, members.count / quota)
                for index in stride(from: 0, to: members.count, by: step).prefix(quota) where chosen.count < recapHighlights {
                    chosen.append(members[index])
                    chosenIds.insert(members[index].fileId)
                }
            }
        }
        chosen.sort { $0.timestamp < $1.timestamp }
        guard let first = chosen.first, let last = chosen.last else { return nil }
        return Memory(
            id: "recap-\(year)", kind: .yearRecap(year), title: String(localized: "\(String(year)) in review"), start: first.timestamp,
            end: last.timestamp,
            cover: chosen[chosen.count / 2].fileId, items: chosen.map(\.fileId))
    }
}
