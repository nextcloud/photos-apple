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

@Suite(.timeLimit(.minutes(1))) struct SmartOfflineManagerTests {
    let sandbox = Sandbox()
    let server = StubServer()
    /// The settings the manager reads, changed by the tests.
    let setting = Setting()

    final class Setting: Sendable {
        let value = Mutex((budget: SmartOfflineBudget.small, quality: SmartOfflineQuality.screen))
        func withLock<T>(_ body: (inout (budget: SmartOfflineBudget, quality: SmartOfflineQuality)) -> T) -> T {
            value.withLock { body(&$0) }
        }
    }

    func makeServices() throws -> AccountServices {
        let account = makeAccount("alice", server: server.url.absoluteString)
        return try AccountServices(
            account: account, appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    func makeManager(_ services: AccountServices) async -> SmartOfflineManager {
        let manager = SmartOfflineManager(services: services, settings: { [setting] in setting.withLock { $0 } })
        await manager.setConditions(network: NetworkConditions(), lowPower: false)
        return manager
    }

    /// Recent photos with previews on the server; the newest has the highest id.
    func seed(_ services: AccountServices, count: Int, previewBytes: Int = 1000) throws {
        let now = Date()
        let items = (1...count).map { index in
            MediaItem(
                fileId: FileID(index), path: "/Photos/p\(index).jpg", mimeType: "image/jpeg", size: 5000, etag: "e\(index)",
                modifiedAt: now.addingTimeInterval(-Double(count - index) * 3600),
                capturedAt: now.addingTimeInterval(-Double(count - index) * 3600))
        }
        try services.library.upsert(items)
        server.set { state in
            for index in 1...count {
                state.downloads["/index.php/apps/photos/api/v1/preview/\(index)"] = Data(repeating: UInt8(index % 255), count: previewBytes)
                state.downloads["/remote.php/dav/files/alice/Photos/p\(index).jpg"] = Data(repeating: 7, count: 5000)
            }
        }
    }

    @Test func aPassKeepsPreviewsOfTheBestPhotosAndThePipelineCanFindThem() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 5)
        let manager = await makeManager(services)

        let outcome = await manager.run(limit: nil)

        #expect(outcome.downloaded == 5)
        #expect(outcome.remaining == 0)
        #expect(manager.keptCount == 5)
        let file = try #require(manager.localPreview(fileId: 5, etag: "e5", bucket: 1024))
        #expect(try Data(contentsOf: file).count == 1000)
        // Not for a larger preview, another version of the file, or as an original.
        #expect(manager.localPreview(fileId: 5, etag: "e5", bucket: 4096) == nil)
        #expect(manager.localPreview(fileId: 5, etag: "old", bucket: 256) == nil)
        #expect(manager.localOriginal(fileId: 5, etag: "e5") == nil)
        // Only previews were asked for, at the screen size.
        #expect(server.requests.allSatisfy { !$0.path.hasPrefix("/remote.php/dav/files") })
        let summary = await manager.summary()
        #expect(summary.count == 5)
        #expect(summary.bytes == 5000)
    }

    @Test func nothingIsDownloadedOnCellularOrInLowPowerModeButRemovingGoesOn() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 3)
        let manager = await makeManager(services)
        await manager.setConditions(network: NetworkConditions(isExpensive: true), lowPower: false)
        var outcome = await manager.run(limit: nil)
        #expect(outcome.downloaded == 0)
        #expect(outcome.remaining == 3)
        await manager.setConditions(network: NetworkConditions(), lowPower: true)
        outcome = await manager.run(limit: nil)
        #expect(outcome.downloaded == 0)

        await manager.setConditions(network: NetworkConditions(), lowPower: false)
        outcome = await manager.run(limit: nil)
        #expect(outcome.downloaded == 3)
        // Off: everything goes, without network.
        await manager.setConditions(network: NetworkConditions(isConnected: false), lowPower: true)
        setting.withLock { $0.budget = .off }
        outcome = await manager.run(limit: nil)
        #expect(outcome.evicted == 3)
        #expect(manager.keptCount == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: manager.directory.path(percentEncoded: false)))?.isEmpty == true)
    }

    @Test func theForegroundLimitAndArchivedPhotos() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 4)
        let manager = await makeManager(services)
        var outcome = await manager.run(limit: 2)
        #expect(outcome.downloaded == 2)
        #expect(outcome.remaining == 2)
        // The newest come first.
        #expect(manager.isKept(4) && manager.isKept(3))
        // An archived photo's file goes in the next pass.
        try await services.database.writer.write { db in try db.execute(sql: "UPDATE media SET isArchived = 1 WHERE fileId = 4") }
        outcome = await manager.run(limit: nil)
        #expect(outcome.evicted == 1)
        #expect(!manager.isKept(4))
        #expect(manager.isKept(1) && manager.isKept(2) && manager.isKept(3))
    }

    @Test func originalsAreKeptWhenChosenAndServedAsOriginals() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        try seed(services, count: 2)
        setting.withLock { $0.quality = .original }
        let manager = await makeManager(services)
        let outcome = await manager.run(limit: nil)
        #expect(outcome.downloaded == 2)
        let original = try #require(manager.localOriginal(fileId: 2, etag: "e2"))
        #expect(original.pathExtension == "jpg")
        #expect(manager.localPreview(fileId: 2, etag: "e2", bucket: 256) == nil)
        // Back to previews: the originals are replaced.
        setting.withLock { $0.quality = .screen }
        let again = await manager.run(limit: nil)
        #expect(again.evicted == 2)
        #expect(again.downloaded == 2)
        #expect(manager.localPreview(fileId: 2, etag: "e2", bucket: 256) != nil)
    }
}

@Suite struct PhotoOfTheDayNotificationTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute))!
    }

    @Test func lockedNotificationsSayNothingAboutThePhoto() {
        let choice = DailyPhotoChoice(fileId: 1, reason: .yearsAgo(3), takenAt: date(2023, 11, 24), place: "Lisbon")
        let open = PhotoOfTheDayNotifications.text(for: choice, locked: false)
        #expect(open.body.contains("Lisbon"))
        #expect(open.body.contains("3"))
        let locked = PhotoOfTheDayNotifications.text(for: choice, locked: true)
        #expect(!locked.body.contains("Lisbon"))
        #expect(!locked.body.contains("3"))
        #expect(locked.title == open.title)
    }

    @Test func fireDatesStartTodayWhenTheTimeIsStillToCome() {
        let morning = date(2026, 11, 24, 8)
        let dates = PhotoOfTheDayNotifications.fireDates(now: morning, minutes: 9 * 60 + 30, days: 3, calendar: calendar)
        #expect(dates == [date(2026, 11, 24, 9, 30), date(2026, 11, 25, 9, 30), date(2026, 11, 26, 9, 30)])
        let evening = date(2026, 11, 24, 20)
        let later = PhotoOfTheDayNotifications.fireDates(now: evening, minutes: 9 * 60 + 30, days: 3, calendar: calendar)
        #expect(later.first == date(2026, 11, 25, 9, 30))
        #expect(later.count == 3)
    }

    @Test func historyCountsOnlyEarlierDaysWithinTheWindow() {
        let history: [String: Int64] = ["2026-11-20": 1, "2026-11-24": 2, "2026-11-25": 3, "2026-08-01": 4]
        let shown = PhotoOfTheDayNotifications.recentlyShown(history, before: date(2026, 11, 24), calendar: calendar)
        #expect(shown == [1])
        let pruned = PhotoOfTheDayNotifications.pruned(history, now: date(2026, 11, 24), calendar: calendar)
        #expect(pruned.keys.sorted() == ["2026-11-20", "2026-11-24", "2026-11-25"])
        #expect(PhotoOfTheDayNotifications.dayKey(date(2026, 1, 5), calendar: calendar) == "2026-01-05")
    }

    @Test func settingsDefaultToOffAtNine() {
        let defaults = UserDefaults(suiteName: "photo-of-the-day-\(UUID().uuidString)")!
        #expect(!PhotoOfTheDaySettings.isEnabled(defaults))
        #expect(PhotoOfTheDaySettings.time(defaults) == 9 * 60)
        defaults.set(25 * 60, forKey: PhotoOfTheDaySettings.timeKey)
        #expect(PhotoOfTheDaySettings.time(defaults) == 24 * 60 - 1)
    }
}

@MainActor @Suite struct StickerBookTests {
    @Test func stickersAreAddedNewestFirstAndSurviveAReload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stickers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = StickerBook(directory: directory)
        let first = try book.add(png: Data([1]), width: 10, height: 10, source: 4, pack: nil, style: "outline")
        let second = try book.add(png: Data([2]), width: 10, height: 10, source: 5, pack: "Ada", style: "outline")
        #expect(book.stickers.map(\.id) == [second.id, first.id])
        #expect(book.packs == ["Ada"])

        let reloaded = StickerBook(directory: directory)
        reloaded.load()
        #expect(reloaded.stickers.map(\.id) == [second.id, first.id])
        reloaded.remove([first.id])
        #expect(!FileManager.default.fileExists(atPath: reloaded.url(of: first).path(percentEncoded: false)))
        let again = StickerBook(directory: directory)
        again.load()
        #expect(again.stickers.map(\.id) == [second.id])
    }
}
