// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

let connection = ServerConnection(
    serverURL: URL(string: "https://example.com/nextcloud/")!, userId: "alice", loginName: "alice@example.com", appPassword: "secret",
    userAgent: "test")

@Suite struct MultiStatusTests {
    @Test func parsesAlbumAndChildren() throws {
        let resources = try MultiStatus.parse(fixture("album-children.xml"))
        #expect(resources.count == 2)
        let album = try #require(MediaParser.album(from: resources[0], kind: .own))
        #expect(album.name == "Lisbon 2025")
        #expect(album.title == "Lisbon 2025")
        #expect(album.itemCount == 10)
        #expect(album.location == "Lisbon")
        #expect(album.lastPhotoFileId == 2991, "\(resources[0].properties.keys.map(\.name).sorted())")
        #expect(album.dateStart == Date(timeIntervalSince1970: 1_736_768_973))

        let child = try #require(MediaParser.collectionChild(from: resources[1]))
        #expect(child.childName == "2984-Lisbon (54269600073).jpg")
        #expect(child.origin == "user")
        #expect(child.ownerPath == "/Photos/Test library/Travel/Lisbon/Lisbon (54269600073).jpg")
        #expect(child.item.fileId == 2984)
        #expect(child.item.width == 1920)
        #expect(child.item.height == 1310)
        #expect(child.item.place == "Lisbon")
        #expect(abs((child.item.latitude ?? 0) - 38.71748) < 0.001)
        #expect(child.item.capturedAt == Date(timeIntervalSince1970: 1_736_774_100))
        #expect(child.item.livePhotoPeer == nil)
        #expect(resources[1].missing.contains(DAVProp.metadataLivePhoto))
    }

    @Test func parsesSearchResultsWithServerPathAndLivePhotos() throws {
        let resources = try MultiStatus.parse(fixture("search-files.xml"))
        let items = resources.compactMap { MediaParser.mediaItem(from: $0, connection: connection) }
        #expect(items.count == 2)  // the folder is skipped
        let still = items[0]
        #expect(still.path == "/Photos/2026/IMG_0001.HEIC")
        #expect(still.etag == "abc123")
        #expect(still.isFavorite)
        #expect(still.isLivePhoto)
        #expect(still.livePhotoPeer == 43)
        #expect(still.isOwnStorage)
        #expect(still.capturedAt == nil)
        #expect(still.timestamp == HTTPDate.parse("Sun, 22 Nov 2026 10:00:00 GMT"))
        #expect(items[1].isLivePhotoVideo)
    }
}

@Suite struct RequestBodyTests {
    @Test func searchBodyEscapesAndNests() throws {
        let search = DAVSearch(
            select: [DAVProp.fileId],
            scopes: [DAVSearch.Scope(href: connection.filesHref("/Photos & Videos"))],
            condition: .and([PhotosAPI.mimeCondition(["image/jpeg", "video/mp4"]), .like(DAVProp.displayName, "%a<b%")]),
            orderBy: [DAVSearch.Order(DAVProp.metadataOriginalDateTime)],
            limit: 200, offset: 400)
        let body = String(decoding: search.body, as: UTF8.self)
        #expect(body.contains("<d:href>/files/alice/Photos &amp; Videos</d:href>"))
        #expect(body.contains("<d:or><d:eq><d:prop><d:getcontenttype/></d:prop><d:literal>image/jpeg</d:literal></d:eq>"))
        #expect(body.contains("<d:literal>%a&lt;b%</d:literal>"))
        #expect(body.contains("<nc:metadata-photos-original_date_time/></d:prop><d:descending/>"))
        #expect(body.contains("<d:nresults>200</d:nresults><ns:firstresult>400</ns:firstresult>"))
        _ = try XMLTreeParser.parse(search.body)  // well-formed
    }

    @Test func proppatchEscapesJSON() throws {
        let json = PhotosAPI.collaboratorsJSON([
            Collaborator(id: "bob", label: "Bob <B>", type: .user), Collaborator(id: "", label: "Public link", type: .publicLink),
        ])
        let body = DAVBody.proppatch(set: [(DAVProp.collaborators, .text(json))])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("Bob &lt;B&gt;"))
        #expect(text.contains("&quot;type&quot;:3"))
        _ = try XMLTreeParser.parse(body)
    }

    @Test func likeEscaping() {
        #expect(DAVSearch.Condition.likeEscaped("50%_off\\") == "50\\%\\_off\\\\")
    }
}

@Suite struct ConnectionTests {
    @Test func urlsAreEncodedPerSegment() {
        #expect(connection.serverURL.absoluteString == "https://example.com/nextcloud")
        #expect(
            connection.filesURL("/Photos/a b#1.jpg").absoluteString
                == "https://example.com/nextcloud/remote.php/dav/files/alice/Photos/a%20b%231.jpg")
        #expect(connection.userPath(fromHref: "/nextcloud/remote.php/dav/files/alice/Photos/x.jpg") == "/Photos/x.jpg")
        #expect(connection.authorizationHeader == "Basic " + Data("alice@example.com:secret".utf8).base64EncodedString())
    }

    @Test func normalizesAddresses() {
        #expect(LoginService.normalizeServerAddress("cloud.example.com/")?.absoluteString == "https://cloud.example.com")
        #expect(LoginService.normalizeServerAddress("http://x.org/index.php")?.absoluteString == "http://x.org")
        #expect(LoginService.normalizeServerAddress("  ") == nil)
    }

    @Test func parsesLoginLinks() throws {
        let credentials = try #require(
            LoginService.parseLoginURL("nc://login/server:https://cloud.example.com&user:bob%40x&password:app-pw"))
        #expect(credentials.serverURL.absoluteString == "https://cloud.example.com")
        #expect(credentials.loginName == "bob@x")
        #expect(credentials.appPassword == "app-pw")
    }

    @Test func previewBuckets() {
        #expect(PhotosAPI.previewBucket(forPixels: 60) == 64)
        #expect(PhotosAPI.previewBucket(forPixels: 300) == 256)
        #expect(PhotosAPI.previewBucket(forPixels: 400) == 1024)
        #expect(PhotosAPI.previewBucket(forPixels: 5000) == 4096)
    }
}

@Suite struct InitialStateTests {
    @Test func scrapesPhotosInitialState() throws {
        func input(_ key: String, _ json: String) -> String {
            "<input type=\"hidden\" id=\"initial-state-photos-\(key)\" value=\"\(Data(json.utf8).base64EncodedString())\">"
        }
        let html =
            "<html><body>" + input("image-mimes", #"["image/jpeg","image/gif"]"#)
            + input("photosSourceFolders", #""[\"/Photos\",\"/Camera\"]""#)
            + input("recognizeApiKey", #""KEY""#) + input("nomedia-paths", #"["/Photos/WhatsApp"]"#)
            + "<input type=\"hidden\" id=\"initial-state-core-config\" value=\"e30=\"></body></html>"
        let state = InitialStateScraper.parse(html: html)
        #expect(state.count == 4)
        var features = ServerFeatures(serverVersion: ServerVersion(major: 33))
        FeatureDetector.applyInitialState(state, to: &features)
        #expect(features.imageMimeTypes == ["image/jpeg", "image/gif"])
        #expect(features.userConfig.photosSourceFolders == ["/Photos", "/Camera"])
        #expect(features.recognizeAPIKey == "KEY")
        #expect(features.nomediaPaths == ["/Photos/WhatsApp"])
        #expect(features.has(.photosDAV))
    }

    @Test func appliesPhotosCapability() throws {
        let json =
            #"{"version":"9.1.0","features":["timeline-days","album-cover","sync-feed"],"mimetypes":{"image":["image/png"],"video":["video/mp4"]},"captions":{"enabled":true,"searchable":false}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        var features = ServerFeatures(serverVersion: ServerVersion(major: 36))
        FeatureDetector.applyPhotosCapability(value, to: &features)
        #expect(features.has(.timelineDays) && features.has(.albumCover) && features.has(.syncFeed))
        #expect(features.has(.captions) && !features.has(.captionsSearchable))
        #expect(features.imageMimeTypes == ["image/png"])
        #expect(features.photosAppVersion == "9.1.0")
    }
}

/// A photo of someone else's shared album is fetched through the album, never by its name in the user's own files.
@Suite struct SharedAlbumChildTests {
    static let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/sharedalbums/Trip%20(bob)/731-IMG_1234.JPG</d:href>
        <d:propstat><d:prop>
         <d:getcontentlength>1000</d:getcontentlength><d:getcontenttype>image/jpeg</d:getcontenttype>
         <d:getetag>"e1"</d:getetag><d:resourcetype/><oc:fileid>731</oc:fileid><nc:has-preview>true</nc:has-preview>
         <nc:photos-album-file-origin>user</nc:photos-album-file-origin>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><nc:photos-collection-file-original-filename/><nc:file-name/></d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        </d:multistatus>
        """

    @Test func itsOriginalIsTheAlbumChild() throws {
        let resource = try #require(try MultiStatus.parse(Data(Self.xml.utf8)).first)
        let child = try #require(MediaParser.collectionChild(from: resource))
        #expect(child.ownerPath == nil)
        #expect(child.item.name == "IMG_1234.JPG")
        #expect(child.item.isCollectionChild)
        #expect(!child.item.isOwnStorage)
        #expect(child.item.path == "photos/alice/sharedalbums/Trip (bob)/731-IMG_1234.JPG")
        let url = connection.originalURL(path: child.item.path)
        #expect(url.host() == "example.com")
        #expect(url.path(percentEncoded: false) == "/nextcloud/remote.php/dav/photos/alice/sharedalbums/Trip (bob)/731-IMG_1234.JPG")
        // Not /files/alice/IMG_1234.JPG, where Alice may have a different photo of the same name.
        #expect(!url.absoluteString.contains("/files/"))
        // The user's own files keep their path.
        let own = connection.originalURL(path: "/Photos/a.jpg").absoluteString
        #expect(own == "https://example.com/nextcloud/remote.php/dav/files/alice/Photos/a.jpg")
    }

    @Test func anOwnFileKeepsItsPath() throws {
        let resources = try MultiStatus.parse(fixture("album-children.xml"))
        let child = try #require(MediaParser.collectionChild(from: resources[1]))
        #expect(child.item.path == "/Photos/Test library/Travel/Lisbon/Lisbon (54269600073).jpg")
        #expect(child.item.isOwnStorage)
        #expect(!child.item.isCollectionChild)
    }
}
