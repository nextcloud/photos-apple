// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

@Suite struct CacheImportanceTests {
    let now = day(2026, 11, 24)

    func score(_ signals: CacheImportance.Signals) -> (score: Double, reason: CacheImportance.Reason)? {
        CacheImportance.score(signals, now: now, calendar: utcCalendar)
    }

    @Test func theOldReasonsScoreAsSmartOfflineDidBefore() throws {
        let recent = try #require(score(.init(timestamp: now)))
        #expect(recent.reason == .recent && abs(recent.score - 0.9) < 0.001)
        let twoMonths = try #require(score(.init(timestamp: now.addingTimeInterval(-60 * 86_400))))
        #expect(abs(twoMonths.score - 0.45) < 0.001)
        #expect(score(.init(timestamp: day(2024, 1, 1))) == nil)
        let memory = try #require(score(.init(timestamp: day(2019, 11, 26))))
        #expect(memory.reason == .onThisDay && abs(memory.score - 0.98) < 0.001)
        let favorite = try #require(score(.init(timestamp: day(2018, 3, 1), isFavorite: true)))
        #expect(favorite.reason == .favorite && favorite.score >= 0.35 && favorite.score < 0.4)
        let album = try #require(score(.init(timestamp: day(2016, 5, 5), albumViewedAt: now.addingTimeInterval(-7 * 86_400))))
        #expect(album.reason == .album && abs(album.score - 0.3) < 0.001)
        #expect(score(.init(timestamp: day(2016, 5, 5), albumViewedAt: now.addingTimeInterval(-31 * 86_400))) == nil)
    }

    @Test func recentlyViewedRanksByRecencyAndRepeats() throws {
        let old = day(2015, 6, 1)
        let today = try #require(score(.init(timestamp: old, viewedAt: now, viewCount: 1)))
        #expect(today.reason == .viewed && abs(today.score - 0.7) < 0.001)
        let often = try #require(score(.init(timestamp: old, viewedAt: now, viewCount: 9)))
        #expect(abs(often.score - 0.8) < 0.001)  // the repeats add at most 0.1
        let twoWeeks = try #require(score(.init(timestamp: old, viewedAt: now.addingTimeInterval(-14 * 86_400), viewCount: 1)))
        #expect(abs(twoWeeks.score - 0.35) < 0.001)
        #expect(score(.init(timestamp: old, viewedAt: now.addingTimeInterval(-91 * 86_400), viewCount: 3)) == nil)
        // Looked at yesterday beats an old favourite and a photo of four months ago.
        let yesterday = try #require(score(.init(timestamp: old, viewedAt: now.addingTimeInterval(-86_400), viewCount: 1)))
        #expect(yesterday.score > score(.init(timestamp: old, isFavorite: true))!.score)
        #expect(yesterday.score > score(.init(timestamp: now.addingTimeInterval(-120 * 86_400)))!.score)
    }

    @Test func rolesRankInTheirOrder() throws {
        let old = day(2015, 6, 1)
        let order: [(CacheImportance.Roles, CacheImportance.Reason)] = [
            (.memoryCover, .memoryCover), (.keyPhoto, .keyPhoto), (.cover, .cover), (.face, .face),
        ]
        let scores = try order.map { role, reason in
            let result = try #require(score(.init(timestamp: old, roles: role)))
            #expect(result.reason == reason)
            return result.score
        }
        #expect(scores == scores.sorted(by: >))
        // A photo with several roles takes the best; a cover without a known date still counts.
        #expect(score(.init(timestamp: old, roles: [.face, .memoryCover]))?.reason == .memoryCover)
        #expect(score(.init(roles: .cover))?.reason == .cover)
        // The memory of the coming days still comes first.
        #expect(score(.init(timestamp: day(2019, 11, 24), roles: .memoryCover))?.reason == .onThisDay)
    }

    @Test func tiersAreQuartersOfTheScore() {
        #expect(CacheImportance.tier(0) == 0)
        #expect(CacheImportance.tier(0.01) == 1)
        #expect(CacheImportance.tier(0.25) == 1)
        #expect(CacheImportance.tier(0.26) == 2)
        #expect(CacheImportance.tier(0.5) == 2)
        #expect(CacheImportance.tier(0.7) == 3)
        #expect(CacheImportance.tier(1) == 4)
    }

    @Test func smartOfflineScoresWithTheSameScorer() throws {
        let candidate = SmartOfflineCandidate(
            fileId: 1, etag: "e", timestamp: day(2015, 6, 1), viewedAt: now, viewCount: 2, roles: .cover)
        let ranked = SmartOfflinePolicy.rank([candidate], now: now, calendar: utcCalendar)
        #expect(ranked.first?.reason == .viewed)
        #expect(ranked.first?.score == CacheImportance.score(candidate.signals, now: now, calendar: utcCalendar)?.score)
        // The reasons smart offline stored before keep their raw values.
        #expect(SmartOfflineReason(rawValue: "onThisDay") == .onThisDay)
        #expect(SmartOfflineReason(rawValue: "album") == .album)
    }
}

@Suite struct CacheEvictionTests {
    let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func file(_ size: Int64, age: Double, pool: CachePool = .thumbnails, tier: UInt8 = 0, kept: Bool = false, exempt: Bool = false)
        -> CacheEviction.File
    {
        CacheEviction.File(
            size: size, lastUsed: reference.addingTimeInterval(-age), pool: pool, tier: tier, isKept: kept, isExempt: exempt)
    }

    @Test func poolsShareTheLimit() {
        let budgets = CachePoolBudgets(total: 2 * 1024 * 1024 * 1024)
        #expect(budgets.large == CachePoolBudgets.largeCap)
        #expect(budgets.thumbnails + budgets.screen + budgets.large == budgets.total)
        #expect(abs(budgets.thumbnails - budgets.screen) <= 1)
        let small = CachePoolBudgets(total: 1000)
        #expect(small.large == 150)
        #expect(CachePool(bucket: 64) == .thumbnails)
        #expect(CachePool(bucket: 256) == .thumbnails)
        #expect(CachePool(bucket: 1024) == .screen)
        #expect(CachePool(bucket: 2048) == .screen)
        #expect(CachePool(bucket: 4096) == .large)
        #expect(CachePool(bucket: 0) == .screen)
    }

    @Test func belowTheLimitNothingGoes() {
        let plan = CacheEviction.plan([file(100, age: 10), file(100, age: 20, pool: .screen)], budgets: CachePoolBudgets(total: 1000))
        #expect(plan.removals.isEmpty)
        #expect(plan.remaining == 200)
    }

    /// The bug of a single LRU: zooming into a few photos (4096 px, large and newest) pushed out hundreds of thumbnails.
    @Test func largePreviewsCannotPushOutThumbnails() {
        var files: [CacheEviction.File] = (0..<8).map { file(100, age: 1000 + Double($0)) }  // 800 bytes of older thumbnails
        files += (0..<4).map { file(300, age: Double($0), pool: .large) }  // 1200 bytes of new zoomed-in previews
        let plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: 2000))
        // The large pool has 300 bytes (15 %); everything above goes, newest last. Not one thumbnail goes.
        #expect(Set(plan.removals) == [9, 10, 11])
        #expect(plan.remaining == 1100)
    }

    @Test func thePoolFurthestOverItsShareGivesBack() {
        // Limit 1000: thumbnails and screen 425 each, large 150.
        var files: [CacheEviction.File] = (0..<4).map { file(100, age: Double(100 + $0)) }  // 400 thumbnails, older
        files += (0..<8).map { file(100, age: Double($0), pool: .screen) }  // 800 screen, newer
        let plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: 1000))
        #expect(plan.remaining == 1000)
        // The screen pool was over its share; the older thumbnails stay.
        #expect(plan.removals.allSatisfy { $0 >= 4 })
        // Its oldest went first.
        #expect(plan.removals == [11, 10])
    }

    @Test func aPoolMayUseRoomTheOtherLeavesFree() {
        let files: [CacheEviction.File] = (0..<9).map { file(100, age: Double($0), pool: .screen) }
        let plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: 1000))
        #expect(plan.removals.isEmpty)
    }

    @Test func leastImportantFirstThenLeastRecentlyUsed() {
        let files = [
            file(100, age: 10, tier: 4),  // 0: important, used long ago
            file(100, age: 1, tier: 0),  // 1: unimportant, just used
            file(100, age: 5, tier: 0),  // 2: unimportant, used before 1
            file(100, age: 50, tier: 2),  // 3
            file(100, age: 2, tier: 2),  // 4
        ]
        let plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: 200))
        #expect(plan.removals == [2, 1, 3])
    }

    @Test func keptFilesCountButStayAndExemptOnesDoNotCount() {
        let files = [
            file(500, age: 100, kept: true),
            file(5000, age: 200, exempt: true),
            file(100, age: 1),
            file(100, age: 2),
        ]
        let plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: 550))
        #expect(plan.removals == [3, 2])
        #expect(plan.remaining == 500)
        // A limit of zero still keeps both.
        #expect(CacheEviction.plan(files, budgets: CachePoolBudgets(total: 0)).removals == [3, 2])
    }

    @Test func aHundredThousandFilesArePlannedQuickly() {
        var files: [CacheEviction.File] = []
        files.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let pool: CachePool = index % 10 == 0 ? .large : (index % 3 == 0 ? .screen : .thumbnails)
            files.append(file(Int64(20_000 + index % 7 * 1000), age: Double(index * 37 % 100_000), pool: pool, tier: UInt8(index % 5)))
        }
        let total = files.reduce(0) { $0 + $1.size }
        let clock = ContinuousClock()
        var plan = CacheEviction.Plan(removals: [], remaining: 0)
        let elapsed = clock.measure { plan = CacheEviction.plan(files, budgets: CachePoolBudgets(total: total / 2)) }
        #expect(plan.remaining <= total / 2)
        // Debug build on a CI Mac: well under a second (release: a few tens of milliseconds).
        #expect(elapsed < .seconds(2))
        // Within a pool the order holds: no removed file is more important than a kept one of the same pool... unless all of
        // its tier went.
        let removed = Set(plan.removals)
        for pool in CachePool.allCases {
            let maxRemovedTier = plan.removals.filter { files[$0].pool == pool }.map { files[$0].tier }.max() ?? 0
            let keptBelow = files.indices.filter { !removed.contains($0) && files[$0].pool == pool && files[$0].tier < maxRemovedTier }
            #expect(keptBelow.isEmpty)
        }
    }
}

@Suite struct MemoryPressurePolicyTests {
    typealias Entry = MemoryPressurePolicy.Entry

    let entries: [Entry] = [
        Entry(fileId: 1, decodedSize: 4096, cost: 64_000_000),  // the viewer's photo, zoomed in
        Entry(fileId: 1, decodedSize: 1024, cost: 4_000_000),
        Entry(fileId: 2, decodedSize: 1024, cost: 4_000_000),  // its neighbour
        Entry(fileId: 2, decodedSize: 256, cost: 250_000),
        Entry(fileId: 3, decodedSize: 1024, cost: 4_000_000),  // some other photo seen before
        Entry(fileId: 4, decodedSize: 400, cost: 640_000),  // tiles on screen
        Entry(fileId: 5, decodedSize: 400, cost: 640_000),
        Entry(fileId: 6, decodedSize: 400, cost: 640_000),  // a tile further back
        Entry(fileId: 7, decodedSize: 256, cost: 250_000),  // a cover, long ago
        Entry(fileId: 8, decodedSize: 2048, cost: 16_000_000),  // a protected photo, but a large decode
    ]
    let focus = MemoryPressurePolicy.Focus(current: 1, neighbours: [2])

    func kept(_ level: MemoryPressurePolicy.Level, limit: Int) -> [Int] {
        MemoryPressurePolicy.survivors(entries, level: level, limit: limit, protected: [7, 8], focus: focus)
            .enumerated().filter(\.element).map(\.offset)
    }

    @Test func aWarningKeepsWhatIsOnScreen() {
        // Tile budget a quarter of 6 MB: two of the three recent tiles.
        #expect(kept(.warning, limit: 6_000_000) == [0, 1, 2, 3, 5, 6, 8])
    }

    @Test func aCriticalWarningKeepsLess() {
        // Tile budget a tenth of 7 MB: one tile; the zoomed-in decode and the neighbour's 1024 go.
        #expect(kept(.critical, limit: 7_000_000) == [1, 3, 5, 8])
    }

    @Test func withoutAViewerOnlyTilesStay() {
        let survivors = MemoryPressurePolicy.survivors(entries, level: .warning, limit: 100_000_000, protected: [], focus: .init())
        #expect(survivors.enumerated().filter(\.element).map(\.offset) == [3, 5, 6, 7, 8])
    }
}
