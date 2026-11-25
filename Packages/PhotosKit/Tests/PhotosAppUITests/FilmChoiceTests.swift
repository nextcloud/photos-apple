// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI
@testable import PhotosDomain

/// The film style and music chosen per memory, and the birthdays of "through the years" (SPEC §16.6).
@MainActor @Suite struct FilmChoiceTests {
    func defaults() -> UserDefaults {
        let name = "film-choices-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aMemoryKeepsItsStyleAndMusic() {
        let defaults = defaults()
        #expect(FilmChoiceStore.choice(for: "trip-1", defaults: defaults) == FilmChoice(style: .cinematic, soundtrack: .style))
        FilmChoiceStore.save(FilmChoice(style: .superEight, soundtrack: .none), for: "trip-1", defaults: defaults)
        #expect(FilmChoiceStore.choice(for: "trip-1", defaults: defaults) == FilmChoice(style: .superEight, soundtrack: .none))
        #expect(FilmChoiceStore.choice(for: "trip-2", defaults: defaults).style == .cinematic)
    }

    @Test func withOwnMusicTheDefaultIsThatMusicAndWithoutItTheStylesOwn() {
        let defaults = defaults()
        defaults.set(SlideshowMusic(source: .file("song.m4a"), title: "Song").stored, forKey: SlideshowMusicStore.key)
        #expect(FilmChoiceStore.choice(for: "m", defaults: defaults).soundtrack == .mine)
        FilmChoiceStore.save(FilmChoice(style: .calm, soundtrack: .mine), for: "m", defaults: defaults)
        // The music was removed in Settings since: the style's own instead.
        defaults.removeObject(forKey: SlideshowMusicStore.key)
        #expect(FilmChoiceStore.choice(for: "m", defaults: defaults) == FilmChoice(style: .calm, soundtrack: .style))
    }

    @Test func onlyTheMostRecentChoicesAreKept() {
        let defaults = defaults()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(FilmChoiceStore.limit + 5) {
            FilmChoiceStore.save(
                FilmChoice(style: .upbeat, soundtrack: .style), for: "memory-\(index)", defaults: defaults,
                now: start.addingTimeInterval(Double(index)))
        }
        #expect(FilmChoiceStore.choice(for: "memory-0", defaults: defaults).style == .cinematic)
        #expect(FilmChoiceStore.choice(for: "memory-\(FilmChoiceStore.limit + 4)", defaults: defaults).style == .upbeat)
    }

    @Test func scoresArePlayableMusicButNeverTheUsersChoice() {
        let music = FilmStyle.upbeat.scoreMusic
        #expect(music.scoreMood == .upbeat)
        #expect(SlideshowMusic(source: .file("a"), title: "a").scoreMood == nil)
    }

    @Test func birthdaysArePerAccountAndPerson() {
        let defaults = defaults()
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        BirthdayStore.set(date, of: "Anna", account: "a1", defaults: defaults)
        #expect(BirthdayStore.birthday(of: "Anna", account: "a1", defaults: defaults) == date)
        #expect(BirthdayStore.birthday(of: "Anna", account: "a2", defaults: defaults) == nil)
        BirthdayStore.set(nil, of: "Anna", account: "a1", defaults: defaults)
        #expect(BirthdayStore.birthday(of: "Anna", account: "a1", defaults: defaults) == nil)
    }

    @Test func agesAreWrittenOut() {
        #expect(YearsText.age(DateComponents(year: 3))?.contains("3") == true)
        #expect(YearsText.age(DateComponents(month: 8))?.contains("8") == true)
    }
}
