// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A theme of the weekly photo prompts (SPEC §16.7.3).
public struct PromptTheme: Hashable, Sendable, Identifiable {
    /// Stable, not shown ("reflections").
    public var id: String
    public var title: String
    /// A short nudge where to look.
    public var hint: String
}

/// One week's prompt.
public struct WeeklyPrompt: Hashable, Sendable, Identifiable {
    public var theme: PromptTheme
    /// The week, from its first day (in the user's calendar) to the first day of the next one.
    public var week: DateInterval
    /// Counts weeks from the start of 2024; only used to pick the theme and as an identity.
    public var index: Int

    public var id: Int { index }

    /// The album the week's photos go into: "Prompt: Reflections". The same theme comes back after a year and adds to it.
    public var albumName: String { WeeklyPrompts.albumName(theme) }
}

/// The built-in weekly themes and which one a week has. Every user sees the same theme in the same week, so a family
/// can play along together; no server or network is involved.
public enum WeeklyPrompts {
    /// The first week counted: the one with 3 January 2024 in it.
    static let epochDay = DateComponents(year: 2024, month: 1, day: 3)

    /// The week a date is in, in `calendar` (whose first weekday follows the user's region).
    public static func week(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86400)
    }

    /// The number of weeks between the epoch week and the week of `date`.
    static func weekIndex(of date: Date, calendar: Calendar) -> Int {
        guard let epoch = calendar.date(from: epochDay) else { return 0 }
        let start = week(containing: epoch, calendar: calendar).start
        let current = week(containing: date, calendar: calendar).start
        let days = calendar.dateComponents([.day], from: start, to: current).day ?? 0
        // A week across a daylight saving change has 6 days and 23 hours: whole days count, rounded to weeks.
        return Int((Double(days) / 7).rounded(.down))
    }

    /// This week's prompt.
    public static func prompt(for date: Date, calendar: Calendar = .current) -> WeeklyPrompt {
        let index = weekIndex(of: date, calendar: calendar)
        let all = themes
        let theme = all[((index % all.count) + all.count) % all.count]
        return WeeklyPrompt(theme: theme, week: week(containing: date, calendar: calendar), index: index)
    }

    /// The prompts of the weeks before this one, newest first, back to the week of `since` (at most `limit`).
    public static func history(since: Date, now: Date, limit: Int = 52, calendar: Calendar = .current) -> [WeeklyPrompt] {
        let current = prompt(for: now, calendar: calendar)
        let first = weekIndex(of: since, calendar: calendar)
        var result: [WeeklyPrompt] = []
        var date = current.week.start
        while result.count < limit {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            let prompt = prompt(for: previous, calendar: calendar)
            guard prompt.index >= first, prompt.index < current.index else { break }
            result.append(prompt)
            date = prompt.week.start
        }
        return result
    }

    /// When a reminder for a week goes out: on the week's sixth day at `minutes` after midnight (Saturday at 10:00 where
    /// weeks start on Monday), when there are still two days to take a photo.
    public static func reminderDate(for prompt: WeeklyPrompt, minutes: Int = 10 * 60, calendar: Calendar = .current) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: 5, to: prompt.week.start) else { return nil }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// The reminders to schedule from `now`: the coming weeks' reminder dates that are still ahead, without the current
    /// week's when photos were already added to it.
    public static func reminders(
        now: Date, weeks: Int = 4, currentWeekDone: Bool, minutes: Int = 10 * 60, calendar: Calendar = .current
    ) -> [(prompt: WeeklyPrompt, date: Date)] {
        var result: [(WeeklyPrompt, Date)] = []
        var date = now
        for offset in 0..<weeks {
            let prompt = prompt(for: date, calendar: calendar)
            if let fire = reminderDate(for: prompt, minutes: minutes, calendar: calendar), fire > now, !(offset == 0 && currentWeekDone) {
                result.append((prompt, fire))
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: prompt.week.start) else { break }
            date = next
        }
        return result
    }

    public static func albumName(_ theme: PromptTheme) -> String {
        String(
            localized: "Prompt: \(theme.title)", bundle: .module,
            comment: "Name of the album the photos of a weekly photo prompt go into; the argument is the theme, e.g. Prompt: Reflections.")
    }

    /// The themes in the order the weeks take them: colours, light, subjects and techniques take turns.
    public static var themes: [PromptTheme] {
        [
            PromptTheme(
                id: "reflections", title: String(localized: "Reflections", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Mirrors, puddles, shop windows, a spoon.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Reflections.")),
            PromptTheme(
                id: "something-blue", title: String(localized: "Something Blue", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Sky, jeans, a door, a mug — any blue will do.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Something Blue.")),
            PromptTheme(
                id: "hands", title: String(localized: "Hands", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Hands at work, at rest, holding on.", bundle: .module, comment: "Hint of the weekly photo prompt Hands.")),
            PromptTheme(
                id: "morning-light", title: String(localized: "Morning Light", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "The first hour of the day, low and golden.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Morning Light.")),
            PromptTheme(
                id: "doors", title: String(localized: "Doors", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Old, painted, open, closed, your own.", bundle: .module, comment: "Hint of the weekly photo prompt Doors.")),
            PromptTheme(
                id: "something-you-made",
                title: String(localized: "Something You Made", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "A meal, a drawing, a repair, a mess.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Something You Made.")),
            PromptTheme(
                id: "shadows", title: String(localized: "Shadows", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Let the shadow be the subject.", bundle: .module, comment: "Hint of the weekly photo prompt Shadows.")),
            PromptTheme(
                id: "red", title: String(localized: "Red", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "One spot of red in a quiet picture.", bundle: .module, comment: "Hint of the weekly photo prompt Red.")),
            PromptTheme(
                id: "close-up", title: String(localized: "Close-Up", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Get closer than feels right.", bundle: .module, comment: "Hint of the weekly photo prompt Close-Up.")),
            PromptTheme(
                id: "through-a-window",
                title: String(localized: "Through a Window", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Inside looking out, or outside looking in.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Through a Window.")),
            PromptTheme(
                id: "patterns", title: String(localized: "Patterns", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Tiles, leaves, bricks, a crowd.", bundle: .module, comment: "Hint of the weekly photo prompt Patterns.")),
            PromptTheme(
                id: "a-small-joy", title: String(localized: "A Small Joy", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Whatever made you smile today.", bundle: .module, comment: "Hint of the weekly photo prompt A Small Joy.")),
            PromptTheme(
                id: "green", title: String(localized: "Green", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Moss, a leaf, a traffic light.", bundle: .module, comment: "Hint of the weekly photo prompt Green.")),
            PromptTheme(
                id: "symmetry", title: String(localized: "Symmetry", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Find the middle and stand in it.", bundle: .module, comment: "Hint of the weekly photo prompt Symmetry.")),
            PromptTheme(
                id: "home", title: String(localized: "Home", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "A corner of home you never photograph.", bundle: .module, comment: "Hint of the weekly photo prompt Home.")),
            PromptTheme(
                id: "motion", title: String(localized: "Motion", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Something moving — sharp or blurred.", bundle: .module, comment: "Hint of the weekly photo prompt Motion.")),
            PromptTheme(
                id: "textures", title: String(localized: "Textures", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Bark, wool, rust, bread crust.", bundle: .module, comment: "Hint of the weekly photo prompt Textures.")),
            PromptTheme(
                id: "yellow", title: String(localized: "Yellow", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Lemons, lines on the road, a raincoat.", bundle: .module, comment: "Hint of the weekly photo prompt Yellow."
                )),
            PromptTheme(
                id: "look-up", title: String(localized: "Look Up", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Ceilings, treetops, sky between buildings.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Look Up.")),
            PromptTheme(
                id: "something-old", title: String(localized: "Something Old", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Worn, faded, loved for years.", bundle: .module, comment: "Hint of the weekly photo prompt Something Old.")),
            PromptTheme(
                id: "silhouettes", title: String(localized: "Silhouettes", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Put the light behind it.", bundle: .module, comment: "Hint of the weekly photo prompt Silhouettes.")),
            PromptTheme(
                id: "street-life", title: String(localized: "Street Life", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Your street, ten minutes, no plan.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Street Life.")),
            PromptTheme(
                id: "circles", title: String(localized: "Circles", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Wheels, plates, clocks, the moon.", bundle: .module, comment: "Hint of the weekly photo prompt Circles.")),
            PromptTheme(
                id: "water", title: String(localized: "Water", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "A river, a glass, rain on the window.", bundle: .module, comment: "Hint of the weekly photo prompt Water.")),
            PromptTheme(
                id: "the-view-from-here",
                title: String(localized: "The View From Here", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Exactly what you see right now.", bundle: .module,
                    comment: "Hint of the weekly photo prompt The View From Here.")),
            PromptTheme(
                id: "orange", title: String(localized: "Orange", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Sunsets, fruit, safety vests.", bundle: .module, comment: "Hint of the weekly photo prompt Orange.")),
            PromptTheme(
                id: "stairs", title: String(localized: "Stairs", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(localized: "Up, down, spiral, steep.", bundle: .module, comment: "Hint of the weekly photo prompt Stairs.")),
            PromptTheme(
                id: "breakfast", title: String(localized: "Breakfast", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "The first meal, before it's gone.", bundle: .module, comment: "Hint of the weekly photo prompt Breakfast.")),
            PromptTheme(
                id: "leading-lines", title: String(localized: "Leading Lines", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Roads, rails, fences that pull the eye in.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Leading Lines.")),
            PromptTheme(
                id: "tiny-things", title: String(localized: "Tiny Things", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Something smaller than your thumb.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Tiny Things.")),
            PromptTheme(
                id: "black-and-white", title: String(localized: "Black and White", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Look for light and shape, not colour.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Black and White.")),
            PromptTheme(
                id: "signs", title: String(localized: "Signs and Letters", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Words in the wild.", bundle: .module, comment: "Hint of the weekly photo prompt Signs and Letters.")),
            PromptTheme(
                id: "sky", title: String(localized: "Sky", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(localized: "The same sky, twice a day.", bundle: .module, comment: "Hint of the weekly photo prompt Sky.")),
            PromptTheme(
                id: "from-above", title: String(localized: "From Above", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Hold the camera straight down.", bundle: .module, comment: "Hint of the weekly photo prompt From Above.")),
            PromptTheme(
                id: "flowers", title: String(localized: "Flowers", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "In a vase, a garden, a crack in the pavement.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Flowers.")),
            PromptTheme(
                id: "night", title: String(localized: "After Dark", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Lamps, windows, the glow of a screen.", bundle: .module,
                    comment: "Hint of the weekly photo prompt After Dark.")),
            PromptTheme(
                id: "something-new", title: String(localized: "Something New", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "A first time, a new thing, a fresh start.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Something New.")),
            PromptTheme(
                id: "frame-in-a-frame",
                title: String(localized: "Frame in a Frame", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "An arch, a doorway, branches around the view.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Frame in a Frame.")),
            PromptTheme(
                id: "animals", title: String(localized: "Animals", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Pets, birds, a snail on the path.", bundle: .module, comment: "Hint of the weekly photo prompt Animals.")),
            PromptTheme(
                id: "pink", title: String(localized: "Pink", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Blossoms, candy, a sunset's last minutes.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Pink.")),
            PromptTheme(
                id: "wheels", title: String(localized: "Wheels", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Bikes, buses, a pram, a skateboard.", bundle: .module, comment: "Hint of the weekly photo prompt Wheels.")),
            PromptTheme(
                id: "contrast", title: String(localized: "Contrast", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Light against dark, old against new.", bundle: .module, comment: "Hint of the weekly photo prompt Contrast."
                )),
            PromptTheme(
                id: "self-portrait", title: String(localized: "Self-Portrait", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "You, without your face if you like.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Self-Portrait.")),
            PromptTheme(
                id: "books", title: String(localized: "Books", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "On a shelf, in a hand, in a pile.", bundle: .module, comment: "Hint of the weekly photo prompt Books.")),
            PromptTheme(
                id: "golden-hour", title: String(localized: "Golden Hour", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(localized: "The hour before sunset.", bundle: .module, comment: "Hint of the weekly photo prompt Golden Hour.")
            ),
            PromptTheme(
                id: "curves", title: String(localized: "Curves", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(localized: "Nothing straight this week.", bundle: .module, comment: "Hint of the weekly photo prompt Curves.")),
            PromptTheme(
                id: "weather", title: String(localized: "Weather", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Whatever it's doing out there.", bundle: .module, comment: "Hint of the weekly photo prompt Weather.")),
            PromptTheme(
                id: "numbers", title: String(localized: "Numbers", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "House numbers, clocks, price tags.", bundle: .module, comment: "Hint of the weekly photo prompt Numbers.")),
            PromptTheme(
                id: "white", title: String(localized: "White", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Snow, paper, steam, a quiet wall.", bundle: .module, comment: "Hint of the weekly photo prompt White.")),
            PromptTheme(
                id: "music", title: String(localized: "Music", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Instruments, headphones, someone singing.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Music.")),
            PromptTheme(
                id: "minimal", title: String(localized: "Less Is More", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "One subject, lots of empty space.", bundle: .module,
                    comment: "Hint of the weekly photo prompt Less Is More.")),
            PromptTheme(
                id: "together", title: String(localized: "Together", bundle: .module, comment: "Weekly photo prompt theme."),
                hint: String(
                    localized: "Two or more of anything — or anyone.", bundle: .module, comment: "Hint of the weekly photo prompt Together."
                )),
        ]
    }
}
