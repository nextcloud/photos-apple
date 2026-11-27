// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// Birthdays read from the user's Nextcloud Contacts (SPEC §22.3), table `contactBirthday` (migration
/// `v_r12_people_contact_birthdays`): only what birthdays need (name, nicknames, the date), replaced at each read, deleted
/// when the setting is turned off. Never written back.
public struct ContactBirthdayStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    static func migrate(_ db: Database) throws {
        try db.create(table: "contactBirthday") { t in
            t.primaryKey("uid", .text)
            t.column("name", .text).notNull()
            t.column("givenName", .text)
            // JSON array of strings.
            t.column("nicknames", .text).notNull().defaults(to: "[]")
            t.column("month", .integer).notNull()
            t.column("day", .integer).notNull()
            t.column("year", .integer)
        }
    }

    static let readAtKey = "contactBirthdaysReadAt"

    /// When the contacts were last read.
    public func readAt() throws -> Date? {
        try database.syncValue(Self.readAtKey).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// Replaces the stored birthdays with what was read.
    public func replace(_ birthdays: [ContactBirthday], at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM contactBirthday")
            for birthday in birthdays {
                let nicknames = String(decoding: try JSONEncoder().encode(birthday.nicknames), as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO contactBirthday(uid, name, givenName, nicknames, month, day, year)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [birthday.uid, birthday.name, birthday.givenName, nicknames, birthday.month, birthday.day, birthday.year])
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)",
                arguments: [Self.readAtKey, String(date.timeIntervalSince1970)])
        }
    }

    public func birthdays() throws -> [ContactBirthday] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM contactBirthday ORDER BY month, day, name").map { row in
                let nicknames = (try? JSONDecoder().decode([String].self, from: Data((row["nicknames"] as String? ?? "[]").utf8))) ?? []
                return ContactBirthday(
                    uid: row["uid"], name: row["name"], givenName: row["givenName"], nicknames: nicknames, month: row["month"],
                    day: row["day"], year: row["year"])
            }
        }
    }

    /// The named people's birthdays: the people the index knows (Recognize's, or the ones named on this device) matched
    /// with the stored contacts.
    public func personBirthdays() throws -> [PersonBirthday] {
        let people = try LabelStore(database: database).personNames()
        return Birthdays.match(people: people, contacts: try birthdays())
    }

    /// The photos of a person in the library, as memory candidates.
    public func photos(of person: String) throws -> [MemoryItem] {
        try database.writer.read { db in
            var result: [MemoryItem] = []
            try LibraryStore.memoryItems(
                db,
                sql: """
                    SELECT DISTINCT media.fileId, \(LibraryStore.timestamp), media.isFavorite, media.place FROM media
                    JOIN personItem ON personItem.fileId = media.fileId WHERE personItem.person = ? AND \(LibraryStore.visible)
                    """, arguments: [person], into: &result)
            return result
        }
    }

    /// "Anna's birthday" memories of every named person with a birthday and enough photos, the next birthday first.
    public func memories(now: Date = Date(), calendar: Calendar = .current) throws -> [(birthday: PersonBirthday, memory: Memory)] {
        let result = try personBirthdays().compactMap { birthday -> (PersonBirthday, Memory)? in
            Birthdays.memory(birthday, photos: try photos(of: birthday.person), now: now, calendar: calendar).map { (birthday, $0) }
        }
        return result.sorted { a, b in
            let next = { (value: PersonBirthday) in Birthdays.next(value.contact, after: now, calendar: calendar) ?? .distantFuture }
            return (next(a.0), a.0.person) < (next(b.0), b.0.person)
        }
        .map { (birthday: $0.0, memory: $0.1) }
    }

    /// Forgets the birthdays (the setting was turned off).
    public func deleteAll() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM contactBirthday")
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [Self.readAtKey])
        }
    }
}
