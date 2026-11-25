// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosNetworking

@Suite struct SharedFoldersTests {
    /// The top level of alice's files: her own folders (one shared with a user, one only by link, one not at all), a
    /// share she received, a read-only share, a group folder and a hidden folder.
    let rootXML = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVCK</oc:permissions></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Family%20photos/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVCK</oc:permissions><nc:mount-type></nc:mount-type>
          <oc:share-types><oc:share-type>0</oc:share-type><oc:share-type>3</oc:share-type></oc:share-types></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Holiday/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVCK</oc:permissions><nc:mount-type></nc:mount-type>
          <oc:share-types><oc:share-type>3</oc:share-type></oc:share-types></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Photos/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVCK</oc:permissions><nc:mount-type></nc:mount-type>
          <oc:share-types/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Grandpa's%20scans/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>SRGDNVCK</oc:permissions><nc:mount-type>shared</nc:mount-type>
          <oc:owner-display-name>Grandpa</oc:owner-display-name><oc:share-types/></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Read%20only/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>SG</oc:permissions><nc:mount-type>shared</nc:mount-type></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/Team%20Smith/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RMGDNVCK</oc:permissions><nc:mount-type>group</nc:mount-type></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/.nextcloud-photos/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVCK</oc:permissions><nc:mount-type>group</nc:mount-type></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/files/alice/notes.txt</d:href><d:propstat><d:prop>
          <d:resourcetype/><oc:permissions>RGDNVW</oc:permissions></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """

    let connection = ServerConnection(
        serverURL: URL(string: "https://example.com/nextcloud/")!, userId: "alice", loginName: "alice", appPassword: "secret",
        userAgent: "test")

    @Test func findsWritableSharedFolders() throws {
        let root = try MultiStatus.parse(Data(rootXML.utf8)).dropFirst()
        let received = [
            FileShare(
                id: "1", kind: .user, ownerDisplayName: "Ben", path: "/Shared/Kids", isFolder: true, permissions: [.read, .create, .update]),
            FileShare(id: "2", kind: .user, ownerDisplayName: "Ben", path: "/Shared/Tax", isFolder: true, permissions: .viewOnly),
            FileShare(
                id: "3", kind: .user, ownerDisplayName: "Grandpa", path: "/Grandpa's scans", isFolder: true, permissions: .folderEdit),
        ]
        let own = [
            FileShare(id: "4", kind: .user, path: "/Family photos", isFolder: true, shareWith: "ben", shareWithDisplayName: "Ben"),
            FileShare(id: "5", kind: .group, path: "/Family photos", isFolder: true, shareWith: "family", shareWithDisplayName: "Family"),
            FileShare(id: "6", kind: .link, path: "/Holiday", isFolder: true),
            FileShare(
                id: "7", kind: .group, path: "/Photos/2026/Wedding", isFolder: true, shareWith: "family", shareWithDisplayName: "Family"),
            FileShare(id: "8", kind: .user, path: "/Photos/a.jpg", isFolder: false, shareWith: "ben"),
        ]
        let folders = PhotosAPI.sharedFolders(root: Array(root), received: received, own: own, connection: connection)
        #expect(folders.map(\.path) == ["/Family photos", "/Grandpa's scans", "/Shared/Kids", "/Team Smith", "/Photos/2026/Wedding"])
        let family = try #require(folders.first)
        #expect(family.kind == .own)
        #expect(family.sharedWith == ["Ben", "Family"])
        #expect(folders[1].kind == .received)
        #expect(folders[1].ownerDisplayName == "Grandpa")
        #expect(folders[2].ownerDisplayName == "Ben")
        #expect(folders[3].kind == .groupFolder)
        #expect(folders[4].name == "Wedding")
    }

    @Test func nothingSharedMeansNoFolders() throws {
        let root = try MultiStatus.parse(Data(rootXML.utf8)).dropFirst().filter { $0.href.contains("/Photos/") }
        #expect(PhotosAPI.sharedFolders(root: root, received: [], own: [], connection: connection).isEmpty)
    }
}
