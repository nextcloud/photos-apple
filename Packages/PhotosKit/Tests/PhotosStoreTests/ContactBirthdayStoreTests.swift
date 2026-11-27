// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Birthdays from Contacts in the index and the "Anna's birthday" memories (SPEC §22.3).
@Suite(.timeLimit(.minutes(5))) struct ContactBirthdayStoreTests {
    @Test func memoriesOfNamedPeopleWithABirthday() async throws {
        let database = try AccountDatabase.temporary()
        let calendar = Calendar(identifier: .gregorian)
        func at(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        try LibraryStore(database: database).upsert(
            [(1, at(2023, 4, 12)), (2, at(2024, 4, 13)), (3, at(2025, 4, 11)), (4, at(2025, 7, 1)), (5, at(2024, 4, 12))].map {
                MediaItem(fileId: FileID($0.0), path: "/Photos/\($0.0).jpg", mimeType: "image/jpeg", etag: "e", capturedAt: $0.1)
            })
        let labels = LabelStore(database: database)
        try labels.mergePeople([Person(name: "Anna"), Person(name: "Ben")])
        try labels.setMembers(
            ofPerson: "Anna", [1, 2, 3, 4].map { PhotosAPI.PersonMember(detectionId: Int($0), childName: "\($0)", fileId: $0) },
            serverCount: 4)
        try labels.setMembers(ofPerson: "Ben", [PhotosAPI.PersonMember(detectionId: 9, childName: "9", fileId: 5)], serverCount: 1)
        let store = ContactBirthdayStore(database: database)
        #expect(try store.readAt() == nil)
        try store.replace([
            ContactBirthday(uid: "a", name: "Anna", month: 4, day: 12, year: 2019),
            ContactBirthday(uid: "b", name: "Ben", month: 4, day: 12),
            ContactBirthday(uid: "c", name: "Carla", month: 1, day: 1),
        ])
        #expect(try store.readAt() != nil)
        #expect(try store.birthdays().count == 3)
        #expect(try store.personBirthdays().map(\.person) == ["Anna", "Ben"])
        let memories = try store.memories(now: at(2026, 1, 1), calendar: calendar)
        // Ben has one photo: no memory.
        #expect(memories.map(\.birthday.person) == ["Anna"])
        #expect(memories.first?.memory.items == [1, 2, 3])
        try store.deleteAll()
        #expect(try store.birthdays().isEmpty)
        #expect(try store.readAt() == nil)
    }
}
