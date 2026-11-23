// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// What VoiceOver reads for cards, tiles, markers and the viewer.
@Suite struct AccessibilityTextTests {
    let date = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func albumCardSaysWhatItIsAndHowManyItemsItHas() {
        #expect(AccessibilityText.album(title: "Lisbon 2025", itemCount: 28) == "Lisbon 2025, album, 28 items")
        #expect(AccessibilityText.album(title: "Lisbon 2025", itemCount: 1) == "Lisbon 2025, album, 1 item")
        #expect(
            AccessibilityText.album(title: "Hiking", itemCount: 3, owner: "Anna", location: "Alps", sharing: .people)
                == "Hiking, album, 3 items, shared by Anna, Alps, shared with others")
        #expect(AccessibilityText.album(title: "Party", itemCount: 0, sharing: .link) == "Party, album, 0 items, shared with a link")
    }

    @Test func collectionAndMemoryCards() {
        #expect(
            AccessibilityText.collection(title: "Lisbon", kind: "place", detail: AccessibilityText.photos(28)) == "Lisbon, place, 28 photos"
        )
        #expect(AccessibilityText.collection(title: "Holidays", kind: "folder", detail: nil) == "Holidays, folder")
        #expect(AccessibilityText.photos(1) == "1 photo")
        #expect(
            AccessibilityText.memory(title: "3 years ago", dateLine: "22 Nov – 25 Nov 2023", itemCount: 12)
                == "3 years ago, memory, 22 Nov – 25 Nov 2023, 12 photos")
        // A trip titled by its date does not repeat it.
        #expect(AccessibilityText.memory(title: "22 Nov 2026", dateLine: nil, itemCount: 8) == "22 Nov 2026, memory, 8 photos")
    }

    @Test func mediaLabelNamesKindDateAndWhatIsKnown() {
        let when = date.formatted(date: .long, time: .shortened)
        #expect(AccessibilityText.media(isVideo: false, isLivePhoto: false, date: date) == "Photo, \(when)")
        #expect(AccessibilityText.media(isVideo: false, isLivePhoto: true, date: date, isFavorite: true) == "Live Photo, \(when), Favorite")
        let video = AccessibilityText.media(isVideo: true, isLivePhoto: false, date: date, duration: 65)
        #expect(video == "Video, \(when), \(AccessibilityText.spokenDuration(65))")
        let people = ["Anna", "Ben"].formatted(.list(type: .and))
        #expect(
            AccessibilityText.media(
                isVideo: false, isLivePhoto: false, date: date, place: "Lisbon", people: ["Anna", "Ben"], isFavorite: true,
                caption: "A dog on the beach")
                == "Photo, \(when), Lisbon, with \(people), Favorite, A dog on the beach")
        // Empty values are left out, not read as a pause.
        #expect(AccessibilityText.media(isVideo: false, isLivePhoto: false, date: date, place: "", caption: "") == "Photo, \(when)")
    }

    @Test func spokenDurationIsWordsNotAClockFace() {
        let spoken = AccessibilityText.spokenDuration(65)
        #expect(spoken != Formatters.duration(65))
        #expect(spoken == Duration.seconds(65).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
    }

    @Test func viewerPositionAndMapMarkers() {
        #expect(AccessibilityText.position(index: 2, count: 120) == "3 of 120")
        #expect(AccessibilityText.mapMarker(place: "Lisbon", count: 12, newest: date) == "Lisbon, 12 photos")
        let day = date.formatted(date: .abbreviated, time: .omitted)
        #expect(AccessibilityText.mapMarker(place: nil, count: 1, newest: date) == "1 photo, newest from \(day)")
    }

    @Test func overlaysGetDarkerWithIncreasedContrast() {
        #expect(OverlayLegibility.scrimOpacity(base: 0.5, increased: false) == 0.5)
        #expect(OverlayLegibility.scrimOpacity(base: 0.5, increased: true) == 0.75)
        #expect(OverlayLegibility.scrimOpacity(base: 0.9, increased: true) == 0.9)
    }

    @Test func durationsUseTheLocalesClockFormat() {
        #expect(Formatters.duration(65) == Duration.seconds(65).formatted(.time(pattern: .minuteSecond)))
        #expect(Formatters.duration(3723) == Duration.seconds(3723).formatted(.time(pattern: .hourMinuteSecond)))
    }
}
