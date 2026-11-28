// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A named person with the birthday of the contact they are (SPEC §22.3).
public struct PersonBirthday: Hashable, Sendable, Identifiable {
    public var person: String
    public var contact: ContactBirthday
    public var id: String { person }

    public init(person: String, contact: ContactBirthday) {
        self.person = person
        self.contact = contact
    }
}

/// Birthdays from Nextcloud Contacts with the people of the photos (SPEC §22.3): who is whom, the "Anna's birthday"
/// memories (their photos around the day, over the years) and the reminder on the day.
public enum Birthdays {
    /// Photos this many days before and after the birthday belong to it (the party is often at the weekend).
    public static let windowDays = 3
    /// A birthday memory needs at least this many photos.
    public static let minimumPhotos = 3

    /// Which person is which contact, by name (case and accents ignored):
    ///  1. the person's name is the contact's full name, or one of its nicknames;
    ///  2. else the person's name is a contact's given name (or the first word of its name), when exactly one contact has
    ///     that first name and exactly one person is called so.
    /// A person matched twice is left out rather than guessed.
    public static func match(people: [String], contacts: [ContactBirthday]) -> [PersonBirthday] {
        let fold = FuzzyMatch.fold
        var byFullName: [String: [ContactBirthday]] = [:]
        var byFirstName: [String: [ContactBirthday]] = [:]
        for contact in contacts {
            for name in [contact.name] + contact.nicknames {
                byFullName[fold(name).trimmingCharacters(in: .whitespaces), default: []].append(contact)
            }
            let first = contact.givenName ?? contact.name.split(separator: " ").first.map(String.init)
            if let first { byFirstName[fold(first), default: []].append(contact) }
        }
        let personCounts = Dictionary(people.map { (fold($0), 1) }, uniquingKeysWith: +)
        var result: [PersonBirthday] = []
        for person in people where Int(person) == nil {
            let key = fold(person).trimmingCharacters(in: .whitespaces)
            let full = Set(byFullName[key] ?? [])
            if full.count == 1, let contact = full.first {
                result.append(PersonBirthday(person: person, contact: contact))
            } else if full.isEmpty, personCounts[key] == 1, let candidates = byFirstName[key], Set(candidates).count == 1 {
                result.append(PersonBirthday(person: person, contact: candidates[0]))
            }
        }
        return result.sorted { $0.person < $1.person }
    }

    /// The birthday in `year` (29 February on the 28th in other years).
    public static func date(of birthday: ContactBirthday, in year: Int, calendar: Calendar) -> Date? {
        var components = DateComponents(year: year, month: birthday.month, day: birthday.day)
        if birthday.month == 2, birthday.day == 29,
            calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: 2))!)?.count != 29
        {
            components.day = 28
        }
        return calendar.date(from: components)
    }

    /// The next birthday from `now` on (today's counts).
    public static func next(_ birthday: ContactBirthday, after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        for candidate in [year, year + 1] {
            if let date = date(of: birthday, in: candidate, calendar: calendar), date >= today { return date }
        }
        return nil
    }

    /// Whether `now` is the birthday.
    public static func isToday(_ birthday: ContactBirthday, now: Date, calendar: Calendar) -> Bool {
        guard let date = date(of: birthday, in: calendar.component(.year, from: now), calendar: calendar) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    /// How old the person turns on the birthday in `year`, when the contact has the year of birth.
    public static func age(_ birthday: ContactBirthday, in year: Int) -> Int? {
        guard let born = birthday.year, year > born else { return nil }
        return year - born
    }

    /// "Anna's birthday": the person's photos within `windowDays` of each birthday, over the years, newest first in the
    /// memory's order of time. Nil with fewer than `minimumPhotos`.
    public static func memory(
        _ birthday: PersonBirthday, photos: [some MemoryCandidate], now: Date = Date(), calendar: Calendar = .current
    ) -> Memory? {
        let window = TimeInterval(windowDays * 86_400)
        let chosen = photos.filter { photo in
            let year = calendar.component(.year, from: photo.timestamp)
            return [year - 1, year, year + 1].contains { candidate in
                guard let day = date(of: birthday.contact, in: candidate, calendar: calendar) else { return false }
                let start = day.addingTimeInterval(-window)
                let end = day.addingTimeInterval(window + 86_400)
                return photo.timestamp >= start && photo.timestamp < end
            }
        }
        .filter { $0.timestamp <= now }
        .sorted { $0.timestamp < $1.timestamp }
        guard chosen.count >= minimumPhotos, let first = chosen.first, let last = chosen.last else { return nil }
        let cover = chosen.last { $0.isFavorite } ?? last
        return Memory(
            id: "birthday-\(birthday.contact.uid)", kind: .birthday(person: birthday.person), title: title(birthday.person),
            start: first.timestamp, end: last.timestamp, cover: cover.fileId, items: chosen.map(\.fileId))
    }

    public static func title(_ person: String) -> String {
        String(localized: "\(person)'s birthday", bundle: .module, comment: "Title of a memory: a person's photos around their birthdays.")
    }
}
