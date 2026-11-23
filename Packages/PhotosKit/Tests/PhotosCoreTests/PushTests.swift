// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import Testing
import UserNotifications

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

@Suite struct PushPayloadTests {
    let account = makeAccount("alice", server: "https://cloud.example.com").id

    func decode(_ json: String) throws -> PushNotifications.Payload {
        try JSONDecoder().decode(PushNotifications.Payload.self, from: Data(json.utf8))
    }

    @Test func photosNotificationIsShown() throws {
        let payload = try decode(#"{"app":"photos","subject":"On this day: 3 years ago","type":"onthisday","id":"1","nid":42}"#)
        guard case .show(let presentation) = PushNotifications.action(for: payload) else {
            Issue.record("expected the notification to be shown")
            return
        }
        #expect(presentation.title == "Nextcloud Photos")
        #expect(presentation.body == "On this day: 3 years ago")
        #expect(presentation.notificationId == 42)
    }

    @Test func notificationsOfOtherAppsAreSuppressed() throws {
        for app in ["files_sharing", "spreed", "updatenotification", "Photos2"] {
            let payload = try decode(#"{"app":"\#(app)","subject":"Somebody shared a file with you","type":"file","id":"1","nid":7}"#)
            #expect(PushNotifications.action(for: payload) == .suppress)
        }
        // Nothing to show is not a notification either.
        #expect(PushNotifications.action(for: try decode(#"{"app":"photos","subject":""}"#)) == .suppress)
        #expect(PushNotifications.action(for: try decode(#"{"nid":7}"#)) == .suppress)
    }

    /// Delete pushes carry no `app` and no `subject`; they used to fail decoding and were shown as empty notifications.
    @Test func deletePushesRemoveInsteadOfShowing() throws {
        #expect(PushNotifications.action(for: try decode(#"{"nid":42,"delete":true}"#)) == .removeDelivered([42]))
        #expect(PushNotifications.action(for: try decode(#"{"nids":[1,2,3],"delete-multiple":true}"#)) == .removeDelivered([1, 2, 3]))
        #expect(PushNotifications.action(for: try decode(#"{"delete-all":true}"#)) == .removeAllDelivered)
    }

    @Test func deletePushRemovesOnlyTheWithdrawnNotificationsOfItsAccount() {
        let other = makeAccount("bob", server: "https://cloud.example.com").id
        let delivered = [
            PushNotifications.Delivered(identifier: "a", account: account.rawValue, notificationId: 1),
            PushNotifications.Delivered(identifier: "b", account: account.rawValue, notificationId: 2),
            PushNotifications.Delivered(identifier: "c", account: other.rawValue, notificationId: 1),
            PushNotifications.Delivered(identifier: "d", account: nil, notificationId: nil),
        ]
        #expect(PushNotifications.identifiersToRemove(.removeDelivered([1]), account: account, delivered: delivered) == ["a"])
        #expect(PushNotifications.identifiersToRemove(.removeAllDelivered, account: account, delivered: delivered) == ["a", "b"])
        #expect(PushNotifications.identifiersToRemove(.suppress, account: account, delivered: delivered) == [])
    }

    @Test func shownNotificationRemembersItsServerId() {
        let content = UNMutableNotificationContent()
        let presentation = PushNotifications.Presentation(
            title: "Nextcloud Photos", body: "On this day", threadIdentifier: "photos", destination: "onThisDay", notificationId: 42)
        PushNotifications.apply(presentation, account: account, to: content)
        #expect(content.title == "Nextcloud Photos")
        #expect(content.body == "On this day")
        #expect(content.userInfo[PushNotifications.notificationIdKey] as? Int == 42)
        #expect(content.userInfo[PushNotifications.accountKey] as? String == account.rawValue)
        #expect(content.userInfo[PushNotifications.destinationKey] as? String == "onThisDay")
    }

    @Test func decryptsWithTheAccountKeyOnly() throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let key = try PushNotifications.loadOrCreateKey(account: account, keychain: sandbox.keychain)
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let plain = Data(#"{"nid":42,"delete":true}"#.utf8)
        let encrypted = try #require(SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA1, plain as CFData, nil) as Data?)
        let subject = encrypted.base64EncodedString()

        let payload = PushNotifications.decrypt(subject, account: account, keychain: sandbox.keychain)
        #expect(payload == PushNotifications.Payload(nid: 42, delete: true))
        // After the key is gone (notifications turned off, account removed) nothing can be read any more.
        sandbox.keychain.delete(Keychain.pushPrivateKeyKey(account.rawValue))
        #expect(PushNotifications.decrypt(subject, account: account, keychain: sandbox.keychain) == nil)
    }

    @Test func launchRegistersOnlyWithExistingPermission() {
        #expect(PushNotifications.shouldRegisterAtLaunch(.authorized))
        #expect(PushNotifications.shouldRegisterAtLaunch(.provisional))
        #expect(!PushNotifications.shouldRegisterAtLaunch(.notDetermined))
        #expect(!PushNotifications.shouldRegisterAtLaunch(.denied))
    }
}

/// The Notifications switch, against a stubbed server and push proxy.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PushToggleTests {
    let sandbox = Sandbox()
    let server = StubServer()
    let pushPaths = ["notifications/api/v2/push", "/devices"]

    func makeApp() throws -> (AppModel, Account, UserDefaults) {
        let account = makeAccount("alice", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        return (app, account, defaults)
    }

    func pushRequests() -> [String] { server.lines(containing: "notifications/api/v2/push", "/devices") }

    @Test func tokenRegistersAccountsAndTurningOffUnregistersThem() async throws {
        defer { sandbox.remove() }
        let (app, account, defaults) = try makeApp()
        #expect(app.pushEnabled)

        app.didRegisterForPush(deviceToken: Data([0xAB, 0xCD]))
        #expect(await eventually { PushNotifications.isRegistered(account.id, keychain: sandbox.keychain) })
        #expect(pushRequests() == ["POST /ocs/v2.php/apps/notifications/api/v2/push", "POST /devices"])
        #expect(sandbox.keychain.data(for: Keychain.pushPrivateKeyKey(account.id.rawValue)) != nil)

        await app.setPushEnabled(false)

        #expect(!app.pushEnabled)
        #expect(!PushNotifications.isEnabled(defaults))
        #expect(
            pushRequests() == [
                "POST /ocs/v2.php/apps/notifications/api/v2/push", "POST /devices", "DELETE /ocs/v2.php/apps/notifications/api/v2/push",
                "DELETE /devices",
            ])
        #expect(!PushNotifications.isRegistered(account.id, keychain: sandbox.keychain))
        #expect(sandbox.keychain.data(for: Keychain.pushPrivateKeyKey(account.id.rawValue)) == nil)

        // While it is off, a new device token registers nothing.
        app.didRegisterForPush(deviceToken: Data([0xAB, 0xCD]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(pushRequests().count == 4)

        // Turning it on again registers with the token the app already has.
        await app.setPushEnabled(true)
        #expect(await eventually { PushNotifications.isRegistered(account.id, keychain: sandbox.keychain) })
        #expect(pushRequests().suffix(2) == ["POST /ocs/v2.php/apps/notifications/api/v2/push", "POST /devices"])
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func theSwitchIsRememberedAcrossLaunches() async throws {
        defer { sandbox.remove() }
        let (app, _, defaults) = try makeApp()
        await app.setPushEnabled(false)
        let relaunched = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        #expect(!relaunched.pushEnabled)
        await app.session?.shutdown(closeDatabase: true)
        await relaunched.session?.shutdown(closeDatabase: true)
    }
}
