// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Birthdays from Contacts with the people of the photos (SPEC §22.3).
@Suite struct BirthdaysTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    let anna = ContactBirthday(uid: "a", name: "Anna Schmidt", givenName: "Anna", nicknames: ["Anni"], month: 4, day: 12, year: 2018)
    let ben = ContactBirthday(uid: "b", name: "Ben Weber", givenName: "Ben", month: 11, day: 27)
    let benOther = ContactBirthday(uid: "b2", name: "Ben Müller", givenName: "Ben", month: 1, day: 2)
    let leap = ContactBirthday(uid: "l", name: "Lea Leap", month: 2, day: 29, year: 2016)

    @Test func peopleAreMatchedByNameNicknameOrAUniqueFirstName() {
        let matched = Birthdays.match(people: ["Anna Schmidt", "Anni", "Ben", "12", "Carla"], contacts: [anna, ben, benOther])
        #expect(matched.map(\.person) == ["Anna Schmidt", "Anni"])
        // "Ben" is two contacts: not guessed. With one Ben it is.
        let one = Birthdays.match(people: ["ben", "ANNA"], contacts: [anna, ben])
        #expect(one.map(\.contact.uid).sorted() == ["a", "b"])
        // Accents and case do not matter.
        #expect(Birthdays.match(people: ["anna schmidt"], contacts: [anna]).count == 1)
    }

    @Test func theBirthdayMemoryHasThePhotosAroundTheDayOverTheYears() throws {
        let photos = [
            MemoryItem(fileId: 1, timestamp: Self.day(2023, 4, 12)),
            MemoryItem(fileId: 2, timestamp: Self.day(2024, 4, 14), isFavorite: true),
            MemoryItem(fileId: 3, timestamp: Self.day(2025, 4, 9)),
            MemoryItem(fileId: 4, timestamp: Self.day(2025, 5, 20)),
            MemoryItem(fileId: 5, timestamp: Self.day(2024, 4, 20)),
        ]
        let memory = try #require(
            Birthdays.memory(
                PersonBirthday(person: "Anna", contact: anna), photos: photos, now: Self.day(2026, 1, 1), calendar: Self.calendar))
        #expect(memory.items == [1, 2, 3])
        #expect(memory.cover == 2)
        #expect(memory.kind == .birthday(person: "Anna"))
        #expect(memory.id == "birthday-a")
        // Too few photos: no memory.
        #expect(
            Birthdays.memory(PersonBirthday(person: "Anna", contact: anna), photos: Array(photos.prefix(2)), calendar: Self.calendar) == nil
        )
        // A birthday on New Year's Eve takes photos of the first days of January.
        let newYear = ContactBirthday(uid: "n", name: "N", month: 12, day: 31)
        let january = (1...3).map { MemoryItem(fileId: FileID($0), timestamp: Self.day(2025, 1, $0)) }
        #expect(
            Birthdays.memory(
                PersonBirthday(person: "N", contact: newYear), photos: january, now: Self.day(2026, 1, 1), calendar: Self.calendar)?.items
                .count == 3)
    }

    @Test func nextTodayAndAge() {
        let now = Self.day(2026, 11, 27, hour: 8)
        #expect(Birthdays.isToday(ben, now: now, calendar: Self.calendar))
        #expect(!Birthdays.isToday(anna, now: now, calendar: Self.calendar))
        #expect(Birthdays.next(ben, after: now, calendar: Self.calendar) == Self.calendar.startOfDay(for: now))
        #expect(
            Birthdays.next(anna, after: now, calendar: Self.calendar)
                == Self.calendar.date(from: DateComponents(year: 2027, month: 4, day: 12)))
        #expect(Birthdays.age(anna, in: 2026) == 8)
        #expect(Birthdays.age(ben, in: 2026) == nil)
        // 29 February: the 28th in other years.
        #expect(
            Birthdays.date(of: leap, in: 2027, calendar: Self.calendar)
                == Self.calendar.date(from: DateComponents(year: 2027, month: 2, day: 28)))
        #expect(
            Birthdays.date(of: leap, in: 2028, calendar: Self.calendar)
                == Self.calendar.date(from: DateComponents(year: 2028, month: 2, day: 29)))
    }
}
