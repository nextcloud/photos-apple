// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Reading the camera data for Insights in the background (SPEC §16.5.1), against a stub server.
@Suite(.timeLimit(.minutes(2))) struct ExifReaderTests {
    let server = StubServer()
    let database: AccountDatabase
    let store: InsightsStore

    init() throws {
        database = try AccountDatabase.temporary()
        store = InsightsStore(database: database)
        // 1 and 2 newest first; 3 has no EXIF date, 4 is gone from the server.
        try LibraryStore(database: database).upsert([
            MediaItem(fileId: 1, path: "/Photos/1.jpg", mimeType: "image/jpeg", etag: "e1", capturedAt: Date(timeIntervalSince1970: 4000)),
            MediaItem(fileId: 2, path: "/Photos/2.jpg", mimeType: "image/jpeg", etag: "e2", capturedAt: Date(timeIntervalSince1970: 3000)),
            MediaItem(
                fileId: 3, path: "/Photos/3.png", mimeType: "image/png", etag: "e3", capturedAt: Date(timeIntervalSince1970: 7200),
                captureOffset: 3600),
            MediaItem(fileId: 4, path: "/Photos/4.jpg", mimeType: "image/jpeg", etag: "e4", capturedAt: Date(timeIntervalSince1970: 1000)),
        ])
        server.set {
            $0.responses["SEARCH /remote.php/dav/"] = StubServer.Stub(status: 207, body: Self.answer)
        }
    }

    static let answer = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:response><d:href>/remote.php/dav/files/alice/Photos/1.jpg</d:href><d:propstat><d:prop><oc:fileid>1</oc:fileid>
        <d:getetag>"e1"</d:getetag><nc:metadata-photos-original_date_time>4000</nc:metadata-photos-original_date_time>
        <nc:metadata-photos-ifd0><Make>Canon</Make><Model>Canon EOS 6D</Model></nc:metadata-photos-ifd0>
        <nc:metadata-photos-exif><FNumber>28/10</FNumber><DateTimeOriginal>2024:06:14 09:12:30</DateTimeOriginal></nc:metadata-photos-exif>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/remote.php/dav/files/alice/Photos/2.jpg</d:href><d:propstat><d:prop><oc:fileid>2</oc:fileid>
        <d:getetag>"e2-new"</d:getetag><nc:metadata-photos-original_date_time>3000</nc:metadata-photos-original_date_time>
        <nc:metadata-photos-exif><ISOSpeedRatings>800</ISOSpeedRatings></nc:metadata-photos-exif>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/remote.php/dav/files/alice/Photos/3.png</d:href><d:propstat><d:prop><oc:fileid>3</oc:fileid>
        <d:getetag>"e3"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """

    func reader() -> ExifReader {
        let connection = ServerConnection(
            serverURL: server.url, userId: "alice", loginName: "alice", appPassword: "secret", userAgent: "test")
        let http = server.http()
        let api = PhotosAPI(
            dav: DAVClient(http: http, connection: connection, onUnauthorized: {}),
            ocs: OCSClient(http: http, connection: connection, onUnauthorized: {}))
        return ExifReader(api: api, store: store, sourceFolders: ["/Photos"], mimeTypes: ["image/jpeg"], excludedFolders: [])
    }

    func facts() async throws -> [FileID: (etag: String, facts: ExifFacts)] {
        try await database.writer.read { db in
            var result: [FileID: (etag: String, facts: ExifFacts)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM photoExif") {
                result[row["fileId"]] = (row["etag"], InsightsStore.facts(row))
            }
            return result
        }
    }

    @Test func readsByIdAndRemembersWhatTheServerDidNotReturn() async throws {
        try await reader().run(pause: .zero) { true }
        let stored = try await facts()
        #expect(stored[1]?.facts == ExifFacts(camera: "Canon EOS 6D", aperture: 2.8, hour: 9))
        // Rows carry the index's ETag, whatever the server answered: read again when the sync sees a change.
        #expect(stored[2]?.etag == "e2" && stored[2]?.facts.iso == 800)
        // No EXIF date: the hour of the capture time in the photo's own zone (02:00 UTC+1 → 3).
        #expect(stored[3]?.facts.hour == 3)
        #expect(stored[4]?.etag == "e4" && stored[4]?.facts.camera == nil)
        let searches = server.requests.filter { $0.method == "SEARCH" }
        #expect(searches.count == 1)
        #expect(searches[0].body.contains("<nc:metadata-photos-exif/>"))
        #expect(searches[0].body.contains("<d:literal>4</d:literal>"))
    }

    @Test func pagesThroughALargeLibraryFirst() async throws {
        try await reader().run(pause: .zero, pagingThreshold: 2) { true }
        let searches = server.requests.filter { $0.method == "SEARCH" }.map(\.body)
        // A page from the newest, the next page from the oldest photo seen (inclusive: only photos seen already, so the
        // paging ends), then the one photo the pages did not have, by id.
        #expect(searches.count == 3)
        #expect(searches[0].contains("<d:nresults>500</d:nresults>") && !searches[0].contains("<d:lte>"))
        #expect(searches[1].contains("<d:lte>") && searches[1].contains("<d:literal>3000</d:literal>"))
        #expect(searches[2].contains("<d:literal>4</d:literal>") && !searches[2].contains("<d:literal>2</d:literal>"))
        #expect(try await facts().count == 4)
    }

    @Test func stopsWhenAskedTo() async throws {
        try await reader().run(pause: .zero, pagingThreshold: 2) { false }
        #expect(server.requests.filter { $0.method == "SEARCH" }.count == 1)
    }

    @Test func nothingToDoWhenEverythingIsRead() async throws {
        try await reader().run(pause: .zero) { true }
        let before = server.requests.count
        try await reader().run(pause: .zero) { true }
        #expect(server.requests.count == before)
        // A photo the sync saw change is read again, alone.
        try LibraryStore(database: database).upsert([
            MediaItem(
                fileId: 2, path: "/Photos/2.jpg", mimeType: "image/jpeg", etag: "e2-new", capturedAt: Date(timeIntervalSince1970: 3000))
        ])
        try await reader().run(pause: .zero) { true }
        let again = server.requests.dropFirst(before).filter { $0.method == "SEARCH" }
        #expect(again.count == 1)
        #expect(again.first?.body.contains("<d:literal>2</d:literal>") == true)
        #expect(again.first?.body.contains("<d:literal>1</d:literal>") == false)
    }
}
