// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Weeks that start on Monday, in UTC.
let mondayCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

@Suite struct PostcardTests {
    @Test func cardFollowsThePhotosOrientation() {
        #expect(PostcardLayout(photoAspectRatio: 1.5).size == CGSize(width: 1800, height: 1200))
        #expect(PostcardLayout(photoAspectRatio: 0.75).size == CGSize(width: 1200, height: 1800))
        #expect(!PostcardLayout(photoAspectRatio: 1).isPortrait, "square photos get a landscape card")
    }

    @Test func everythingOnTheBackStaysOnTheCard() {
        for layout in [PostcardLayout(photoAspectRatio: 1.5), PostcardLayout(photoAspectRatio: 0.6)] {
            let card = CGRect(origin: .zero, size: layout.size)
            #expect(card.contains(layout.stampRect))
            #expect(card.contains(layout.messageRect))
            #expect(card.contains(layout.headingRect))
            #expect(layout.messageRect.height > layout.size.height * 0.25, "room for a few lines")
            #expect(!layout.messageRect.intersects(layout.stampRect), "the message never runs under the stamp")
            let postmark = CGRect(
                x: layout.postmarkCenter.x - layout.postmarkRadius, y: layout.postmarkCenter.y - layout.postmarkRadius,
                width: 2 * layout.postmarkRadius, height: 2 * layout.postmarkRadius)
            #expect(card.contains(postmark))
            for line in layout.addressLines {
                #expect(card.contains(line.from) && card.contains(line.to))
                #expect(line.from.y > postmark.maxY, "address lines are below the postmark")
                #expect(line.from.x >= layout.messageRect.maxX || line.from.y > layout.messageRect.maxY, "address side is apart")
            }
        }
    }

    @Test func framesLeaveTheEdgeToEdgePhotoAlone() {
        let layout = PostcardLayout(photoAspectRatio: 1.5)
        #expect(layout.photoRect(.edgeToEdge) == CGRect(origin: .zero, size: layout.size))
        for style in [PostcardStyle.classic, .airmail, .vintage] {
            let rect = layout.photoRect(style)
            #expect(rect.minX > 0 && rect.minY > 0 && rect.maxX < layout.size.width && rect.maxY < layout.size.height)
        }
        #expect(layout.borderWidth(.airmail) > layout.airmailStripeWidth, "a white margin inside the stripes")
    }

    @Test func messageIsTrimmedAndLimited() {
        #expect(PostcardContent.printedMessage("  Hello!\n ") == "Hello!")
        #expect(PostcardContent.printedMessage(String(repeating: "a", count: 900)).count == PostcardContent.maximumMessageLength)
        let words = PostcardContent.printedMessage(String(repeating: "word ", count: 200))
        #expect(words.hasSuffix("word…"), "cut between words")
        #expect(words.count <= PostcardContent.maximumMessageLength)
        let lines = (1...20).map(String.init).joined(separator: "\n")
        #expect(PostcardContent.printedMessage(lines).components(separatedBy: "\n").count == 12)
    }

    @Test func greetingNeedsAPlace() {
        #expect(PostcardContent.defaultGreeting(place: "  ") == "")
        #expect(PostcardContent.defaultGreeting(place: "Lisbon").contains("Lisbon"))
    }

    @Test func folderNamesAreSafeAndDated() {
        let date = day(2026, 11, 25)
        #expect(PostcardFiles.folderName(date: date, place: "Lisbon", calendar: utcCalendar) == "2026-11-25 Lisbon")
        #expect(PostcardFiles.folderName(date: date, place: "Lisbon", attempt: 3, calendar: utcCalendar) == "2026-11-25 Lisbon 3")
        #expect(PostcardFiles.folderName(date: date, place: "a/b:c\nd", calendar: utcCalendar) == "2026-11-25 a b c d")
        #expect(PostcardFiles.folderName(date: date, place: "..", calendar: utcCalendar).hasPrefix("2026-11-25 "))
        #expect(!PostcardFiles.folderName(date: date, place: "..", calendar: utcCalendar).hasSuffix("."))
        #expect(PostcardFiles.sanitized(String(repeating: "x", count: 100)).count == 60)
        #expect(PostcardFiles.frontFileName < PostcardFiles.backFileName, "the front is listed first")
    }
}

@Suite struct WeeklyPromptTests {
    @Test func everyDayOfAWeekHasTheSamePrompt() {
        let monday = day(2026, 11, 23)
        let prompt = WeeklyPrompts.prompt(for: monday, calendar: mondayCalendar)
        for offset in 0..<7 {
            let date = mondayCalendar.date(byAdding: .day, value: offset, to: monday)!
            #expect(WeeklyPrompts.prompt(for: date, calendar: mondayCalendar) == prompt)
        }
        #expect(prompt.week.start == mondayCalendar.startOfDay(for: monday))
        let next = WeeklyPrompts.prompt(for: day(2026, 11, 30), calendar: mondayCalendar)
        #expect(next.index == prompt.index + 1)
        #expect(next.theme != prompt.theme)
    }

    @Test func themesAreUniqueAndCycleThroughTheYear() {
        let themes = WeeklyPrompts.themes
        #expect(themes.count == 52)
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(themes.allSatisfy { !$0.title.isEmpty && !$0.hint.isEmpty })
        let first = WeeklyPrompts.prompt(for: day(2025, 3, 5), calendar: mondayCalendar)
        let yearLater = WeeklyPrompts.prompt(
            for: mondayCalendar.date(byAdding: .day, value: 7 * 52, to: day(2025, 3, 5))!, calendar: mondayCalendar)
        #expect(first.theme == yearLater.theme)
        #expect(WeeklyPrompts.prompt(for: day(2024, 1, 3), calendar: mondayCalendar).index == 0)
        #expect(WeeklyPrompts.prompt(for: day(2023, 6, 1), calendar: mondayCalendar).index < 0, "weeks before the epoch work too")
    }

    @Test func daylightSavingDoesNotSkipAWeek() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        berlin.firstWeekday = 2
        // The clocks went forward on 29 March 2026.
        let before = WeeklyPrompts.prompt(
            for: berlin.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 12))!, calendar: berlin)
        let after = WeeklyPrompts.prompt(for: berlin.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12))!, calendar: berlin)
        #expect(after.index == before.index + 1)
    }

    @Test func historyGoesBackToWhenPromptsWereTurnedOn() {
        let now = day(2026, 11, 25)
        let history = WeeklyPrompts.history(since: day(2026, 11, 4), now: now, calendar: mondayCalendar)
        #expect(history.count == 3)
        let current = WeeklyPrompts.prompt(for: now, calendar: mondayCalendar)
        #expect(history.map(\.index) == [current.index - 1, current.index - 2, current.index - 3])
        #expect(WeeklyPrompts.history(since: now, now: now, calendar: mondayCalendar).isEmpty, "the current week is not history")
        #expect(WeeklyPrompts.history(since: day(2020, 1, 1), now: now, limit: 10, calendar: mondayCalendar).count == 10)
    }

    @Test func remindersComeOnTheSixthDayAndSkipAWeekThatIsDone() throws {
        let wednesday = day(2026, 11, 25)
        let reminders = WeeklyPrompts.reminders(now: wednesday, weeks: 3, currentWeekDone: false, calendar: mondayCalendar)
        #expect(reminders.count == 3)
        let first = try #require(reminders.first)
        #expect(mondayCalendar.component(.weekday, from: first.date) == 7, "Saturday")
        #expect(mondayCalendar.component(.hour, from: first.date) == 10)
        let done = WeeklyPrompts.reminders(now: wednesday, weeks: 3, currentWeekDone: true, calendar: mondayCalendar)
        #expect(done.count == 2)
        #expect(done.first?.prompt.index == first.prompt.index + 1)
        let sunday = day(2026, 11, 29)
        #expect(
            WeeklyPrompts.reminders(now: sunday, weeks: 1, currentWeekDone: false, calendar: mondayCalendar).isEmpty, "Saturday has passed")
    }

    @Test func albumNameNamesTheTheme() {
        let prompt = WeeklyPrompts.prompt(for: day(2024, 1, 3), calendar: mondayCalendar)
        #expect(prompt.albumName.contains(prompt.theme.title))
        #expect(prompt.albumName != prompt.theme.title)
    }
}

@Suite struct FamilySuggestionTests {
    func item(_ id: FileID, _ date: Date, lat: Double? = nil, lon: Double? = nil, place: String? = nil, name: String = "IMG.jpg")
        -> MediaItem
    {
        MediaItem(
            fileId: id, path: "/Photos/\(id).jpg", name: name, mimeType: "image/jpeg", capturedAt: date, latitude: lat, longitude: lon,
            place: place)
    }

    let members: Set<String> = ["Anna", "Ben"]

    @Test func photosWithFamilyMembersAreGroupedByMonth() throws {
        let candidates: [(item: MediaItem, people: Set<String>)] = [
            (item(1, day(2026, 10, 3)), ["Anna"]),
            (item(2, day(2026, 10, 20)), ["Ben", "Carl"]),
            (item(3, day(2026, 9, 1)), ["Anna"]),
            (item(4, day(2026, 10, 5)), ["Carl"]),
            (item(5, day(2026, 10, 6)), []),
        ]
        let result = FamilySuggestions.suggestions(
            candidates: candidates, members: members, folder: [], decided: [], calendar: utcCalendar)
        #expect(result.count == 2)
        let october = try #require(result.first)
        #expect(october.fileIds == [2, 1], "newest first")
        #expect(
            october.reason
                == .people(names: ["Anna", "Ben"], month: utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!))
        #expect(result[1].fileIds == [3])
    }

    @Test func photosFromADayAndPlaceTheFamilyFolderHasAreSuggested() throws {
        let party = day(2026, 7, 4, 15)
        let folder = [FamilyFolderMoment(timestamp: party, coordinate: GeoCoordinate(latitude: 52.52, longitude: 13.405))]
        let candidates: [(item: MediaItem, people: Set<String>)] = [
            (item(1, day(2026, 7, 4, 18), lat: 52.521, lon: 13.406), []),  // 150 m away, same day
            (item(2, day(2026, 7, 4, 9), lat: 48.14, lon: 11.58), []),  // same day, Munich
            (item(3, day(2026, 7, 4, 10)), []),  // same day, no location
            (item(4, day(2026, 7, 5), lat: 52.52, lon: 13.405), []),  // next day
        ]
        let result = FamilySuggestions.suggestions(
            candidates: candidates, members: members, folder: folder, decided: [], calendar: utcCalendar)
        let only = try #require(result.first)
        #expect(result.count == 1)
        #expect(only.fileIds == [1])
        #expect(only.reason == .sharedDay(day: utcCalendar.startOfDay(for: party), place: nil))
    }

    @Test func samePlaceNameCountsWithoutCoordinates() throws {
        let folder = [FamilyFolderMoment(timestamp: day(2026, 8, 1), place: "Lisbon")]
        let result = FamilySuggestions.suggestions(
            candidates: [(item(7, day(2026, 8, 1, 20), place: "lisbon"), [])], members: [], folder: folder, decided: [],
            calendar: utcCalendar)
        #expect(result.first?.fileIds == [7])
        #expect(result.first?.reason == .sharedDay(day: day(2026, 8, 1, 0), place: "lisbon"))
    }

    @Test func decidedScreenshotsAndArchivedNeverComeBack() {
        var archived = item(3, day(2026, 10, 3))
        archived.isArchived = true
        let candidates: [(item: MediaItem, people: Set<String>)] = [
            (item(1, day(2026, 10, 3)), ["Anna"]),
            (item(2, day(2026, 10, 3), name: "Screenshot 2026-10-03 at 10.00.00.png"), ["Anna"]),
            (archived, ["Anna"]),
        ]
        let result = FamilySuggestions.suggestions(
            candidates: candidates, members: members, folder: [], decided: [1], calendar: utcCalendar)
        #expect(result.isEmpty)
    }

    @Test func largeGroupsAreSplit() {
        let candidates: [(item: MediaItem, people: Set<String>)] = (1...450).map {
            (item(FileID($0), day(2026, 10, 1).addingTimeInterval(Double($0) * 60)), ["Anna"])
        }
        let result = FamilySuggestions.suggestions(candidates: candidates, members: members, folder: [], decided: [], calendar: utcCalendar)
        #expect(result.map(\.fileIds.count) == [200, 200, 50])
        #expect(Set(result.map(\.id)).count == 1, "the parts of one month share the month's id")
        #expect(result[0].fileIds.first == 450)
    }
}

@Suite struct DeviceMirrorTests {
    func photo(_ id: FileID, kind: MediaKind = .image, archived: Bool = false, video: Bool = false) -> MediaItem {
        var item = MediaItem(fileId: id, path: "/Photos/\(id).jpg", mimeType: kind == .video ? "video/mp4" : "image/jpeg", kind: kind)
        item.isArchived = archived
        item.isLivePhotoVideo = video
        return item
    }

    @Test func onlyVisiblePhotosAreCopied() {
        let items = [photo(1), photo(2, kind: .video), photo(3, archived: true), photo(4), photo(5), photo(6, video: true), photo(1)]
        let eligible = DeviceMirror.eligible(items, peopleOf: [4: ["Secret"], 5: ["Anna"]], hiddenPeople: ["Secret"])
        #expect(eligible.map(\.fileId) == [1, 5])
    }

    @Test func eligibleIsCapped() {
        let items = (1...400).map { photo(FileID($0)) }
        #expect(DeviceMirror.eligible(items, peopleOf: [:], hiddenPeople: []).count == DeviceMirror.maximumPhotos)
    }

    @Test func planAddsRemovesAndReplacesEditedPhotos() {
        let mirrored = [
            DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L1"),
            DeviceMirror.Entry(fileId: 2, etag: "b", localIdentifier: "L2"),
            DeviceMirror.Entry(fileId: 3, etag: "c", localIdentifier: "L3"),
            DeviceMirror.Entry(fileId: 4, etag: "d", localIdentifier: "L4"),
        ]
        let plan = DeviceMirror.plan(
            desired: [(1, "a"), (2, "b2"), (4, "d"), (5, "e")], mirrored: mirrored, presentOnDevice: ["L1", "L2", "L3"])
        #expect(plan.add == [2, 4, 5], "edited 2 again, 4 was deleted on the device, 5 is new")
        #expect(plan.remove.map(\.localIdentifier) == ["L2", "L3"], "old version of 2, and 3 left the album")
        #expect(plan.forget.map(\.localIdentifier) == ["L4"])
    }

    @Test func nothingToDoWhenInSync() {
        let mirrored = [DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L1")]
        #expect(DeviceMirror.plan(desired: [(1, "a")], mirrored: mirrored, presentOnDevice: ["L1"]).isEmpty)
    }

    @Test func duplicateCopiesAreRemoved() {
        let mirrored = [
            DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L1"),
            DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L9"),
        ]
        let plan = DeviceMirror.plan(desired: [(1, "a")], mirrored: mirrored, presentOnDevice: ["L1", "L9"])
        #expect(plan.add.isEmpty)
        #expect(plan.remove.map(\.localIdentifier) == ["L9"])
    }

    @Test func turningOffIsAPlanWithNothingDesired() {
        let mirrored = [DeviceMirror.Entry(fileId: 1, etag: "a", localIdentifier: "L1")]
        #expect(DeviceMirror.plan(desired: [], mirrored: mirrored, presentOnDevice: ["L1"]).remove == mirrored)
        #expect(DeviceMirror.deviceAlbumTitle("Summer").contains("Summer"))
    }
}
