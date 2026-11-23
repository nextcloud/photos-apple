// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Testing

@testable import PhotosBackup
@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

@Suite struct OfflineManagerTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeServices() throws -> AccountServices {
        let account = makeAccount("alice", server: server.url.absoluteString)
        return try AccountServices(
            account: account, appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    /// One pinned album with one photo that is not downloaded yet.
    func pinAlbum(in services: AccountServices) throws -> (Album, MediaItem) {
        let album = Album(kind: .own, name: "Holiday")
        let item = MediaItem(fileId: 11, path: "/Photos/beach.jpg", mimeType: "image/jpeg", etag: "abc")
        try services.collections.upsertAlbum(album)
        try services.library.upsert([item])
        try services.database.writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO albumItem(albumId, fileId, childName, origin, ownerPath, position) VALUES (?, 11, '11-beach.jpg', 'user', ?, 1)",
                arguments: [album.id, item.path])
            try db.execute(
                sql: "INSERT INTO offlinePin(id, title, createdAt) VALUES (?, 'Holiday', 0)",
                arguments: [OfflineManager.pinId(album: album)])
        }
        server.set { $0.downloads["/remote.php/dav/files/alice/Photos/beach.jpg"] = Data("original".utf8) }
        return (album, item)
    }

    func storedPaths(_ services: AccountServices) throws -> [String] {
        try services.database.writer.read { db in try String.fetchAll(db, sql: "SELECT localPath FROM offlineFile ORDER BY fileId") }
    }

    @Test func wifiOnlyRule() {
        let wifi = NetworkConditions()
        let cellular = NetworkConditions(isExpensive: true)
        let lowData = NetworkConditions(isConstrained: true)
        let offline = NetworkConditions(isConnected: false)
        #expect(OfflineManager.downloadsAllowed(wifiOnly: true, network: wifi))
        #expect(!OfflineManager.downloadsAllowed(wifiOnly: true, network: cellular))
        #expect(!OfflineManager.downloadsAllowed(wifiOnly: true, network: lowData))
        #expect(OfflineManager.downloadsAllowed(wifiOnly: false, network: cellular))
        #expect(OfflineManager.downloadsAllowed(wifiOnly: false, network: lowData))
        #expect(!OfflineManager.downloadsAllowed(wifiOnly: false, network: offline))
        #expect(!OfflineManager.downloadsAllowed(wifiOnly: true, network: offline))
    }

    @Test func nothingIsDownloadedOnCellularUntilWifiOrTheSettingAllowsIt() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (_, item) = try pinAlbum(in: services)
        let offline = OfflineManager(services: services, wifiOnly: { true })
        await offline.setNetwork(NetworkConditions(isExpensive: true))

        await offline.syncPins()

        #expect(await offline.isWaitingForWiFi)
        #expect(server.requests.filter { $0.path.hasSuffix("beach.jpg") }.isEmpty)
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) == nil)

        await offline.setNetwork(NetworkConditions())
        await offline.syncPins()

        #expect(await !offline.isWaitingForWiFi)
        let file = try #require(offline.localFile(fileId: item.fileId, etag: item.etag))
        #expect(try Data(contentsOf: file) == Data("original".utf8))
        // The database knows the file by its name, not by where the container happens to be.
        #expect(try storedPaths(services) == ["11-abc.jpg"])
        #expect(file.deletingLastPathComponent().lastPathComponent == "Offline")
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    @Test func cellularDownloadWhenTheSettingIsOff() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (_, item) = try pinAlbum(in: services)
        let offline = OfflineManager(services: services, wifiOnly: { false })
        await offline.setNetwork(NetworkConditions(isExpensive: true))
        await offline.syncPins()
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) != nil)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    @Test func offlineFolderIsExcludedFromDeviceBackups() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let offline = OfflineManager(services: services, wifiOnly: { true })
        let directory = sandbox.layout.offline(services.account.id)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Also after "Remove all offline files" recreated the folder.
        try await offline.removeAll()
        let recreated = URL(fileURLWithPath: directory.path(percentEncoded: false))
        #expect(try recreated.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    /// Rows written by earlier versions hold the absolute path of a container that may have moved since.
    @Test func absolutePathsOfEarlierVersionsAreMigratedAndStillResolve() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let directory = sandbox.layout.offline(services.account.id)
        try sandbox.write("original", to: directory.appending(path: "11-abc.jpg"))
        let oldContainer = "/private/var/mobile/Containers/Shared/AppGroup/OLD-UUID/Library/Application Support/Accounts/x/Offline"
        try await services.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO offlineFile(fileId, etag, localPath, bytes, downloadedAt) VALUES (11, 'abc', ?, 8, 0)",
                arguments: ["\(oldContainer)/11-abc.jpg"])
        }
        // Before the migration the stored path already resolves into the current folder …
        #expect(OfflineManager.storedPath(for: "\(oldContainer)/11-abc.jpg") == "11-abc.jpg")

        let offline = OfflineManager(services: services, wifiOnly: { true })

        // … and creating the manager rewrites the row.
        #expect(try storedPaths(services) == ["11-abc.jpg"])
        let file = try #require(offline.localFile(fileId: 11, etag: "abc"))
        #expect(try Data(contentsOf: file) == Data("original".utf8))
        #expect(offline.localFile(fileId: 11, etag: "changed") == nil)
        await offline.shutdown()
        await services.shutdown(closeDatabase: true)
    }

    @Test func shutDownManagerDownloadsNothing() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let (_, item) = try pinAlbum(in: services)
        let offline = OfflineManager(services: services, wifiOnly: { false })
        await offline.setNetwork(NetworkConditions())
        await offline.shutdown()
        await offline.syncPins()
        #expect(offline.localFile(fileId: item.fileId, etag: item.etag) == nil)
        await services.shutdown(closeDatabase: true)
    }
}

@Suite struct BackupOutcomeTests {
    func status(_ phase: BackupStatus.Phase, uploaded: Int = 0, thisPass: Int = 0, pending: Int = 0, failed: Int = 0) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.uploaded = uploaded
        status.uploadedThisPass = thisPass
        status.pending = pending
        status.failed = failed
        return status
    }

    /// The messages come from PhotosCore's string catalog, with its plural forms.
    @Test func messagesUseTheCatalogsPluralForms() {
        #expect(
            BackupOutcome.finished(uploaded: 2, remaining: 0, failed: 1).message == "Backup finished, but 1 item could not be uploaded.")
        #expect(
            BackupOutcome.finished(uploaded: 2, remaining: 0, failed: 3).message == "Backup finished, but 3 items could not be uploaded.")
        #expect(BackupOutcome.finished(uploaded: 1, remaining: 1, failed: 0).message == "1 item was backed up, 1 is still waiting.")
        #expect(BackupOutcome.finished(uploaded: 5, remaining: 2, failed: 0).message == "5 items were backed up, 2 are still waiting.")
    }

    @Test func outcomeFollowsTheFinalStatus() {
        #expect(BackupOutcome(status: status(.upToDate)) == .upToDate)
        #expect(BackupOutcome(status: status(.paused("Waiting for Wi-Fi"))) == .paused("Waiting for Wi-Fi"))
        #expect(BackupOutcome(status: status(.failed("Server error"))) == .failed("Server error"))
        #expect(BackupOutcome(status: status(.notAuthorized)) == .notAuthorized)
        var full = status(.failed("Insufficient storage"))
        full.blocker = .insufficientStorage
        #expect(BackupOutcome(status: full) == .blocked(.insufficientStorage))
        #expect(BackupOutcome.blocked(.insufficientStorage).message.contains("storage is full"))
        #expect(BackupOutcome.blocked(.unauthorized).message.contains("log in"))
        #expect(!BackupOutcome.blocked(.forbidden).isComplete)
        // The count is what the pass uploaded, not everything the ledger knows (also in the first pass after a launch).
        #expect(
            BackupOutcome(status: status(.idle, uploaded: 1200, thisPass: 2, pending: 3, failed: 1))
                == .finished(uploaded: 2, remaining: 3, failed: 1))
    }

    /// Review r2 item 1: a pass after which items are still failed is not "your photos are backed up".
    @Test func failedItemsAreNeverReportedAsBackedUp() {
        let outcome = BackupOutcome(status: status(.incomplete(failed: 2), uploaded: 40, thisPass: 3, failed: 2))
        #expect(outcome == .finished(uploaded: 3, remaining: 0, failed: 2))
        #expect(!outcome.isComplete)
        #expect(outcome.message == "Backup finished, but 2 items could not be uploaded.")
        #expect(outcome.message != BackupOutcome.upToDate.message)
    }

    /// Item 7: originals that are only in iCloud while downloads are off.
    @Test func skippedItemsAreNamed() {
        var skipped = status(.upToDate)
        skipped.skipped = 4
        let outcome = BackupOutcome(status: skipped)
        #expect(outcome == .skipped(4))
        #expect(!outcome.isComplete)
        #expect(outcome.message.contains("4 items that are only in iCloud"))
        #expect(BackupOutcome.skipped(1).message.contains("1 item that is only in iCloud was not backed up"))
    }

    /// Item 7: a full device is named as what it is.
    @Test func aFullDeviceIsABlocker() {
        var full = status(.failed("no space"))
        full.blocker = .deviceStorageFull
        let outcome = BackupOutcome(status: full)
        #expect(outcome == .blocked(.deviceStorageFull))
        #expect(outcome.message.contains("free up space on this"))
        #expect(!outcome.message.contains("Nextcloud storage"))
    }

    /// Item 10: with access to selected photos only, the answer says so.
    @Test func limitedAccessIsPartOfTheAnswer() {
        let note = "Only the photos you selected for Nextcloud Photos are backed up."
        #expect(BackupOutcome.upToDate.message(limitedAccess: false) == BackupOutcome.upToDate.message)
        #expect(BackupOutcome.upToDate.message(limitedAccess: true) == "Your photos are backed up. " + note)
        #expect(BackupOutcome.paused("Waiting for Wi-Fi").message(limitedAccess: true).hasSuffix(note))
        // Without any access, or without a backup, there is nothing to add.
        #expect(BackupOutcome.notAuthorized.message(limitedAccess: true) == BackupOutcome.notAuthorized.message)
        #expect(BackupOutcome.unavailable("x").message(limitedAccess: true) == "x")
    }

    @Test func aPassTheSystemInterruptedIsNeitherFinishedNorPaused() {
        var interrupted = status(.idle, uploaded: 40, thisPass: 4, pending: 9)
        interrupted.isInterrupted = true
        let outcome = BackupOutcome(status: interrupted)
        #expect(outcome == .interrupted(uploaded: 4))
        #expect(!outcome.isComplete)
        #expect(outcome.message.contains("interrupted"))
    }

    @Test func onlyACompletePassCountsAsDone() {
        #expect(BackupOutcome.upToDate.isComplete)
        #expect(BackupOutcome.finished(uploaded: 5, remaining: 0, failed: 0).isComplete)
        #expect(!BackupOutcome.finished(uploaded: 5, remaining: 2, failed: 0).isComplete)
        #expect(!BackupOutcome.finished(uploaded: 5, remaining: 0, failed: 1).isComplete)
        #expect(!BackupOutcome.paused("Waiting for Wi-Fi").isComplete)
        #expect(!BackupOutcome.failed("x").isComplete)
        #expect(!BackupOutcome.notAuthorized.isComplete)
        #expect(!BackupOutcome.unavailable("x").isComplete)
    }

    @Test func messagesSayWhatHappened() {
        #expect(BackupOutcome.paused("Waiting for Wi-Fi").message.contains("Waiting for Wi-Fi"))
        #expect(BackupOutcome.failed("Server error").message.contains("Server error"))
        #expect(BackupOutcome.finished(uploaded: 0, remaining: 0, failed: 0).message == "Backup finished.")
        #expect(BackupOutcome.paused("x").message != "Backup finished.")
        #expect(BackupOutcome.unavailable("Backup is not turned on in Nextcloud Photos.").message.contains("not turned on"))
    }
}
