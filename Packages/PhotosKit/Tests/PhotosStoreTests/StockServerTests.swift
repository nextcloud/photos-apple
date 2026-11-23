// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Answers requests with responses recorded from real servers (`Fixtures/<server>/`, user `admin`, Nextcloud 36):
///
/// - `stock-master`: the Photos app as on upstream master (`8258010a9`, 9.0.0-dev.0), none of the feature branches;
/// - `photos-8.0.0`: the released Photos 8.0.0 (`v35.0.3`), force-enabled on Nextcloud 36;
/// - `extended`: `deploy/devel-all`, all feature branches (9.0.0-dev.3).
///
/// Recorded with `curl` against local test servers on 2026-11-23. Requests are matched by method, path and `Depth`;
/// anything not recorded answers 404 like Nextcloud does for unknown routes. `overrides` replace single routes with
/// errors to test how detection and sync cope with failing probes.
final class RecordedServer: Sendable {
    enum Response: Sendable {
        case file(Int, String)
        case status(Int, String)
        case failure(URLError.Code)
    }

    let fixtures: String
    let host = "rec-\(UUID().uuidString.prefix(8).lowercased()).test"
    let overrides = Mutex<[String: Response]>([:])
    let log = Mutex<[(line: String, body: String)]>([])
    static let registry = Mutex<[String: RecordedServer]>([:])

    init(_ fixtures: String) {
        self.fixtures = fixtures
        Self.registry.withLock { $0[host] = self }
    }

    deinit {
        let host = self.host
        Self.registry.withLock { $0[host] = nil }
    }

    var connection: ServerConnection {
        ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: "admin", loginName: "admin", appPassword: "secret", userAgent: "tests")
    }

    var api: PhotosAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordedProtocol.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        return PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    var detector: FeatureDetector { FeatureDetector(dav: api.dav, ocs: api.ocs) }

    /// "METHOD /path" of every request, in order.
    var lines: [String] { log.withLock { $0.map(\.line) } }
    var bodies: [String] { log.withLock { $0.map(\.body) } }

    func override(_ line: String, with response: Response) { overrides.withLock { $0[line] = response } }

    static let notFound = Response.status(
        404,
        #"<?xml version="1.0" encoding="utf-8"?><d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><s:exception>Sabre\DAV\Exception\NotFound</s:exception><s:message>Not found</s:message></d:error>"#
    )
    static let emptyMultistatus = Response.status(
        207, #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"/>"#)

    func response(method: String, path: String, depth: String?, body: String) -> Response {
        let line = "\(method) \(path)"
        log.withLock { $0.append((line, body)) }
        if let override = overrides.withLock({ $0[line] }) { return override }
        let ocsStatus = Self.ocsStatus[fixtures]
        switch (method, path) {
        case ("GET", "/ocs/v2.php/cloud/capabilities"): return .file(200, "capabilities.json")
        case ("GET", "/index.php/apps/photos/"), ("GET", "/index.php/apps/photos"): return .file(200, "photos-page.html")
        case ("GET", "/ocs/v2.php/apps/photos/api/v1/timeline/days"):
            return .file(ocsStatus?["timeline-days"] ?? 404, "timeline-days.json")
        case ("GET", "/ocs/v2.php/apps/photos/api/v1/config"): return .file(404, "config.json")
        case ("GET", "/ocs/v2.php/taskprocessing/tasktypes"): return .file(200, "tasktypes.json")
        case ("GET", "/ocs/v2.php/search/providers"): return .file(200, "search-providers.json")
        case ("PROPFIND", "/remote.php/dav/photos/admin/"): return .file(207, "photos-home.xml")
        case ("PROPFIND", "/remote.php/dav/photos/admin/places/"):
            return .file(207, depth == "0" ? "places-root.xml" : "places.xml")
        case ("PROPFIND", "/remote.php/dav/photos/admin/albums/"): return .file(207, "albums.xml")
        case ("PROPFIND", "/remote.php/dav/photos/admin/sharedalbums/"): return .file(207, "sharedalbums.xml")
        case ("PROPFIND", "/remote.php/dav/photos/admin/albums/Lisbon 2025/"): return .file(207, "album-lisbon.xml")
        case ("PROPFIND", "/remote.php/dav/files/admin/Photos"), ("PROPFIND", "/remote.php/dav/files/admin/Photos/"):
            return .file(207, "photos-folder.xml")
        case ("PROPFIND", "/remote.php/dav/systemtags/"): return .file(207, "systemtags.xml")
        case ("SEARCH", "/remote.php/dav/"):
            // The favourites check asks for `oc:favorite = 1`: none of the recorded photos is a favourite.
            if body.contains("<oc:favorite/></d:prop><d:literal>1</d:literal>") { return Self.emptyMultistatus }
            return .file(207, "search-index.xml")
        default: return Self.notFound
        }
    }

    /// Status of recorded OCS answers that differ between the servers.
    static let ocsStatus: [String: [String: Int]] = ["extended": ["timeline-days": 200]]

    func data(_ file: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures/\(fixtures)"))
        var data = try Data(contentsOf: url)
        if file.hasSuffix(".html") { data = Data("<!DOCTYPE html><html><body>".utf8) + data + Data("</body></html>".utf8) }
        return data
    }
}

/// `@unchecked Sendable`: `URLProtocol` is not Sendable; an instance is only used by the URL loading system.
final class RecordedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = RecordedServer.registry.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
        let response = server.response(
            method: request.httpMethod ?? "GET", path: url.path(percentEncoded: false), depth: request.value(forHTTPHeaderField: "Depth"),
            body: body)
        let status: Int
        let data: Data
        switch response {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        case .status(let code, let text):
            status = code
            data = Data(text.utf8)
        case .file(let code, let name):
            guard let loaded = try? server.data(name) else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
                return
            }
            status = code
            data = loaded
        }
        let type = data.first == UInt8(ascii: "{") ? "application/json" : data.first == UInt8(ascii: "<") ? "application/xml" : "text/html"
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What the app finds on servers with and without the new Photos features, from recorded responses.
@Suite struct StockServerDetectionTests {
    static let core: Set<ServerFeature> = [.photosDAV, .places, .systemtags, .trashbin, .comments, .publicLinks, .metadataEdit]

    @Test(arguments: ["stock-master", "photos-8.0.0"])
    func stockPhotosHasOnlyCoreFeatures(fixtures: String) async throws {
        let server = RecordedServer(fixtures)
        let features = try await server.detector.detect()
        #expect(features.enabled == Self.core, "\(features.enabled.sorted())")
        #expect(!features.hasExtendedFeatures)
        #expect(features.serverVersion.major == 36)
        #expect(features.photosAppVersion == nil)
        #expect(features.fingerprint == "36.0.0 dev")
        // Settings come from the page's initial state; the extended keys are not there.
        #expect(features.userConfig.photosSourceFolders == ["/Photos"])
        #expect(features.userConfig.smartAlbums == nil)
        #expect(features.userConfig.onThisDayNotifications == nil)
        #expect(features.imageMimeTypes.contains("image/heic"))
        #expect(!features.videoMimeTypes.contains("video/webm"))
        // Probing is read-only and asks for no companion API.
        #expect(server.lines.allSatisfy { $0.hasPrefix("GET ") || $0.hasPrefix("PROPFIND ") }, "\(server.lines)")
        #expect(!server.lines.contains { $0.contains("/recognize/key") || $0.contains("/api/v1/sync") })
    }

    @Test func extendedPhotosLightsUpItsFeatures() async throws {
        let server = RecordedServer("extended")
        let features = try await server.detector.detect()
        let expected: Set<ServerFeature> = [
            .albumCover, .albumDescription, .albumComments, .albumLastModified, .placeCountry, .timelineDays, .captions,
            .captionsSearchable, .onThisDayNotifications, .unifiedSearchPhotos, .configAPI,
        ]
        #expect(features.enabled.isSuperset(of: Self.core.union(expected)), "\(features.enabled.sorted())")
        #expect(features.hasExtendedFeatures)
        #expect(features.userConfig.smartAlbums == [])
        #expect(features.videoMimeTypes.contains("video/webm"))
        // Not offered by that server (needs the admin switch, ffmpeg or the companion APIs).
        #expect(!features.has(.videoRenditions) && !features.has(.syncFeed) && !features.has(.recognizeKeyAPI))
    }

    /// Probes that fail (server error, timeout) only turn their own feature off; detection itself succeeds.
    @Test func failingProbesTurnTheirFeatureOff() async throws {
        let server = RecordedServer("extended")
        server.override("GET /ocs/v2.php/apps/photos/api/v1/timeline/days", with: .status(500, "{}"))
        server.override("PROPFIND /remote.php/dav/photos/admin/albums/", with: .failure(.timedOut))
        server.override("PROPFIND /remote.php/dav/photos/admin/sharedalbums/", with: .status(503, ""))
        server.override("GET /ocs/v2.php/search/providers", with: .status(502, "bad gateway"))
        server.override("GET /ocs/v2.php/taskprocessing/tasktypes", with: .status(200, "not json"))
        let features = try await server.detector.detect()
        for feature in [
            ServerFeature.timelineDays, .albumCover, .albumDescription, .albumComments, .albumLastModified, .unifiedSearchPhotos,
        ] {
            #expect(!features.has(feature), "\(feature)")
        }
        #expect(features.enabled.isSuperset(of: Self.core))
        #expect(features.has(.placeCountry))
    }

    /// A user without albums of their own: the album properties are probed on an album shared with them.
    @Test func albumFeaturesAreFoundOnSharedAlbums() async throws {
        let server = RecordedServer("extended")
        let albums = String(decoding: try server.data("albums.xml"), as: UTF8.self)
        server.override("PROPFIND /remote.php/dav/photos/admin/albums/", with: RecordedServer.emptyMultistatus)
        server.override(
            "PROPFIND /remote.php/dav/photos/admin/sharedalbums/",
            with: .status(207, albums.replacingOccurrences(of: "/photos/admin/albums/", with: "/photos/admin/sharedalbums/")))
        let features = try await server.detector.detect()
        #expect(features.has(.albumCover) && features.has(.albumDescription) && features.has(.albumComments))
    }

    /// Without the Photos page (Photos disabled for the user, or a broken page) the app falls back to defaults.
    @Test func missingPhotosPageFallsBackToDefaults() async throws {
        let server = RecordedServer("stock-master")
        server.override("GET /index.php/apps/photos", with: .status(500, "<html>error</html>"))
        let features = try await server.detector.detect()
        #expect(features.has(.photosDAV))
        #expect(features.userConfig.photosSourceFolders == ["/Photos"])
        #expect(features.imageMimeTypes == MimeTypes.defaultImages)
    }

    /// Detection fails only when the capabilities fail. Unreachable: the cache stays. Error answer: only core features.
    @Test func failedDetectionNeverKeepsExtendedFeatures() async throws {
        let extended = try await RecordedServer("extended").detector.detect()
        let failing = RecordedServer("extended")
        failing.override("GET /ocs/v2.php/cloud/capabilities", with: .status(500, "{}"))
        await #expect(throws: (any Error).self) { try await failing.detector.detect() }
        do {
            _ = try await failing.detector.detect()
        } catch {
            let fallback = try #require(FeatureDetector.fallback(after: error, cached: extended))
            #expect(!fallback.hasExtendedFeatures)
            #expect(fallback.enabled.isSuperset(of: Self.core))
            #expect(fallback.userConfig.smartAlbums == nil)
        }
        let offline = RecordedServer("extended")
        offline.override("GET /ocs/v2.php/cloud/capabilities", with: .failure(.notConnectedToInternet))
        do {
            _ = try await offline.detector.detect()
            Issue.record("detection should fail offline")
        } catch {
            #expect(FeatureDetector.fallback(after: error, cached: extended) == nil)
        }
    }

    /// The capabilities fingerprint tells an upgraded or downgraded server apart, so the app detects again.
    @Test func fingerprintChangesWithTheServer() async throws {
        let stock = try await RecordedServer("stock-master").detector.currentFingerprint()
        #expect(stock == "36.0.0 dev")
        let capability = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"version":{"string":"36.0.0 dev"},"capabilities":{"photos":{"version":"9.1.0","features":["timeline-days","album-cover"]}}}"#
                    .utf8))
        #expect(FeatureDetector.fingerprint(capability) == "36.0.0 dev|photos 9.1.0|album-cover,timeline-days")
        #expect(FeatureDetector.fingerprint(capability) != stock)
    }

    @Test func recognizeKeySkipsTheCompanionEndpointWhenAbsent() async throws {
        let server = RecordedServer("stock-master")
        #expect(try await server.api.fetchRecognizeKey(companionAPI: false) == nil)
        #expect(server.lines.count == 1 && server.lines[0].hasPrefix("GET /index.php/apps/photos"))
    }
}

/// Properties a stock server does not know come back in a 404 propstat; they must read as "missing", never as an error.
@Suite struct StockServerParsingTests {
    let server = RecordedServer("stock-master")

    @Test func albumsWithoutExtendedProperties() async throws {
        let albums = try await server.api.listAlbums(.own, extended: true)
        #expect(albums.count == 7)
        let lisbon = try #require(albums.first { $0.name == "Lisbon 2025" })
        #expect(lisbon.itemCount == 10)
        #expect(lisbon.location == "Lisbon")
        #expect(lisbon.serverAlbumId == nil)
        #expect(lisbon.lastModified == nil)
        #expect(lisbon.albumDescription.isEmpty)
        #expect(lisbon.filters == AlbumFilters())

        let raw = try await server.api.dav.propfind(
            server.api.albumsHomeURL(.own), depth: 1, properties: DAVProp.album + DAVProp.albumExtended)
        #expect(raw[1].missing.isSuperset(of: [DAVProp.cover, DAVProp.albumDescription, DAVProp.albumId, DAVProp.lastModified]))
        #expect(raw[1].properties[DAVProp.cover] == nil)
    }

    @Test func placesWithoutCountry() async throws {
        let places = try await server.api.listPlaces(withCountry: true)
        #expect(places.count == 36)
        #expect(places.allSatisfy { $0.countryCode == nil && $0.itemCount > 0 })
    }

    @Test func indexWithoutCaptionsAndCountries() async throws {
        let page = try await server.api.indexPage(
            sourceFolders: ["/Photos"], mimeTypes: ["image/jpeg"], properties: DAVProp.mediaIndex + DAVProp.mediaIndexExtended,
            before: nil)
        #expect(page.items.count == 14)
        // A short page is not the end (the server may have left entries out); the page after it is. The recorded
        // server ignores the cursor and repeats itself, which must end the listing too.
        let cursor = try #require(page.next)
        let rest = try await server.api.indexPage(
            sourceFolders: ["/Photos"], mimeTypes: ["image/jpeg"], properties: DAVProp.mediaIndex + DAVProp.mediaIndexExtended,
            before: cursor)
        #expect(rest.next == nil)
        // The recorded server still has `photos-place-country` in its file metadata from an earlier deployment of the
        // feature branches, and core serves any metadata key; the app only asks for it when `placeCountry` is detected.
        for item in page.items {
            #expect(item.caption == nil && item.duration == nil, "\(item.name)")
            #expect(item.place == "Lisbon", "\(item.name): \(item.place ?? "-")")
        }
        let raw = try await server.api.dav.search(
            DAVSearch(select: DAVProp.mediaIndex + [DAVProp.metadataCaption], scopes: [DAVSearch.Scope(href: "/files/admin/Photos")]))
        #expect(raw.allSatisfy { $0.missing.contains(DAVProp.metadataCaption) })
    }
}

/// Sync, albums, places and memories against a stock server, with the features detected there.
@Suite struct StockServerSyncTests {
    @Test func syncAlbumsPlacesAndMemoriesWork() async throws {
        let server = RecordedServer("stock-master")
        let features = try await server.detector.detect()
        let database = try AccountDatabase.temporary()
        let engine = SyncEngine(api: server.api, database: database, features: features, reconcileInterval: 0)
        let library = LibraryStore(database: database)
        let detection = server.lines.count

        await engine.sync()
        #expect(try library.count() == 14)
        #expect(try library.gridItems(.all).count == 14)
        try await engine.refreshAlbums()
        let collections = CollectionStore(database: database)
        #expect(try collections.albums(.own).count == 7)
        let lisbon = try #require(try collections.albums(.own).first { $0.name == "Lisbon 2025" })
        try await engine.refreshAlbumContent(lisbon)
        #expect(try collections.albumItems(albumId: lisbon.id).count == 10)
        try await engine.refreshPlaces()
        #expect(try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM place") } == 36)

        // Memories are computed on the device: a year after the Lisbon trip, the trip is "on this day".
        let now = try #require(DateComponents(calendar: .current, year: 2026, month: 1, day: 13, hour: 12).date)
        let memories = try await library.memories(now: now)
        #expect(!memories.onThisDay.isEmpty)

        // Nothing of a newer Photos version was asked for: no extended endpoint, no extended property.
        let syncLines = Array(server.lines.dropFirst(detection))
        let syncBodies = Array(server.bodies.dropFirst(detection))
        #expect(!syncLines.contains { $0.contains("/ocs/") }, "\(syncLines)")
        for property in ["metadata-photos-caption", "metadata-photos-place-country", "metadata-photos-duration", "nc:cover", "album-id"] {
            #expect(!syncBodies.contains { $0.contains(property) }, "\(property)")
        }
    }
}

@Suite struct FeatureFallbackTests {
    @Test func coreOnlyAndRemoving() {
        var features = ServerFeatures(
            serverVersion: ServerVersion(major: 36),
            enabled: [.photosDAV, .places, .albumCover, .taskOCR, .syncFeed, .onThisDayNotifications])
        features.userConfig.smartAlbums = []
        features.userConfig.onThisDayNotifications = true
        #expect(features.hasExtendedFeatures)
        #expect(features.coreOnly.enabled == [.photosDAV, .places])
        #expect(features.coreOnly.userConfig.onThisDayNotifications == nil)
        let withoutDay = features.removing([.onThisDayNotifications])
        #expect(!withoutDay.has(.onThisDayNotifications) && withoutDay.has(.albumCover))
        #expect(withoutDay.userConfig.onThisDayNotifications == nil && withoutDay.userConfig.smartAlbums == [])
        #expect(features.removing([.configAPI]).userConfig.smartAlbums == nil)
    }

    @Test func missingAPIErrors() {
        #expect(FeatureDetector.isMissingAPI(NetworkError.notFound))
        #expect(FeatureDetector.isMissingAPI(NetworkError.http(status: 400, message: nil)))
        #expect(FeatureDetector.isMissingAPI(NetworkError.http(status: 501, message: nil)))
        #expect(!FeatureDetector.isMissingAPI(NetworkError.http(status: 500, message: nil)))
        #expect(!FeatureDetector.isMissingAPI(NetworkError.offline))
        #expect(!FeatureDetector.isMissingAPI(NetworkError.forbidden(message: nil)))
        #expect(FeatureDetector.feature(for: .smartAlbums) == .configAPI)
        #expect(FeatureDetector.feature(for: .onThisDayNotifications) == .onThisDayNotifications)
        #expect(FeatureDetector.feature(for: .photosSourceFolders) == nil)
    }

    /// Features cached by an older app version (without a fingerprint) still load, and then differ from any server.
    @Test func cachedFeaturesWithoutFingerprintStillDecode() throws {
        var features = ServerFeatures(serverVersion: ServerVersion(major: 36), enabled: [.photosDAV])
        features.fingerprint = nil
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(features)) as? [String: Any])
        json["fingerprint"] = nil
        let decoded = try JSONDecoder().decode(ServerFeatures.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.fingerprint == nil && decoded.has(.photosDAV))
    }
}
