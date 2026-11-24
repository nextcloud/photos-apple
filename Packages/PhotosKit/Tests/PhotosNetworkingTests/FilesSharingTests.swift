// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosNetworking

@Suite struct FilesSharingParsingTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Shares as Nextcloud 36 lists them (`GET …/shares?path=…&reshares=true`), from the test server.
    let sharesJSON = """
        [{"id":"3","share_type":3,"uid_owner":"admin","displayname_owner":"admin","permissions":17,"can_edit":true,"can_delete":true,
          "stime":1795488681,"parent":null,"expiration":"2026-12-31 23:59:59","token":"ToroeRbAWXy2roz","uid_file_owner":"admin",
          "note":"","label":"Family","path":"/r3-E3-share/r3-E3-photo.jpg","item_type":"file","item_permissions":27,
          "file_target":"/r3-E3-photo.jpg","share_with":"redacted","share_with_displayname":"(Shared link)","password":"redacted",
          "send_password_by_talk":false,"url":"http://localhost:8089/index.php/s/ToroeRbAWXy2roz","mail_send":1,"hide_download":0},
         {"id":"2","share_type":0,"uid_owner":"admin","displayname_owner":"admin","permissions":31,"can_edit":true,"can_delete":true,
          "stime":1795488681,"expiration":null,"token":null,"path":"/r3-E3-share","item_type":"folder","file_target":"/r3-E3-share",
          "share_with":"r3-E3-partner","share_with_displayname":"Partner","hide_download":0},
         {"id":"9","share_type":"10","permissions":"1","path":"/a.jpg","item_type":"file","share_with":"abc123",
          "share_with_displayname":"Family chat"},
         {"share_type":0}]
        """

    @Test func parsesLinkUserAndTalkShares() throws {
        let shares = FilesSharingAPI.parseShares(try json(sharesJSON))
        #expect(shares.count == 3, "an entry without id is skipped")

        let link = shares[0]
        #expect(link.kind == .link)
        #expect(link.kind.isPublic)
        #expect(link.permissions == [.read, .share])
        #expect(link.expirationDay == "2026-12-31")
        #expect(link.hasPassword)
        #expect(link.shareWith.isEmpty, "a link's share_with holds the password hash, not a recipient")
        #expect(link.url == URL(string: "http://localhost:8089/index.php/s/ToroeRbAWXy2roz"))
        #expect(link.token == "ToroeRbAWXy2roz")
        #expect(link.label == "Family")
        #expect(!link.isFolder)
        #expect(link.createdAt == Date(timeIntervalSince1970: 1_795_488_681))

        let user = shares[1]
        #expect(user.kind == .user)
        #expect(user.isFolder)
        #expect(user.shareWith == "r3-E3-partner")
        #expect(user.shareWithDisplayName == "Partner")
        #expect(user.expirationDay == nil)
        #expect(!user.hasPassword)
        #expect(user.token == nil)

        let talk = shares[2]
        #expect(talk.kind == .talkRoom, "numbers sent as strings are read too")
        #expect(talk.permissions == .read)
    }

    @Test func shareKindsRoundTrip() {
        for raw in [0, 1, 3, 4, 6, 7, 9, 10, 15] {
            #expect(ShareKind(rawValue: raw).rawValue == raw)
        }
        #expect(ShareKind(rawValue: 15) == .other(15))
    }

    @Test func parsesRecipientsExactFirstWithoutDuplicatesOrSelf() throws {
        let data = try json(
            """
            {"exact":{"users":[{"label":"Bob","value":{"shareType":0,"shareWith":"bob"}}],"groups":[],
              "remotes":[{"label":"bob (other.example.org)","value":{"shareType":6,"shareWith":"bob@other.example.org",
                "server":"other.example.org"}}],
              "emails":[{"label":"bob@other.example.org","value":{"shareType":4,"shareWith":"bob@other.example.org"}}],
              "circles":[],"rooms":[]},
             "users":[{"label":"Bob","value":{"shareType":0,"shareWith":"bob"}},
                      {"label":"Me","value":{"shareType":0,"shareWith":"alice"}},
                      {"label":"Bobby","subline":"bobby@example.com","value":{"shareType":0,"shareWith":"bobby"}}],
             "groups":[{"label":"Board","value":{"shareType":1,"shareWith":"board"}}],
             "rooms":[{"label":"Family chat","value":{"shareType":10,"shareWith":"k3x9"}}],
             "remotes":[],"emails":[],"circles":[],"lookup":[]}
            """)
        let recipients = FilesSharingAPI.parseRecipients(data, ownUserId: "alice")
        #expect(recipients.map(\.label) == ["Bob", "bob (other.example.org)", "bob@other.example.org", "Bobby", "Board", "Family chat"])
        #expect(recipients[1].kind == .federated)
        #expect(recipients[1].detail == "other.example.org")
        #expect(recipients[2].kind == .email)
        #expect(recipients[3].detail == "bobby@example.com")
        #expect(recipients[5].kind == .talkRoom)
        #expect(recipients[5].shareWith == "k3x9")
    }

    @Test func readsSharingCapabilities() throws {
        let caps = try json(
            """
            {"files_sharing":{"api_enabled":true,"public":{"enabled":true,"password":{"enforced":true},
              "expire_date":{"enabled":true,"days":7,"enforced":true},"upload":true},"resharing":true,"group_sharing":false,
              "federation":{"outgoing":true,"incoming":true},"sharebymail":{"enabled":true,"password":{"enforced":false}},
              "default_permissions":19},
             "spreed":{"features":["chat-v2"]}}
            """)
        let sharing = SharingCapabilities(capabilities: caps)
        #expect(sharing.publicLinks)
        #expect(sharing.publicPasswordEnforced)
        #expect(sharing.publicExpiryEnforced)
        #expect(sharing.publicExpiryDays == 7)
        #expect(sharing.publicUpload)
        #expect(sharing.email)
        #expect(sharing.federationOutgoing)
        #expect(sharing.talk)
        #expect(!sharing.teams)
        #expect(sharing.defaultPermissions == [.read, .update, .share])
        #expect(sharing.recipientKinds == [.user, .federated, .federatedGroup, .email, .talkRoom], "no groups: group sharing is off")

        let bare = SharingCapabilities(capabilities: try json(#"{"files_sharing":{"public":{"enabled":false}}}"#))
        #expect(!bare.talk && !bare.email && !bare.federationOutgoing && !bare.publicLinks)
        #expect(bare.recipientKinds == [.user, .group])
    }

    @Test func updateSendsOnlyWhatChanged() {
        #expect(ShareUpdate().isEmpty)
        let update = ShareUpdate(permissions: .viewOnly, password: "", expirationDay: "2027-01-02", hideDownload: true)
        #expect(update.form == ["permissions": "1", "password": "", "expireDate": "2027-01-02", "hideDownload": "true"])
    }

    @Test func daysAreLocalCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let date = try #require(FilesSharingAPI.date(fromDay: "2026-12-31", calendar: calendar))
        #expect(FilesSharingAPI.day(of: date, calendar: calendar) == "2026-12-31")
        #expect(FilesSharingAPI.date(fromDay: "2026-12", calendar: calendar) == nil)
        #expect(FileShare.day(fromExpiration: "2026-12-31 23:59:59") == "2026-12-31")
        #expect(FileShare.day(fromExpiration: "never") == nil)
    }
}

/// Creates, changes, lists and removes shares of its own test folder on a real server (PHOTOS_IT_SERVER).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct FilesSharingIntegrationTests {
    let connection: ServerConnection
    let http = HTTPClient(trustStore: TrustStore(directory: nil))

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
    }

    @Test func linkShareLifecycle() async throws {
        let dav = DAVClient(http: http, connection: connection)
        let api = FilesSharingAPI(ocs: OCSClient(http: http, connection: connection))
        let folder = "/r3-E3-sharing-it-\(UUID().uuidString.prefix(8))"
        try await dav.mkcol(connection.filesURL(folder))
        defer { Task { [dav, connection] in try? await dav.delete(connection.filesURL(folder)) } }

        let caps = try await api.capabilities()
        #expect(caps.apiEnabled)
        try #require(caps.publicLinks)

        let link = try await api.createShare(
            path: folder, kind: .link, permissions: .viewOnly, password: "Secret-\(UUID().uuidString)", expirationDay: "2099-12-31")
        #expect(link.kind == .link)
        #expect(link.hasPassword)
        #expect(link.expirationDay == "2099-12-31")
        #expect(link.url != nil)

        let changed = try await api.updateShare(
            id: link.id, ShareUpdate(permissions: .linkUpload, password: "", expirationDay: "", label: "r3-E3"))
        #expect(changed.permissions.contains(.create))
        #expect(!changed.hasPassword)
        #expect(changed.expirationDay == nil)
        #expect(changed.label == "r3-E3")

        let listed = try await api.shares(path: folder)
        #expect(listed.map(\.id) == [link.id])

        let recipients = try await api.searchRecipients("someone@example.org", isFolder: true, kinds: caps.recipientKinds)
        if caps.email { #expect(recipients.contains { $0.kind == .email && $0.shareWith == "someone@example.org" }) }
        if caps.federationOutgoing { #expect(recipients.contains { $0.kind == .federated }) }

        // A user that does not exist: the server's own message, not "no longer exists".
        await #expect(throws: NetworkError.self) {
            _ = try await api.createShare(path: folder, kind: .user, shareWith: "r3-E3-nobody-\(UUID().uuidString)")
        }
        do {
            _ = try await api.createShare(path: folder, kind: .user, shareWith: "r3-E3-nobody-\(UUID().uuidString)")
        } catch let error as NetworkError {
            #expect(error != .notFound)
        }

        try await api.deleteShare(id: link.id)
        #expect(try await api.shares(path: folder).isEmpty)
        try await dav.delete(connection.filesURL(folder))
    }
}
