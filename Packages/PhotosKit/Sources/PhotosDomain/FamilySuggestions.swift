// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A photo of the family folder, as far as suggestions need it: when and where it was taken.
public struct FamilyFolderMoment: Hashable, Sendable {
    public var timestamp: Date
    public var coordinate: GeoCoordinate?
    public var place: String?

    public init(timestamp: Date, coordinate: GeoCoordinate? = nil, place: String? = nil) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.place = place
    }

    public init(_ item: MediaItem) {
        timestamp = item.timestamp
        coordinate = item.latitude.flatMap { latitude in item.longitude.map { GeoCoordinate(latitude: latitude, longitude: $0) } }
            .flatMap { $0.isValid ? $0 : nil }
        place = item.place.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A group of the user's own photos that could go into the family folder (SPEC §16.7.2).
public struct FamilySuggestion: Hashable, Sendable, Identifiable {
    public enum Reason: Hashable, Sendable {
        /// Family members are in them (Recognize); the month they were taken in.
        case people(names: [String], month: Date)
        /// Taken on a day the family folder has photos from, at the same place.
        case sharedDay(day: Date, place: String?)
    }

    public var reason: Reason
    /// Newest first.
    public var fileIds: [FileID]

    public var id: String {
        switch reason {
        case .people(_, let month): "people-\(Int(month.timeIntervalSince1970))"
        case .sharedDay(let day, _): "day-\(Int(day.timeIntervalSince1970))"
        }
    }

    public var date: Date {
        switch reason {
        case .people(_, let month): month
        case .sharedDay(let day, _): day
        }
    }
}

/// Finds the user's own photos that belong in the family folder: photos the chosen family members are in, and photos
/// taken on a day and at a place the family folder already has photos of (an event the family shared). Nothing is ever
/// moved without the user's confirmation; what the user moved, copied or dismissed is never suggested again.
public enum FamilySuggestions {
    /// How far apart two photos of the same day may be taken to count as the same event.
    public static let sameEventDistance: Double = 2000
    /// At most this many photos in one suggestion; the rest come in the next one.
    public static let maximumPerSuggestion = 200

    /// - Parameters:
    ///   - candidates: the user's own photos and videos (not in the family folder, not archived, no Live Photo motion
    ///     parts), each with the named people Recognize found in it.
    ///   - members: the family members' names.
    ///   - folder: what the family folder already has.
    ///   - decided: photos moved, copied or dismissed before.
    public static func suggestions(
        candidates: [(item: MediaItem, people: Set<String>)], members: Set<String>, folder: [FamilyFolderMoment],
        decided: Set<FileID>, calendar: Calendar = .current
    ) -> [FamilySuggestion] {
        let days = Dictionary(grouping: folder) { calendar.startOfDay(for: $0.timestamp) }
        var byDay: [Date: [MediaItem]] = [:]
        var placeOfDay: [Date: String] = [:]
        var byMonth: [Date: (items: [MediaItem], names: Set<String>)] = [:]
        for (item, people) in candidates {
            guard !decided.contains(item.fileId), !item.isLivePhotoVideo, !item.isArchived, !Cleanup.isScreenshot(item),
                !Cleanup.isScreenRecording(item)
            else { continue }
            let day = calendar.startOfDay(for: item.timestamp)
            if let moments = days[day], let match = sharedPlace(of: item, moments: moments) {
                byDay[day, default: []].append(item)
                if let place = match.name { placeOfDay[day] = place }
                continue
            }
            let present = people.intersection(members)
            guard !present.isEmpty else { continue }
            let month = calendar.dateInterval(of: .month, for: item.timestamp)?.start ?? day
            byMonth[month, default: ([], [])].items.append(item)
            byMonth[month]?.names.formUnion(present)
        }
        var result: [FamilySuggestion] = []
        for (day, items) in byDay {
            result += split(items).map { FamilySuggestion(reason: .sharedDay(day: day, place: placeOfDay[day]), fileIds: $0) }
        }
        for (month, group) in byMonth {
            let names = group.names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            result += split(group.items).map { FamilySuggestion(reason: .people(names: names, month: month), fileIds: $0) }
        }
        return result.sorted { ($0.date, $0.fileIds.count) > ($1.date, $1.fileIds.count) }
    }

    /// Whether a photo was taken where the family folder's photos of that day were: within `sameEventDistance` of one
    /// of them, or in the same named place. A photo without a location never matches by day alone (a commute and a
    /// family lunch can share a date). Returns the place's name when it matches.
    static func sharedPlace(of item: MediaItem, moments: [FamilyFolderMoment]) -> SharedPlace? {
        let own = FamilyFolderMoment(item)
        for moment in moments {
            if let a = own.coordinate, let b = moment.coordinate, a.distance(to: b) <= sameEventDistance {
                return SharedPlace(name: own.place ?? moment.place)
            }
            if let a = own.place, let b = moment.place, a.localizedCaseInsensitiveCompare(b) == .orderedSame {
                return SharedPlace(name: a)
            }
        }
        return nil
    }

    /// Where a photo matched the family folder's photos of its day.
    struct SharedPlace: Equatable {
        var name: String?
    }

    /// Newest first, in parts of at most `maximumPerSuggestion`.
    static func split(_ items: [MediaItem]) -> [[FileID]] {
        let ids = items.sorted { ($0.timestamp, $0.fileId) > ($1.timestamp, $1.fileId) }.map(\.fileId)
        return stride(from: 0, to: ids.count, by: maximumPerSuggestion).map { Array(ids[$0..<min($0 + maximumPerSuggestion, ids.count)]) }
    }
}
