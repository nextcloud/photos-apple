// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Searches typed in words, read on the device into chips (SPEC §16.2).
@Suite struct NaturalSearchTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    /// Wednesday, 25 November 2026, 10:00 in Berlin.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
    static let context = SearchDates.Context(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    static let vocabulary = NaturalSearch.Vocabulary(
        places: ["Lisbon", "New York", "São Paulo"], people: ["Anna Schmidt", "Ben", "Jan"],
        tags: [(id: 7, name: "Holiday")],
        albums: [
            (id: "own:Summer", title: "Summer"), (id: "own:Road trip", title: "Road trip"), (id: "own:Lisbon 2025", title: "Lisbon 2025"),
        ],
        labels: ["dog", "beach", "snow", "sunset"])

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    static func range(_ filter: SearchFilter?) -> Range<Date>? {
        guard case .dateRange(let start, let end, _)? = filter else { return nil }
        return start..<end
    }

    func read(_ query: String) -> [SearchFilter] {
        NaturalSearch.interpret(query, vocabulary: Self.vocabulary, context: Self.context).filters
    }

    func date(_ query: String) -> (Range<Date>, String)? {
        let words = FuzzyMatch.words(query).isEmpty ? [] : NaturalSearch.tokens(query).map(NaturalSearch.fold)
        guard let match = SearchDates.match(words, at: 0, context: Self.context), match.length == words.count else { return nil }
        return (match.range, match.label)
    }

    @Test func theExampleSentenceBecomesFourChips() {
        let filters = read("videos of Anna at the beach last summer")
        #expect(filters.count == 4)
        #expect(filters[0] == .videos)
        #expect(filters[1] == .person("Anna Schmidt"))
        #expect(filters[2] == .label("beach"))
        #expect(Self.range(filters[3]) == Self.day(2026, 6, 1)..<Self.day(2026, 9, 1))
        #expect(filters[3].label == "Summer 2026")
    }

    @Test func placesYearsFavouritesAndPeople() {
        let lisbon = read("Lisbon 2019")
        #expect(lisbon.first == .place("Lisbon"))
        #expect(Self.range(lisbon.last) == Self.day(2019, 1, 1)..<Self.day(2020, 1, 1))
        #expect(read("favourites of Anna") == [.favorites, .person("Anna Schmidt")])
        #expect(read("photos in new york") == [.place("New York")])
        // Diacritics and possessives do not matter.
        #expect(read("Anna's pictures from Sao Paulo") == [.person("Anna Schmidt"), .place("São Paulo")])
        // A tag, and an album only next to the word "album".
        #expect(read("holiday dogs") == [.tag(id: 7, name: "Holiday"), .label("dog")])
        #expect(read("album road trip") == [.album(id: "own:Road trip", title: "Road trip")])
        #expect(read("summer album") == [.album(id: "own:Summer", title: "Summer")])
    }

    @Test func anAlbumNamedLikeAPlaceDoesNotHideThePlace() {
        let filters = read("Lisbon 2025")
        #expect(filters.first == .place("Lisbon"))
        #expect(filters.last?.label == "2025")
        #expect(read("album lisbon 2025") == [.album(id: "own:Lisbon 2025", title: "Lisbon 2025")])
    }

    @Test func aPersonAfterWithBeatsAMonth() {
        // "Jan" is a person and January: after "with" it is the person.
        #expect(read("with jan") == [.person("Jan")])
        #expect(Self.range(read("jan 2020").first) == Self.day(2020, 1, 1)..<Self.day(2020, 2, 1))
    }

    @Test func ratingsAndMediaKinds() {
        #expect(read("5 stars") == [.rating(atLeast: 5)])
        #expect(read("4+ stars beach") == [.rating(atLeast: 4), .label("beach")])
        #expect(read("★★★") == [.rating(atLeast: 3)])
        #expect(read("rated 2") == [.rating(atLeast: 2)])
        #expect(read("at least 3 stars") == [.rating(atLeast: 3)])
        #expect(read("three-star snow") == [.rating(atLeast: 3), .label("snow")])
        #expect(read("photos only") == [.photos])
        #expect(read("no videos") == [.photos])
        #expect(read("clips with Ben") == [.videos, .person("Ben")])
    }

    @Test func wordsThatAreNotUnderstoodStayFreeText() {
        #expect(read("IMG_1234") == [.text("IMG_1234")])
        #expect(read("Anna birthday cake") == [.person("Anna Schmidt"), .label("cake"), .text("birthday")])
        let plain = NaturalSearch.interpret("vacation", vocabulary: Self.vocabulary, context: Self.context)
        #expect(!plain.isStructured)
        #expect(plain.text == "vacation")
    }

    @Test func datesInManyForms() throws {
        let cases: [(String, Range<Date>)] = [
            ("2019", Self.day(2019, 1, 1)..<Self.day(2020, 1, 1)),
            ("june 2023", Self.day(2023, 6, 1)..<Self.day(2023, 7, 1)),
            ("jun 2023", Self.day(2023, 6, 1)..<Self.day(2023, 7, 1)),
            ("june of 2023", Self.day(2023, 6, 1)..<Self.day(2023, 7, 1)),
            // A month without a year: the last one that has begun.
            ("december", Self.day(2025, 12, 1)..<Self.day(2026, 1, 1)),
            ("march", Self.day(2026, 3, 1)..<Self.day(2026, 4, 1)),
            ("3 march 2021", Self.day(2021, 3, 3)..<Self.day(2021, 3, 4)),
            ("3rd of march 2021", Self.day(2021, 3, 3)..<Self.day(2021, 3, 4)),
            ("march 3rd 2021", Self.day(2021, 3, 3)..<Self.day(2021, 3, 4)),
            ("2021-03-03", Self.day(2021, 3, 3)..<Self.day(2021, 3, 4)),
            ("2021-03", Self.day(2021, 3, 1)..<Self.day(2021, 4, 1)),
            ("summer 2019", Self.day(2019, 6, 1)..<Self.day(2019, 9, 1)),
            ("winter 2019", Self.day(2019, 12, 1)..<Self.day(2020, 3, 1)),
            ("last summer", Self.day(2026, 6, 1)..<Self.day(2026, 9, 1)),
            // Autumn 2026 is not over yet: the last one that is.
            ("last autumn", Self.day(2025, 9, 1)..<Self.day(2025, 12, 1)),
            ("this autumn", Self.day(2026, 9, 1)..<Self.day(2026, 12, 1)),
            ("christmas 2022", Self.day(2022, 12, 24)..<Self.day(2022, 12, 27)),
            ("christmas", Self.day(2025, 12, 24)..<Self.day(2025, 12, 27)),
            ("new year's eve 2020", Self.day(2020, 12, 31)..<Self.day(2021, 1, 1)),
            // Easter 2019 was on 21 April: Good Friday to Easter Monday.
            ("easter 2019", Self.day(2019, 4, 19)..<Self.day(2019, 4, 23)),
            ("halloween", Self.day(2026, 10, 31)..<Self.day(2026, 11, 1)),
            ("90s", Self.day(1990, 1, 1)..<Self.day(2000, 1, 1)),
            ("the 1980s", Self.day(1980, 1, 1)..<Self.day(1990, 1, 1)),
            ("2018-2020", Self.day(2018, 1, 1)..<Self.day(2021, 1, 1)),
            ("2018 to 2020", Self.day(2018, 1, 1)..<Self.day(2021, 1, 1)),
            ("from 2020 to 2018", Self.day(2018, 1, 1)..<Self.day(2021, 1, 1)),
            ("between june 2020 and march 2021", Self.day(2020, 6, 1)..<Self.day(2021, 4, 1)),
            ("today", Self.day(2026, 11, 25)..<Self.day(2026, 11, 26)),
            ("yesterday", Self.day(2026, 11, 24)..<Self.day(2026, 11, 25)),
            ("last month", Self.day(2026, 10, 1)..<Self.day(2026, 11, 1)),
            ("this year", Self.day(2026, 1, 1)..<Self.day(2027, 1, 1)),
            ("last year", Self.day(2025, 1, 1)..<Self.day(2026, 1, 1)),
            ("last june", Self.day(2026, 6, 1)..<Self.day(2026, 7, 1)),
            ("3 years ago", Self.day(2023, 1, 1)..<Self.day(2024, 1, 1)),
            ("two months ago", Self.day(2026, 9, 1)..<Self.day(2026, 10, 1)),
            ("last 10 days", Self.day(2026, 11, 16)..<Self.day(2026, 11, 26)),
            ("recently", Self.day(2026, 10, 26)..<Self.day(2026, 11, 26)),
        ]
        for (text, expected) in cases {
            let found = try #require(date(text.replacingOccurrences(of: "the ", with: "")), "\(text)")
            #expect(found.0 == expected, "\(text)")
        }
        #expect(date("summer 2019")?.1 == "Summer 2019")
        #expect(date("christmas 2022")?.1 == "Christmas 2022")
        // Not dates.
        #expect(date("1234") == nil)
        #expect(date("2031") == nil)
        #expect(date("2021-13-01") == nil)
        #expect(date("31 february 2021") == nil)
    }

    @Test func weeksAndWeekends() throws {
        // Wednesday 25 November 2026; weeks start on Monday in en_GB.
        let lastWeek = try #require(date("last week"))
        #expect(lastWeek.0 == Self.day(2026, 11, 16)..<Self.day(2026, 11, 23))
        let weekend = try #require(date("last weekend"))
        // The last weekend that is over: Saturday 21 and Sunday 22 November.
        #expect(weekend.0.lowerBound == Self.day(2026, 11, 21))
    }

    @Test func seasonsAreTheOtherWayRoundInTheSouth() throws {
        let sydney = SearchDates.Context(now: Self.now, calendar: Self.calendar, locale: Locale(identifier: "en_AU"))
        let match = try #require(SearchDates.match(["summer", "2019"], at: 0, context: sydney))
        #expect(match.range == Self.day(2019, 12, 1)..<Self.day(2020, 3, 1))
    }

    @Test func monthNamesOfTheUsersLanguageToo() throws {
        let german = SearchDates.Context(now: Self.now, calendar: Self.calendar, locale: Locale(identifier: "de_DE"))
        let match = try #require(SearchDates.match(["märz", "2021"], at: 0, context: german))
        #expect(match.range == Self.day(2021, 3, 1)..<Self.day(2021, 4, 1))
        let english = try #require(SearchDates.match(["march", "2021"], at: 0, context: german))
        #expect(english.range == match.range)
    }

    @Test func dateChipsMoveByTheirOwnKindOfPeriod() throws {
        let context = Self.context
        let year = try #require(SearchDates.shifted(Self.day(2019, 1, 1)..<Self.day(2020, 1, 1), label: "2019", by: -1, context: context))
        #expect(Self.range(year) == Self.day(2018, 1, 1)..<Self.day(2019, 1, 1))
        #expect(year.label == "2018")
        let month = try #require(
            SearchDates.shifted(Self.day(2023, 12, 1)..<Self.day(2024, 1, 1), label: "December 2023", by: 1, context: context))
        #expect(Self.range(month) == Self.day(2024, 1, 1)..<Self.day(2024, 2, 1))
        #expect(month.label == "January 2024")
        let summer = try #require(
            SearchDates.shifted(Self.day(2019, 6, 1)..<Self.day(2019, 9, 1), label: "Summer 2019", by: -1, context: context))
        #expect(Self.range(summer) == Self.day(2018, 6, 1)..<Self.day(2018, 9, 1))
        #expect(summer.label == "Summer 2018")
        let week = try #require(
            SearchDates.shifted(Self.day(2026, 11, 16)..<Self.day(2026, 11, 23), label: "Last week", by: -1, context: context))
        #expect(Self.range(week) == Self.day(2026, 11, 9)..<Self.day(2026, 11, 16))
    }

    @Test func theModelAddsWhatTheParserDidNotKnow() {
        let parsed = NaturalSearch.interpret("Anna at the seaside", vocabulary: Self.vocabulary, context: Self.context)
        #expect(parsed.filters == [.person("Anna Schmidt"), .text("seaside")])
        // The model read "seaside" as beach: the free text goes.
        let merged = NaturalSearch.merge(parsed, model: [.person("Anna Schmidt"), .label("beach")])
        #expect(merged.filters == [.person("Anna Schmidt"), .label("beach")])
        // The parser's date stays; the model's other date is not added.
        let dated = NaturalSearch.interpret("Lisbon 2019", vocabulary: Self.vocabulary, context: Self.context)
        let other = SearchFilter.dateRange(start: Self.day(2018, 1, 1), end: Self.day(2019, 1, 1), label: "2018")
        #expect(NaturalSearch.merge(dated, model: [other, .videos]).filters == dated.filters + [.videos])
        // Nothing new: unchanged.
        #expect(NaturalSearch.merge(parsed, model: []).filters == parsed.filters)
    }
}

/// Forgiving matching for the command palette (SPEC §16.2).
@Suite struct FuzzyMatchTests {
    @Test func prefixesTyposAndAbbreviationsMatch() throws {
        let exact = try #require(FuzzyMatch.score("lisbon", name: "Lisbon"))
        let prefix = try #require(FuzzyMatch.score("lis", name: "Lisbon"))
        let typo = try #require(FuzzyMatch.score("lisbn", name: "Lisbon"))
        let swapped = try #require(FuzzyMatch.score("lsibon", name: "Lisbon"))
        let abbreviation = try #require(FuzzyMatch.score("lsbn", name: "Lisbon"))
        #expect(exact > prefix)
        #expect(prefix > typo)
        #expect(typo >= abbreviation)
        #expect(swapped > 0)
        #expect(FuzzyMatch.score("paris", name: "Lisbon") == nil)
        // Case and diacritics.
        #expect(FuzzyMatch.score("SAO", name: "São Paulo") != nil)
        // Every word must match something; keywords count less than the name.
        #expect(FuzzyMatch.score("new alb", name: "New Album…") != nil)
        #expect(FuzzyMatch.score("newal", name: "New Album…") != nil)
        #expect(FuzzyMatch.score("new zebra", name: "New Album…") == nil)
        let keyword = try #require(FuzzyMatch.score("trash", name: "Recently deleted", keywords: ["trash"]))
        #expect(keyword < exact)
    }

    @Test func wordsInTheNamesOrderRankHigher() throws {
        let ordered = try #require(FuzzyMatch.score("summer 2019", name: "Summer 2019"))
        let reversed = try #require(FuzzyMatch.score("2019 summer", name: "Summer 2019"))
        #expect(ordered > reversed)
        let whole = try #require(FuzzyMatch.score("lisbon", name: "Lisbon"))
        let longer = try #require(FuzzyMatch.score("lisbon", name: "Lisbon airport"))
        #expect(whole > longer)
    }
}

/// The command palette's entries and their order (SPEC §16.2).
@Suite struct CommandPaletteTests {
    static func item(_ id: String, _ title: String, _ kind: CommandPalette.Kind, _ action: CommandPalette.Action, keywords: [String] = [])
        -> CommandPalette.Item
    {
        CommandPalette.Item(id: id, title: title, systemImage: "circle", keywords: keywords, kind: kind, action: action)
    }

    static let items: [CommandPalette.Item] = [
        item("go:library", "Library", .destination, .go("library")),
        item("go:settings", "Settings", .destination, .go("settings"), keywords: ["preferences"]),
        item("go:backup", "Backup", .destination, .go("backup"), keywords: ["settings", "upload"]),
        item("album:own:Summer", "Summer", .album, .openAlbum(id: "own:Summer")),
        item("album:own:Summer camp", "Summer camp", .album, .openAlbum(id: "own:Summer camp")),
        item("place:Lisbon", "Lisbon", .place, .openPlace("Lisbon")),
        item("person:Anna", "Anna", .person, .openPerson("Anna")),
        item("command:newAlbum", "New Album…", .command, .command(.newAlbum)),
        item("command:toggleFavorite", "Add to Favorites", .command, .command(.toggleFavorite), keywords: ["favourite"]),
        item("command:delete", "Delete…", .command, .command(.delete)),
    ]

    @Test func theBestMatchComesFirst() {
        let album = Self.item("album:own:Lisbon 2025", "Lisbon 2025", .album, .openAlbum(id: "own:Lisbon 2025"))
        let ranked = CommandPalette.rank("lisbn", items: Self.items + [album], recents: [], hasSelection: false)
        #expect(ranked.prefix(2).map(\.id) == ["place:Lisbon", "album:own:Lisbon 2025"])
        #expect(CommandPalette.rank("new album", items: Self.items, recents: [], hasSelection: false).first?.id == "command:newAlbum")
        // "settings backup": both words match Backup (its keyword and its title), not Settings alone.
        #expect(CommandPalette.rank("settings backup", items: Self.items, recents: [], hasSelection: false).first?.id == "go:backup")
        #expect(
            CommandPalette.rank("summer", items: Self.items, recents: [], hasSelection: false).prefix(2).map(\.id) == [
                "album:own:Summer", "album:own:Summer camp",
            ])
    }

    @Test func selectionCommandsOnlyWithASelection() {
        let without = CommandPalette.rank("fav", items: Self.items, recents: [], hasSelection: false)
        #expect(!without.contains { $0.id == "command:toggleFavorite" })
        let with = CommandPalette.rank("fav", items: Self.items, recents: [], hasSelection: true)
        #expect(with.first?.id == "command:toggleFavorite")
        // Nothing typed: the commands on the selection come first, then the places.
        let start = CommandPalette.rank("", items: Self.items, recents: [], hasSelection: true)
        #expect(start.first?.kind == .command)
        #expect(start.contains { $0.id == "go:library" })
    }

    @Test func recentEntriesComeFirstAndRankHigher() {
        let start = CommandPalette.rank("", items: Self.items, recents: ["person:Anna", "gone"], hasSelection: false)
        #expect(start.first?.id == "person:Anna")
        let typed = CommandPalette.rank("summer", items: Self.items, recents: ["album:own:Summer camp"], hasSelection: false)
        #expect(typed.first?.id == "album:own:Summer camp")
        #expect(CommandPalette.remembering("a", in: ["b", "a", "c"]) == ["a", "b", "c"])
        let many = (0..<20).map(String.init)
        #expect(CommandPalette.remembering("x", in: many).count == CommandPalette.recentLimit)
    }

    @Test func wordsThatSaySeveralThingsBecomeOneSearchOnTop() {
        let year = SearchFilter.dateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), label: "2019")
        let interpretation = NaturalSearch.Interpretation(filters: [.place("Lisbon"), year])
        let ranked = CommandPalette.rank("Lisbon 2019", items: Self.items, recents: [], hasSelection: false, interpretation: interpretation)
        #expect(ranked.first?.action == .search([.place("Lisbon"), year]))
        #expect(ranked.first?.title == "Lisbon · 2019")
        // One chip alone: the entry of the place itself is enough.
        let single = CommandPalette.rank(
            "Lisbon", items: Self.items, recents: [], hasSelection: false,
            interpretation: NaturalSearch.Interpretation(filters: [.place("Lisbon")]))
        #expect(single.first?.id == "place:Lisbon")
    }

    @Test func aNameTypedInFullStaysAboveTheSearch() {
        let album = Self.item("album:own:Lisbon 2025", "Lisbon 2025", .album, .openAlbum(id: "own:Lisbon 2025"))
        let year = SearchFilter.dateRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), label: "2025")
        let ranked = CommandPalette.rank(
            "Lisbon 2025", items: Self.items + [album], recents: [], hasSelection: false,
            interpretation: NaturalSearch.Interpretation(filters: [.place("Lisbon"), year]))
        #expect(ranked.prefix(2).map(\.kind) == [.album, .search])
    }

    @Test func intents() {
        #expect(CommandPalette.intent("add to Summer") == .addToAlbum("summer"))
        #expect(CommandPalette.intent("add to album Road trip") == .addToAlbum("road trip"))
        #expect(CommandPalette.intent("put in summer") == .addToAlbum("summer"))
        #expect(CommandPalette.intent("rate 4") == .rate(4))
        #expect(CommandPalette.intent("3 stars") == .rate(3))
        #expect(CommandPalette.intent("★★") == .rate(2))
        #expect(CommandPalette.intent("new album") == nil)
        #expect(CommandPalette.intent("add to") == nil)
        let targets = CommandPalette.albumTargets("sumer", albums: [("own:Summer", "Summer"), ("own:Winter", "Winter")]) { id, title in
            Self.item("addto:\(id)", "Add to \(title)", .command, .addToAlbum(id: id, title: title))
        }
        #expect(targets.map(\.id) == ["addto:own:Summer"])
        #expect(targets.first?.needsSelection == true)
    }
}

/// Descriptions of photos written from what Vision found (SPEC §16.2).
@Suite struct PhotoDescriptionTests {
    @Test func aSentenceFromLabelsFacesAndText() {
        let dog = PhotoDescription.Facts(labels: [
            ("animal", 0.97), ("dog", 0.93), ("canine", 0.92), ("beach", 0.81), ("sunset_sunrise", 0.7), ("sky", 0.9),
        ])
        #expect(PhotoDescription.compose(dog) == "A dog on a beach at sunset")
        let people = PhotoDescription.Facts(labels: [("snow", 0.8), ("people", 0.9)], faceCount: 2)
        #expect(PhotoDescription.compose(people) == "Two people in the snow")
        let crowd = PhotoDescription.Facts(labels: [("concert", 0.6)], faceCount: 14)
        #expect(PhotoDescription.compose(crowd) == "A group of people at a concert")
        let sign = PhotoDescription.Facts(labels: [], text: ["Happy Birthday"])
        #expect(PhotoDescription.compose(sign) == "Text reading “Happy Birthday”")
        let landscape = PhotoDescription.Facts(labels: [("mountain", 0.9), ("outdoor", 0.95)])
        #expect(PhotoDescription.compose(landscape) == "The mountains")
        // Unsure labels and nothing at all say nothing.
        #expect(PhotoDescription.compose(PhotoDescription.Facts(labels: [("dog", 0.1)])) == nil)
        #expect(PhotoDescription.compose(PhotoDescription.Facts()) == nil)
        #expect(PhotoDescription.compose(PhotoDescription.Facts(labels: [("apple", 0.8)])) == "An apple")
    }

    @Test func modelAnswersAreCleaned() {
        #expect(PhotoDescription.cleaned("\"A cat sleeping on a sofa.\"\n\nAnything else?") == "A cat sleeping on a sofa")
        #expect(PhotoDescription.cleaned("Description: Two children building a sandcastle.") == "Two children building a sandcastle")
        #expect(PhotoDescription.cleaned("I'm sorry, I can't describe this image.") == nil)
        #expect(PhotoDescription.cleaned("  ") == nil)
        let long = String(repeating: "word ", count: 60)
        let cut = PhotoDescription.cleaned(long)
        #expect((cut?.count ?? 0) <= PhotoDescription.maximumLength + 1)
        #expect(cut?.hasSuffix("…") == true)
        #expect(PhotoDescription.searchWords("A dog running on the beach") == ["dog", "running", "beach"])
    }
}
