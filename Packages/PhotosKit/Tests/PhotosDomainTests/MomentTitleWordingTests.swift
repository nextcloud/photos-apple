// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

/// What the language model is told about a moment and which of its answers are kept (SPEC §16.1).
@Suite struct MomentTitleWordingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func facts(
        places: [String] = ["Lisbon"], people: [String] = [], activities: [MomentActivity] = [], days: Int = 1, isAway: Bool = true
    ) -> MomentFacts {
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 18))!
        return MomentFacts(
            places: places, country: places.isEmpty ? nil : "Portugal", people: people, activities: activities, days: days,
            isAway: isAway, start: end.addingTimeInterval(-Double(days - 1) * 86_400 - 3600), end: end)
    }

    @Test func thePromptHasTheFactsAndNothingElse() {
        let prompt = MomentTitleWording.prompt(
            facts(places: ["Lisbon", "Sintra"], people: ["Anna"], activities: [.beach], days: 2), calendar: calendar)
        #expect(prompt.contains("When: 2 days, Saturday, November 21 to Sunday, November 22"))
        #expect(prompt.contains("Where: Lisbon, Portugal (also Sintra), away from home"))
        #expect(prompt.contains("People: Anna"))
        #expect(prompt.contains("Seen in the photos: a beach"))
        let home = MomentTitleWording.prompt(facts(places: [], people: ["Anna"], isAway: false), calendar: calendar)
        #expect(!home.contains("Where:"))
        #expect(MomentTitleWording.instructions(locale: Locale(identifier: "de_DE")).contains("in German"))
    }

    @Test func goodAnswersAreTidied() {
        #expect(MomentTitleWording.cleaned("  \"Sunny Sunday in Lisbon.\"\n", facts: facts()) == "Sunny Sunday in Lisbon")
        #expect(MomentTitleWording.cleaned("Pastéis in lisbon", facts: facts()) == "Pastéis in lisbon")
        #expect(MomentTitleWording.cleaned("Lisboa? No: Lisbon days", facts: facts()) == "Lisboa? No: Lisbon days")
        // A Christmas moment needs no place.
        #expect(MomentTitleWording.cleaned("Christmas Eve", facts: facts(activities: [.christmas])) == "Christmas Eve")
    }

    @Test func badAnswersAreThrownAway() {
        // Too long, a year, an emoji, a hashtag, two lines.
        #expect(MomentTitleWording.cleaned("A wonderful long sunny Sunday afternoon in Lisbon", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("Lisbon 2026", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("Lisbon 22.11.", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("Lisbon ☀️", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("#Lisbon", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("Lisbon\nSunday", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("", facts: facts()) == nil)
        // The model wandered off: another place, or the birthday of someone else.
        #expect(MomentTitleWording.cleaned("A day in Paris", facts: facts()) == nil)
        #expect(MomentTitleWording.cleaned("Ben’s big day", facts: facts(people: ["Anna"], activities: [.birthday])) == nil)
        #expect(MomentTitleWording.cleaned("Anna turns one", facts: facts(people: ["Anna"], activities: [.birthday])) == "Anna turns one")
        // A day at home with people must name one of them.
        #expect(MomentTitleWording.cleaned("Cozy Sunday", facts: facts(places: ["Berlin"], people: ["Anna"], isAway: false)) == nil)
        #expect(
            MomentTitleWording.cleaned("Sunday with Anna", facts: facts(places: ["Berlin"], people: ["Anna"], isAway: false))
                == "Sunday with Anna")
    }
}
