// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// Round 3, items 33 and 35: when backup is offered after the login, when a user-started backup runs as a continued
/// processing task with which progress, and when the screen stays on.
@Suite struct BackupOnboardingTests {
    @Test func backupIsOfferedOnceWhileItIsNotSetUp() {
        #expect(BackupOffer.shouldOffer(isAvailable: true, isSetUp: false, alreadyOffered: false))
        #expect(!BackupOffer.shouldOffer(isAvailable: true, isSetUp: true, alreadyOffered: false))
        #expect(!BackupOffer.shouldOffer(isAvailable: true, isSetUp: false, alreadyOffered: true))
        #expect(!BackupOffer.shouldOffer(isAvailable: false, isSetUp: false, alreadyOffered: false))
    }

    @MainActor @Test func theMacDoesNotOfferBackupAfterTheLogin() throws {
        let defaults = try #require(UserDefaults(suiteName: "BackupOnboardingTests-\(UUID().uuidString)"))
        let model = BackupModel(settingsFile: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
        #if os(macOS)
            #expect(!BackupOffer.shouldOffer(backup: model, defaults: defaults))
        #else
            #expect(BackupOffer.shouldOffer(backup: model, defaults: defaults) == model.isAvailable)
            defaults.set(true, forKey: BackupOffer.offeredKey)
            #expect(!BackupOffer.shouldOffer(backup: model, defaults: defaults))
        #endif
    }

    @Test func firstAndLargeBackupsUseTheContinuedTask() {
        #expect(ContinuedBackupPolicy.shouldUse(isFirstPass: true, waiting: 0))
        #expect(ContinuedBackupPolicy.shouldUse(isFirstPass: false, waiting: ContinuedBackupPolicy.minimumWaiting))
        #expect(!ContinuedBackupPolicy.shouldUse(isFirstPass: false, waiting: ContinuedBackupPolicy.minimumWaiting - 1))
    }

    @Test func progressOnlyGrowsThroughThePhasesOfAPass() throws {
        let phases: [BackupStatus.Phase] = [
            .scanning, .reconciling(checked: 0, total: 400), .reconciling(checked: 200, total: 400), .reconciling(checked: 400, total: 400),
            .uploading(done: 0, total: 10, current: ""), .uploading(done: 5, total: 10, current: ""),
            .uploading(done: 10, total: 10, current: ""), .upToDate,
        ]
        let fractions = try phases.map { try #require(ContinuedBackupPolicy.fraction($0)) }
        #expect(fractions == fractions.sorted())
        #expect(fractions.first! > 0)
        #expect(fractions.last == 1)
        #expect(fractions.allSatisfy { $0 <= 1 })
        // An empty check does not divide by zero.
        #expect(ContinuedBackupPolicy.fraction(.reconciling(checked: 0, total: 0)) == 0.02)
        #expect(ContinuedBackupPolicy.fraction(.paused("Waiting for Wi-Fi")) == nil)
        #expect(ContinuedBackupPolicy.subtitle(.uploading(done: 9, total: 10, current: "")) == "Uploading 10 of 10")
    }

    @Test func theScreenStaysOnOnlyWhileABackupRunsInFront() {
        #expect(ScreenAwakePolicy.keepsAwake(option: true, isRunning: true, isActive: true))
        #expect(!ScreenAwakePolicy.keepsAwake(option: false, isRunning: true, isActive: true))
        #expect(!ScreenAwakePolicy.keepsAwake(option: true, isRunning: false, isActive: true))
        #expect(!ScreenAwakePolicy.keepsAwake(option: true, isRunning: true, isActive: false))
    }

    /// The listing the server check before removing device photos relies on (round-3 item 36).
    @Test func theServerListingGivesSizesAndIdsOfAFoldersFiles() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let server = StubServer()
        let services = try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
        func file(_ name: String, size: String, id: Int) -> String {
            "<d:response><d:href>/remote.php/dav/files/alice/Photos/2024/\(name)</d:href><d:propstat><d:prop><oc:fileid>\(id)</oc:fileid>\(size)<d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }
        let body = multistatus(
            "<d:response><d:href>/remote.php/dav/files/alice/Photos/2024/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                + "<d:response><d:href>/remote.php/dav/files/alice/Photos/2024/05/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                + file("IMG_1.HEIC", size: "<d:getcontentlength>1234</d:getcontentlength>", id: 7)
                + file("IMG%202.jpg", size: "<oc:size>99</oc:size>", id: 8))
        server.set { $0.responses["PROPFIND /remote.php/dav/files/alice/Photos/2024/"] = StubServer.Stub(status: 207, body: body) }
        let listing = DAVServerFileListing(api: services.api)
        let files = try await listing.files(in: "/Photos/2024")
        #expect(
            files == [
                "/Photos/2024/IMG_1.HEIC": ServerFileInfo(fileId: 7, size: 1234),
                "/Photos/2024/IMG 2.jpg": ServerFileInfo(fileId: 8, size: 99),
            ])
        // A folder that is gone has no files.
        #expect(try await listing.files(in: "/Photos/1999").isEmpty)
    }
}
