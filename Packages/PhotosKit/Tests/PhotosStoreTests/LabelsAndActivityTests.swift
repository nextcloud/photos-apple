// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Tags, people and on-device labels in the search index; tag changes through the outbox; shared-album activity.
@Suite(.timeLimit(.minutes(5))) struct LabelsAndActivityTests {
    let database: AccountDatabase
    let library: LibraryStore
    let labels: LabelStore

    init() throws {
        database = try AccountDatabase.temporary()
        library = LibraryStore(database: database)
        labels = LabelStore(database: database)
        try library.upsert([
            MediaItem(fileId: 1, path: "/Photos/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1"),
            MediaItem(fileId: 2, path: "/Photos/IMG_0002.jpg", mimeType: "image/jpeg", etag: "e2"),
            MediaItem(fileId: 3, path: "/Photos/IMG_0003.mov", mimeType: "video/quicktime", etag: "e3"),
        ])
    }

    func search(_ text: String) async throws -> [FileID] {
        try await library.search(LibrarySearch(texts: [text])).map(\.fileId).sorted()
    }

    // MARK: Search index

    @Test func tagNamesAreSearchable() async throws {
        #expect(try await search("dog") == [])
        try labels.mergeTags([SystemTag(id: 5, name: "Dog", itemCount: 2), SystemTag(id: 6, name: "Beach", itemCount: 1)])
        try labels.setMembers(ofTag: 5, [1, 2], serverCount: 2)
        try labels.setMembers(ofTag: 6, [2], serverCount: 1)
        #expect(try await search("dog") == [1, 2])
        // Every word must match somewhere: a tag and a file name together.
        #expect(try await search("dog 0002") == [2])
        #expect(try await search("dog beach") == [2])
        // Short words are matched by scanning the text, which includes the labels as well.
        #expect(try await search("do") == [1, 2])

        // A file that lost the tag on the server no longer matches.
        try labels.setMembers(ofTag: 5, [2], serverCount: 1)
        #expect(try await search("dog") == [2])
        // A renamed tag is found under its new name only.
        try labels.mergeTags([SystemTag(id: 5, name: "Puppy"), SystemTag(id: 6, name: "Beach")])
        #expect(try await search("dog") == [])
        #expect(try await search("puppy") == [2])
        // A tag that is gone on the server takes its memberships with it.
        try labels.mergeTags([SystemTag(id: 6, name: "Beach")])
        #expect(try await search("puppy") == [])
        #expect(try await search("beach") == [2])
    }

    @Test func mergeKeepsCountsUntilTheFilesAreStored() throws {
        try labels.mergeTags([SystemTag(id: 5, name: "Dog", itemCount: 2)])
        #expect(try labels.storedTagCounts() == [5: -1])
        try labels.setMembers(ofTag: 5, [1, 2], serverCount: 2)
        try labels.mergeTags([SystemTag(id: 5, name: "Dog", itemCount: 7)])
        #expect(try labels.storedTagCounts() == [5: 2])
    }

    @Test func namedPeopleAreSearchableUnnamedAreNot() async throws {
        try labels.mergePeople([Person(name: "Anna", itemCount: 1), Person(name: "17", itemCount: 1)])
        try labels.setMembers(
            ofPerson: "Anna", [PhotosAPI.PersonMember(detectionId: 4, childName: "4-IMG_0001.jpg", fileId: 1)], serverCount: 1)
        try labels.setMembers(
            ofPerson: "17", [PhotosAPI.PersonMember(detectionId: 9, childName: "9-IMG_0002.jpg", fileId: 2)], serverCount: 1)
        #expect(try await search("anna") == [1])
        #expect(try await search("17") == [])
        #expect(try labels.personNames() == ["Anna"])
        #expect(try labels.fileIds(ofPerson: "Anna") == [1])
    }

    @Test func recognisedLabelsAreSearchableAndRedoneForANewVersion() async throws {
        let candidates = try labels.visionCandidates(limit: 10)
        // Images only; videos have no preview the classifier is run on. Paged by file id.
        #expect(candidates.map(\.fileId) == [2, 1])
        #expect(try labels.visionCandidates(limit: 10, before: 2).map(\.fileId) == [1])
        try labels.setVisionLabels([(candidates.first { $0.fileId == 1 }!, ["dog", "grass"]), (candidates.first { $0.fileId == 2 }!, [])])
        #expect(try await search("grass") == [1])
        #expect(try labels.visionCandidates(limit: 10).isEmpty)
        #expect(try labels.visionProgress() == (labeled: 2, total: 2))

        // The photo was edited: another ETag, labelled again.
        try library.upsert([MediaItem(fileId: 1, path: "/Photos/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1-edited")])
        #expect(try labels.visionCandidates(limit: 10).map(\.fileId) == [1])
        #expect(try labels.visionProgress() == (labeled: 1, total: 2))
        // Labels stay in the index while the row changes (the media triggers include them).
        #expect(try await search("grass") == [1])

        try labels.deleteVisionLabels()
        #expect(try await search("grass") == [])
    }

    @Test func labelsSurviveARebuildOfTheIndex() async throws {
        try labels.mergeTags([SystemTag(id: 5, name: "Dog")])
        try labels.setMembers(ofTag: 5, [1], serverCount: 1)
        // The timeline folders changed: the index is emptied and filled again by the next sync.
        try library.deleteIndex()
        #expect(try await search("dog") == [])
        try library.upsert([MediaItem(fileId: 1, path: "/Pictures/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1")])
        #expect(try await search("dog") == [1])
        // The label triggers were created again too.
        try labels.setMembers(ofTag: 5, [], serverCount: 0)
        #expect(try await search("dog") == [])
    }

    /// A database created by an earlier version (up to `v2-large-library`) is migrated in place: its index stays, and
    /// labels are searchable from then on.
    @Test func migratesADatabaseOfTheLastVersion() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "photos-\(UUID().uuidString).sqlite")
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try AccountDatabase.migrator.migrate(pool, upTo: "v2-large-library")
        try await pool.write { db in
            try MediaItem(fileId: 1, path: "/Photos/Holiday/IMG_0001.jpg", mimeType: "image/jpeg", etag: "e1").insert(db)
        }
        try pool.close()

        let database = try AccountDatabase(url: url)
        let library = LibraryStore(database: database)
        let labels = LabelStore(database: database)
        #expect(try await library.search(LibrarySearch(texts: ["holiday"])).map(\.fileId) == [1])
        try labels.mergeTags([SystemTag(id: 5, name: "Dog")])
        try labels.setMembers(ofTag: 5, [1], serverCount: 1)
        #expect(try await library.search(LibrarySearch(texts: ["dog"])).map(\.fileId) == [1])
        #expect(try await library.search(LibrarySearch(texts: ["holiday dog"])).map(\.fileId) == [1])
    }

    // MARK: Tag changes through the outbox

    @Test func tagChangeAppliesLocallyAndReachesTheServer() async throws {
        let server = FakeDAVServer()
        server.statusOverride.withLock { $0 = { $0.method == "PUT" ? 201 : nil } }
        let outbox = Outbox(api: server.api, database: database, retryDelay: { _ in 3600 })
        try labels.mergeTags([SystemTag(id: 5, name: "Dog")])
        try labels.setMembers(ofTag: 5, [], serverCount: 0)

        try await outbox.enqueue([.tag(TagChange(fileId: 1, tagId: 5, tagName: "Dog", assign: true))])
        // At once, before the server has it: found by search, and the tag's files are read again at the next refresh.
        #expect(try await search("dog") == [1])
        #expect(try labels.storedTagCounts()[5] == -1)
        await outbox.waitUntilIdle()
        #expect(server.requests(.other).map { "\($0.method) \($0.path)" } == ["PUT /remote.php/dav/systemtags-relations/files/1/5"])
        #expect(try await outbox.pendingCount() == 0)

        // Removing it again: the server answers 404 for a relation that is not there, which counts as done.
        try await outbox.enqueue([.tag(TagChange(fileId: 1, tagId: 5, tagName: "Dog", assign: false))])
        #expect(try await search("dog") == [])
        await outbox.waitUntilIdle()
        #expect(server.requests(.delete).map(\.path) == ["/remote.php/dav/systemtags-relations/files/1/5"])
        #expect(try await outbox.pendingCount() == 0)
        #expect(try await outbox.failedOperations().isEmpty)
    }

    @Test func tagChangeOfANewTagCreatesItLocally() throws {
        try database.writer.write { db in
            try Outbox.applyLocally(.tag(TagChange(fileId: 2, tagId: 9, tagName: "r3-new", assign: true)), db: db)
        }
        #expect(try labels.tags().map(\.name) == ["r3-new"])
        #expect(try labels.tagIds(of: [1, 2]) == [2: [9]])
        // Codable round trip, as the outbox stores it.
        let operation = PendingOperation.tag(TagChange(fileId: 2, tagId: 9, tagName: "r3-new", assign: true))
        let decoded = try JSONDecoder().decode(PendingOperation.self, from: try JSONEncoder().encode(operation))
        #expect(decoded == operation)
        #expect(operation.fileId == 2)
        #expect(operation.withPath("/elsewhere.jpg") == operation)
    }

    // MARK: Label refresh

    /// The tag listing and the file ids of each tag, as a stock Nextcloud answers them.
    func tagServer(_ tags: [(id: Int, name: String, files: [FileID])]) -> FakeDAVServer {
        let server = FakeDAVServer()
        let user = server.user
        server.responder.withLock {
            $0 = { request in
                if request.method == "PROPFIND", request.path.hasSuffix("systemtags-assigned/image") {
                    var body = "<d:response><d:href>/remote.php/dav/systemtags-assigned/image/</d:href></d:response>"
                    for tag in tags {
                        body +=
                            "<d:response><d:href>/remote.php/dav/systemtags-assigned/image/\(tag.id)/</d:href><d:propstat><d:prop><oc:id>\(tag.id)</oc:id><oc:display-name>\(tag.name)</oc:display-name><nc:files-assigned>\(tag.files.count)</nc:files-assigned></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    }
                    return .http(status: 207, body: FakeDAVServer.multistatus(body))
                }
                if request.method == "REPORT", let match = request.body.firstMatch(of: /<oc:systemtag>(\d+)<\/oc:systemtag>/),
                    let tag = tags.first(where: { $0.id == Int(match.1) })
                {
                    let body = tag.files.map {
                        "<d:response><d:href>/remote.php/dav/files/\(user)/f\($0).jpg</d:href><d:propstat><d:prop><oc:fileid>\($0)</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                    }
                    return .http(status: 207, body: FakeDAVServer.multistatus(body.joined()))
                }
                return nil
            }
        }
        return server
    }

    @Test func labelRefreshReadsOnlyTagsWhoseCountChanged() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var server = tagServer([(5, "Dog", [1, 2]), (6, "Beach", [2])])
        try await LabelSync(api: server.api, database: database).refresh(tags: true, people: false, peopleKey: nil, now: now)
        #expect(try await search("dog") == [1, 2])
        #expect(server.requests(.other).filter { $0.method == "REPORT" }.count == 2)

        // Half an hour later "Dog" lost a photo: only that tag's files are read again.
        server = tagServer([(5, "Dog", [1]), (6, "Beach", [2])])
        let sync = LabelSync(api: server.api, database: database)
        #expect(try sync.isDue(now: now.addingTimeInterval(LabelSync.interval)))
        #expect(try !sync.isDue(now: now.addingTimeInterval(60)))
        try await sync.refresh(tags: true, people: false, peopleKey: nil, now: now.addingTimeInterval(LabelSync.interval))
        let reports = server.requests(.other).filter { $0.method == "REPORT" }
        #expect(reports.count == 1)
        #expect(reports.first?.body.contains("<oc:systemtag>5</oc:systemtag>") == true)
        #expect(try await search("dog") == [1])

        // A day later everything is read again.
        server = tagServer([(5, "Dog", [1]), (6, "Beach", [2])])
        try await LabelSync(api: server.api, database: database).refresh(
            tags: true, people: false, peopleKey: nil, now: now.addingTimeInterval(LabelSync.fullInterval + 1))
        #expect(server.requests(.other).filter { $0.method == "REPORT" }.count == 2)
    }

    @Test func labelRefreshWaitsForTheOutbox() throws {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO operation(kind, payload, state, createdAt) VALUES ('tag', '{}', 'pending', 0)")
        }
        #expect(try !LabelSync(api: FakeDAVServer().api, database: database).isDue())
    }

    // MARK: Shared-album activity

    func album(_ kind: AlbumKind, _ name: String, count: Int, collaborators: [Collaborator] = []) -> Album {
        Album(kind: kind, name: name, ownerDisplayName: kind == .shared ? "Anna" : nil, itemCount: count, collaborators: collaborators)
    }

    @Test func activityEvents() {
        let anna = Collaborator(id: "anna", label: "Anna", type: .user)
        let link = Collaborator(id: "tok", label: "Link", type: .publicLink)
        let before = [
            album(.shared, "Trip (anna)", count: 10), album(.own, "Family", count: 5, collaborators: [anna]),
            album(.own, "Mine", count: 3), album(.own, "Linked", count: 3, collaborators: [link]),
        ]
        // Nothing on the first listing: it is only the baseline.
        #expect(SharedAlbumActivity.events(previous: [], current: before, isFirstListing: true).isEmpty)
        let after = [
            album(.shared, "Trip (anna)", count: 14), album(.own, "Family", count: 6, collaborators: [anna]),
            album(.own, "Mine", count: 9), album(.own, "Linked", count: 8, collaborators: [link]),
            album(.shared, "Party (bob)", count: 20),
        ]
        let events = SharedAlbumActivity.events(previous: before, current: after, isFirstListing: false)
        #expect(events.map(\.albumId) == ["shared:Trip (anna)", "own:Family", "shared:Party (bob)"])
        #expect(events.map(\.added) == [4, 1, 20])
        #expect(events.map(\.isNewAlbum) == [false, false, true])
        // Fewer photos than before is no activity.
        #expect(SharedAlbumActivity.events(previous: after, current: before, isFirstListing: false).isEmpty)
    }

    @Test func activityIsRecordedByAlbumListingsAndSeenWhenOpened() throws {
        let collections = CollectionStore(database: database)
        let activity = AlbumActivityStore(database: database)
        try collections.replaceAlbums([album(.shared, "Trip (anna)", count: 10)], kind: .shared)
        #expect(try activity.all().isEmpty)

        let start = Date()
        try collections.replaceAlbums([album(.shared, "Trip (anna)", count: 12)], kind: .shared)
        try collections.replaceAlbums([album(.shared, "Trip (anna)", count: 15)], kind: .shared)
        // One entry per album while it is unseen, adding up.
        #expect(try activity.all().map(\.added) == [5])
        #expect(try activity.unseen(since: start).count == 1)

        // Photos added in this app raise the stored count first (outbox): not reported as someone else's.
        try database.writer.write { db in
            try Outbox.applyLocally(
                .addToAlbum(albumId: "shared:Trip (anna)", albumName: "Trip (anna)", albumKind: .shared, fileId: 1, path: "/Photos/a.jpg"),
                db: db)
        }
        try collections.replaceAlbums([album(.shared, "Trip (anna)", count: 16)], kind: .shared)
        #expect(try activity.all().map(\.added) == [5])

        try activity.markSeen(albumId: "shared:Trip (anna)")
        #expect(try activity.all().map(\.isSeen) == [true])
        try collections.replaceAlbums([album(.shared, "Trip (anna)", count: 17)], kind: .shared)
        #expect(try activity.all().map(\.added) == [1, 5])
        try activity.markAllSeen()
        #expect(try activity.unseen(since: .distantPast).isEmpty)

        // Leaving the album removes its entries.
        try collections.replaceAlbums([], kind: .shared)
        #expect(try activity.all().isEmpty)
    }
}
