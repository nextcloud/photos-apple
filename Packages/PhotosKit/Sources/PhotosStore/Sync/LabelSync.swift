// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import OSLog
import PhotosModel
import PhotosNetworking

/// Copies tag and people memberships from the server into the local store, where the search index picks them up
/// (SPEC SR-3): "dog" then finds photos tagged "dog", also offline and on servers without the extended search.
///
/// Cheap on repeated runs: one listing of the tags (and one of the people); the files of a tag or person are only read
/// again when its count differs from the stored one, or on the daily full refresh. File ids only, never metadata.
public struct LabelSync: Sendable {
    let api: PhotosAPI
    let store: LabelStore
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "labels")

    public init(api: PhotosAPI, database: AccountDatabase) {
        self.api = api
        self.store = LabelStore(database: database)
    }

    enum Key {
        static let refreshedAt = "labelsRefreshedAt"
        static let fullRefreshAt = "labelsFullRefreshAt"
    }

    /// The shortest time between two refreshes, and between two full ones (seconds).
    public static let interval: TimeInterval = 30 * 60
    public static let fullInterval: TimeInterval = 24 * 3600

    /// Whether a refresh is due. Never while changes wait in the outbox: a tag added there must not be taken away by a
    /// listing made before it reached the server.
    public func isDue(now: Date = Date()) throws -> Bool {
        let database = store.database
        let pending = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM operation WHERE state = 'pending'") ?? 0
        }
        guard pending == 0 else { return false }
        let last = try database.syncValue(Key.refreshedAt).flatMap(Double.init) ?? 0
        return now.timeIntervalSince1970 - last >= Self.interval
    }

    /// Reads tags (and, with `peopleKey`, people) and the memberships that changed.
    /// - Parameters:
    ///   - tags: the server has system tags.
    ///   - people: the server has Recognize; `peopleKey` is its API key, if it needs one.
    public func refresh(tags: Bool, people: Bool, peopleKey: String?, now: Date = Date()) async throws {
        let database = store.database
        let lastFull = try database.syncValue(Key.fullRefreshAt).flatMap(Double.init) ?? 0
        let full = now.timeIntervalSince1970 - lastFull >= Self.fullInterval
        var changed = 0
        if tags { changed += try await refreshTags(full: full) }
        if people { changed += try await refreshPeople(key: peopleKey, full: full) }
        try database.setSyncValue(Key.refreshedAt, String(now.timeIntervalSince1970))
        if full { try database.setSyncValue(Key.fullRefreshAt, String(now.timeIntervalSince1970)) }
        logger.info("labels refreshed (\(full ? "full" : "changed only", privacy: .public)): \(changed) read again")
    }

    /// Returns how many tags had their files read.
    func refreshTags(full: Bool) async throws -> Int {
        let server = try await api.tagsInUse()
        let stored = try store.storedTagCounts()
        try store.mergeTags(server)
        var count = 0
        for tag in server where full || stored[tag.id] != tag.itemCount {
            try Task.checkCancellation()
            try store.setMembers(ofTag: tag.id, try await api.tagMemberIds(tag.id), serverCount: tag.itemCount)
            count += 1
        }
        return count
    }

    /// Returns how many people had their photos read. Unnamed clusters are skipped: nobody searches for a number.
    func refreshPeople(key: String?, full: Bool) async throws -> Int {
        let server = try await api.people(key: key).filter { !$0.isUnnamed }
        let stored = try store.storedPersonCounts()
        try store.mergePeople(server)
        var count = 0
        for person in server where full || stored[person.name] != person.itemCount {
            try Task.checkCancellation()
            try store.setMembers(
                ofPerson: person.name, try await api.personMembers(person.name, key: key), serverCount: person.itemCount)
            count += 1
        }
        return count
    }
}
