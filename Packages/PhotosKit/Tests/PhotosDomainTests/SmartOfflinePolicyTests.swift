// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

@Suite struct SmartOfflinePolicyTests {
    let now = day(2026, 11, 24)

    func candidate(_ id: FileID, _ date: Date, favorite: Bool = false, size: Int64 = 0, kind: MediaKind = .image, album: Date? = nil)
        -> SmartOfflineCandidate
    {
        SmartOfflineCandidate(
            fileId: id, etag: "e\(id)", timestamp: date, isFavorite: favorite, kind: kind, size: size, albumViewedAt: album)
    }

    func kept(_ id: FileID, bytes: Int64 = 100, used: Date, etag: String? = nil, quality: SmartOfflineQuality = .screen)
        -> SmartOfflineKept
    {
        SmartOfflineKept(fileId: id, etag: etag ?? "e\(id)", bytes: bytes, lastUsed: used, quality: quality)
    }

    @Test func budgetsGrow() {
        let sizes = SmartOfflineBudget.allCases.map(\.bytes)
        #expect(sizes == sizes.sorted())
        #expect(SmartOfflineBudget.off.bytes == 0)
        #expect(SmartOfflineBudget.default == .small)
    }

    @Test func onThisDayIsCountedOnlyForTheComingDaysOfEarlierYears() {
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2020, 11, 24), now: now, calendar: utcCalendar) == 0)
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2019, 11, 30), now: now, calendar: utcCalendar) == 6)
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2019, 12, 1), now: now, calendar: utcCalendar) == nil)
        // Yesterday's memory is over; this year's photos are no memory.
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2019, 11, 23), now: now, calendar: utcCalendar) == nil)
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2026, 11, 25), now: now, calendar: utcCalendar) == nil)
        // Across the turn of the year.
        let december = day(2026, 12, 29)
        #expect(SmartOfflinePolicy.daysUntilOnThisDay(day(2020, 1, 2), now: december, calendar: utcCalendar) == 4)
    }

    @Test func scoresFollowTheReasons() throws {
        let today = try #require(SmartOfflinePolicy.score(candidate(1, now), now: now, calendar: utcCalendar))
        #expect(today.reason == .recent)
        #expect(abs(today.score - 0.9) < 0.001)
        let twoMonths = try #require(
            SmartOfflinePolicy.score(candidate(2, now.addingTimeInterval(-60 * 86_400)), now: now, calendar: utcCalendar))
        #expect(abs(twoMonths.score - 0.45) < 0.001)
        // Older than the recent months and no other reason: not a candidate.
        #expect(SmartOfflinePolicy.score(candidate(3, day(2024, 1, 1)), now: now, calendar: utcCalendar) == nil)
        let favorite = try #require(
            SmartOfflinePolicy.score(candidate(4, day(2018, 3, 1), favorite: true), now: now, calendar: utcCalendar))
        #expect(favorite.reason == .favorite)
        #expect(favorite.score >= 0.35 && favorite.score < 0.4)
        let memory = try #require(SmartOfflinePolicy.score(candidate(5, day(2019, 11, 26)), now: now, calendar: utcCalendar))
        #expect(memory.reason == .onThisDay)
        #expect(memory.score > today.score)
        let album = try #require(
            SmartOfflinePolicy.score(candidate(6, day(2015, 6, 1), album: now.addingTimeInterval(-3600)), now: now, calendar: utcCalendar))
        #expect(album.reason == .album)
        // An album opened more than 30 days ago does not count any more.
        #expect(
            SmartOfflinePolicy.score(
                candidate(7, day(2015, 6, 1), album: now.addingTimeInterval(-31 * 86_400)), now: now, calendar: utcCalendar)
                == nil)
        // The best reason wins: a favourite from last week is "recent".
        let both = try #require(
            SmartOfflinePolicy.score(candidate(8, now.addingTimeInterval(-7 * 86_400), favorite: true), now: now, calendar: utcCalendar))
        #expect(both.reason == .recent)
    }

    @Test func rankingPutsUpcomingMemoriesThenRecentPhotosFirst() {
        let ranked = SmartOfflinePolicy.rank(
            [
                candidate(1, day(2010, 5, 5), favorite: true),
                candidate(2, now.addingTimeInterval(-200 * 86_400)),
                candidate(3, now.addingTimeInterval(-86_400)),
                candidate(4, day(2021, 11, 27)),
                candidate(5, day(2012, 1, 1)),
            ], now: now, calendar: utcCalendar)
        #expect(ranked.map(\.fileId) == [4, 3, 1, 2])
    }

    @Test func planFillsTheBudgetBestFirst() {
        let ranked = SmartOfflinePolicy.rank(
            (1...10).map { candidate(FileID($0), now.addingTimeInterval(-Double($0) * 86_400)) }, now: now, calendar: utcCalendar)
        let plan = SmartOfflinePolicy.plan(ranked: ranked, kept: [], budget: 450, quality: .screen, previewBytes: 100)
        #expect(plan.downloads.map(\.fileId) == [1, 2, 3, 4])
        #expect(plan.wanted == [1, 2, 3, 4])
        #expect(plan.wantedBytes == 400)
        #expect(plan.evictions.isEmpty)
    }

    @Test func keptFilesAreNotDownloadedAgainAndCountWithTheirRealSize() {
        let ranked = SmartOfflinePolicy.rank(
            (1...5).map { candidate(FileID($0), now.addingTimeInterval(-Double($0) * 86_400)) }, now: now, calendar: utcCalendar)
        let plan = SmartOfflinePolicy.plan(
            ranked: ranked, kept: [kept(1, bytes: 300, used: now)], budget: 500, quality: .screen, previewBytes: 100)
        #expect(plan.downloads.map(\.fileId) == [2, 3])
        #expect(plan.wantedBytes == 500)
    }

    @Test func unwantedFilesStayUntilTheirRoomIsNeededThenLeastRecentlyUsedGoFirst() {
        // 1…3 are wanted; 20 and 21 were kept for earlier reasons. 20 was in an album opened long ago: no reason applies any
        // more, but the library still shows it.
        let ranked = SmartOfflinePolicy.rank(
            (1...3).map { candidate(FileID($0), now.addingTimeInterval(-Double($0) * 86_400)) }
                + [
                    candidate(20, day(2015, 1, 1), album: now.addingTimeInterval(-40 * 86_400)),
                    candidate(21, day(2015, 1, 1), favorite: true),
                ],
            now: now, calendar: utcCalendar)
        let old = [kept(20, used: now.addingTimeInterval(-10 * 86_400)), kept(21, used: now.addingTimeInterval(-86_400))]
        // Room for everything: nothing goes. 21 is a favourite and still wanted.
        let present: [FileID: String] = [20: "e20", 21: "e21"]
        let roomy = SmartOfflinePolicy.plan(
            ranked: ranked, kept: old, present: present, budget: 1000, quality: .screen, previewBytes: 100)
        #expect(roomy.evictions.isEmpty)
        #expect(roomy.wanted == [1, 2, 3, 21])
        // Room for three new and one old file: the wanted favourite stays, 20 makes room.
        let tight = SmartOfflinePolicy.plan(
            ranked: ranked, kept: old, present: present, budget: 400, quality: .screen, previewBytes: 100)
        #expect(tight.evictions == [20])
        // Without the photo in the library (deleted or archived) it goes even with room to spare.
        let gone = SmartOfflinePolicy.plan(ranked: ranked, kept: old, present: [21: "e21"], budget: 1000, quality: .screen)
        #expect(gone.evictions == [20])
        #expect(tight.wanted == [1, 2, 3, 21])
    }

    @Test func evictionIsLeastRecentlyUsedFirstAndOnlyAsFarAsNeeded() {
        // Three kept favourites from long ago; a smaller budget keeps the best one, the least recently used goes first.
        let favorites = [
            candidate(1, day(2016, 1, 1), favorite: true), candidate(2, day(2016, 1, 2), favorite: true),
            candidate(3, day(2016, 1, 3), favorite: true),
        ]
        let ranked = SmartOfflinePolicy.rank(favorites, now: now, calendar: utcCalendar)
        let keptFiles = [
            kept(1, used: now.addingTimeInterval(-5 * 86_400)), kept(2, used: now.addingTimeInterval(-86_400)),
            kept(3, used: now.addingTimeInterval(-9 * 86_400)),
        ]
        let plan = SmartOfflinePolicy.plan(ranked: ranked, kept: keptFiles, budget: 200, quality: .screen, previewBytes: 100)
        // The newest favourite (3) and the next (2) are wanted; 1 is the one that goes.
        #expect(plan.wanted == [3, 2])
        #expect(plan.evictions == [1])
        #expect(plan.downloads.isEmpty)
    }

    @Test func offRemovesEverything() {
        let ranked = SmartOfflinePolicy.rank([candidate(1, now)], now: now, calendar: utcCalendar)
        let plan = SmartOfflinePolicy.plan(
            ranked: ranked, kept: [kept(1, used: now), kept(2, used: now.addingTimeInterval(-86_400))], budget: 0, quality: .screen)
        #expect(plan.wanted.isEmpty)
        #expect(plan.downloads.isEmpty)
        #expect(Set(plan.evictions) == [1, 2])
    }

    @Test func changedArchivedOrOtherQualityFilesAreReplaced() {
        let ranked = SmartOfflinePolicy.rank([candidate(1, now), candidate(2, now)], now: now, calendar: utcCalendar)
        let plan = SmartOfflinePolicy.plan(
            ranked: ranked,
            kept: [
                kept(1, used: now, etag: "old"),  // changed on the server
                kept(2, used: now, quality: .original),  // the setting changed to previews
                kept(3, used: now),  // archived or deleted: no longer a candidate
            ], budget: 10_000, quality: .screen, previewBytes: 100)
        #expect(Set(plan.evictions) == [1, 2, 3])
        #expect(Set(plan.downloads.map(\.fileId)) == [1, 2])
    }

    @Test func originalsUseTheirSizeAndVideosStayPreviews() {
        let ranked = SmartOfflinePolicy.rank(
            [
                candidate(1, now, size: 4_000_000), candidate(2, now.addingTimeInterval(-60), size: 900_000_000, kind: .video),
                candidate(3, now.addingTimeInterval(-120), size: 0),
            ], now: now, calendar: utcCalendar)
        let plan = SmartOfflinePolicy.plan(ranked: ranked, kept: [], budget: 10_000_000_000, quality: .original, previewBytes: 500)
        #expect(plan.downloads.map(\.fileId) == [1, 2, 3])
        #expect(plan.wantedBytes == 4_000_000 + 500 + SmartOfflinePolicy.defaultOriginalBytes)
        // A smaller original further down still fits where a larger one did not.
        let tight = SmartOfflinePolicy.plan(ranked: ranked, kept: [], budget: 3_500_000, quality: .original, previewBytes: 500)
        #expect(tight.downloads.map(\.fileId) == [2, 3])
        // A kept video preview stays when originals are chosen.
        let keptVideo = SmartOfflinePolicy.plan(
            ranked: ranked, kept: [kept(2, bytes: 500, used: now, quality: .screen)], budget: 10_000_000_000, quality: .original)
        #expect(keptVideo.evictions.isEmpty)
        #expect(!keptVideo.downloads.contains { $0.fileId == 2 })
    }

    @Test func downloadsOnlyOnUnmeteredNetworksOutsideLowPowerMode() {
        #expect(SmartOfflinePolicy.mayDownload(isConnected: true, isExpensive: false, isConstrained: false, isLowPowerMode: false))
        #expect(!SmartOfflinePolicy.mayDownload(isConnected: true, isExpensive: true, isConstrained: false, isLowPowerMode: false))
        #expect(!SmartOfflinePolicy.mayDownload(isConnected: true, isExpensive: false, isConstrained: true, isLowPowerMode: false))
        #expect(!SmartOfflinePolicy.mayDownload(isConnected: true, isExpensive: false, isConstrained: false, isLowPowerMode: true))
        #expect(!SmartOfflinePolicy.mayDownload(isConnected: false, isExpensive: false, isConstrained: false, isLowPowerMode: false))
    }
}
