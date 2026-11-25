// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Testing

@testable import PhotosModel

/// Ratings and flags as system tags (SPEC §15.2).
struct CullingTests {
    @Test func tagNamesHaveTheirMeaning() {
        #expect(CullingTags.ratingNames == ["★", "★★", "★★★", "★★★★", "★★★★★"])
        #expect(CullingTags.meaning(of: "★★★") == .rating(3))
        #expect(CullingTags.meaning(of: " ★★ ") == .rating(2))
        #expect(CullingTags.meaning(of: "Pick") == .flag(.pick))
        // A tag of another case that the server reused.
        #expect(CullingTags.meaning(of: "pick") == .flag(.pick))
        #expect(CullingTags.meaning(of: "REJECTED") == .flag(.reject))
        #expect(CullingTags.meaning(of: "★★★★★★") == nil)
        #expect(CullingTags.meaning(of: "Picks") == nil)
        #expect(CullingTags.meaning(of: "") == nil)
        #expect(CullingTags.name(of: .rating(4)) == "★★★★")
        #expect(CullingTags.name(of: .flag(.none)) == nil)
    }

    @Test func markOfTagsHighestRatingAndPickWin() {
        #expect(CullingTags.mark(fromTagNames: ["Dog", "★★", "Rejected"]) == CullingMark(rating: 2, flag: .reject))
        // Rated on two devices at once: the higher one counts.
        #expect(CullingTags.mark(fromTagNames: ["★★★★", "★"]).rating == 4)
        // Picked and rejected: "Delete Rejected" must never take a picked photo.
        #expect(CullingTags.mark(fromTagNames: ["Rejected", "Pick"]).flag == .pick)
        #expect(CullingTags.mark(fromTagNames: ["Holiday"]).isEmpty)
    }

    @Test func changesTouchOnlyWhatDiffers() {
        let target = CullingMark(rating: 3, flag: .pick)
        var change = CullingTags.changes(from: ["★", "Pick"], to: target)
        #expect(change.remove == ["★"])
        #expect(change.add == [.rating(3)])
        change = CullingTags.changes(from: ["★★★", "pick"], to: target)
        #expect(change.remove.isEmpty && change.add.isEmpty)
        // Clearing removes every culling tag, also duplicates of another case.
        change = CullingTags.changes(from: ["★★", "★★★★", "Rejected", "rejected"], to: .none)
        #expect(change.remove == ["★★", "★★★★", "Rejected", "rejected"])
        #expect(change.add.isEmpty)
        // A duplicate of a wanted tag is removed, one copy stays.
        change = CullingTags.changes(from: ["Pick", "PICK"], to: CullingMark(flag: .pick))
        #expect(change.remove.count == 1 && change.add.isEmpty)
    }

    @Test func keysAndCommands() {
        #expect(CullingCommand(key: "p") == .flag(.pick))
        #expect(CullingCommand(key: "X") == .flag(.reject))
        #expect(CullingCommand(key: "u") == .flag(.none))
        #expect(CullingCommand(key: "0") == .rate(0))
        #expect(CullingCommand(key: "5") == .rate(5))
        #expect(CullingCommand(key: "6") == nil)
        #expect(CullingCommand(key: "c") == nil)
        let mark = CullingMark(rating: 2, flag: .reject)
        #expect(CullingCommand.rate(4).applied(to: mark) == CullingMark(rating: 4, flag: .reject))
        #expect(CullingCommand.flag(.none).applied(to: mark) == CullingMark(rating: 2))
        #expect(CullingMark(rating: 9).rating == 5)
    }

    @Test func filtersMatchMarks() {
        let picked = CullingMark(rating: 4, flag: .pick)
        let rejected = CullingMark(rating: 1, flag: .reject)
        let plain = CullingMark.none
        #expect(CullingFilter.picks.matches(picked) && !CullingFilter.picks.matches(rejected))
        #expect(CullingFilter.rejected.matches(rejected) && !CullingFilter.rejected.matches(plain))
        #expect(CullingFilter.unflagged.matches(plain) && !CullingFilter.unflagged.matches(picked))
        #expect(CullingFilter.notRejected.matches(picked) && !CullingFilter.notRejected.matches(rejected))
        #expect(CullingFilter.rating(atLeast: 3).matches(picked) && !CullingFilter.rating(atLeast: 3).matches(rejected))
        #expect(CullingFilter.unrated.matches(plain) && !CullingFilter.unrated.matches(rejected))
        #expect(CullingFilter.all.matches(rejected))
    }
}
