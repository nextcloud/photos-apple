// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain

/// The camera in search: chips for the camera and lens photos were taken with, typed in words or picked from the
/// suggestions, together with names, dates and places (SPEC §22.3).
@Suite struct CameraSearchTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
    static let context = SearchDates.Context(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    static let vocabulary = NaturalSearch.Vocabulary(
        places: ["Lisbon"], people: ["Anna Schmidt"],
        cameras: ["Fujifilm X100V", "Canon EOS R5", "iPhone 15 Pro", "Sony ILCE-7M4"],
        lenses: ["XF23mmF2 R WR", "RF50mm F1.2 L USM"])

    func read(_ query: String) -> [SearchFilter] {
        NaturalSearch.interpret(query, vocabulary: Self.vocabulary, context: Self.context).filters
    }

    @Test func aCameraByItsFullNameOrItsModel() {
        #expect(read("Fujifilm X100V") == [.camera("Fujifilm X100V")])
        #expect(read("x100v") == [.camera("Fujifilm X100V")])
        #expect(read("eos r5") == [.camera("Canon EOS R5")])
        #expect(read("iphone 15 pro") == [.camera("iPhone 15 Pro")])
    }

    @Test func cameraWithPeopleDatesAndPlaces() throws {
        let filters = read("Anna in Lisbon 2024 shot on x100v")
        #expect(filters.count == 4)
        #expect(filters[0] == .person("Anna Schmidt"))
        #expect(filters[1] == .place("Lisbon"))
        guard case .dateRange(_, _, let label) = filters[2] else {
            Issue.record("no date chip")
            return
        }
        #expect(label == "2024")
        #expect(filters[3] == .camera("Fujifilm X100V"))
        // A lens too.
        #expect(read("photos with the XF23mmF2 R WR") == [.lens("XF23mmF2 R WR")])
    }

    @Test func suggestionsOfferCamerasAndLenses() {
        let vocabulary = SearchSuggestions.Vocabulary(cameras: Self.vocabulary.cameras, lenses: Self.vocabulary.lenses)
        let byMake = SearchSuggestions.suggestions(for: "fuji", vocabulary: vocabulary)
        #expect(byMake.contains(.camera("Fujifilm X100V")))
        let byModel = SearchSuggestions.suggestions(for: "x100", vocabulary: vocabulary)
        #expect(byModel.first == .camera("Fujifilm X100V"))
        let lens = SearchSuggestions.suggestions(for: "rf50", vocabulary: vocabulary)
        #expect(lens.contains(.lens("RF50mm F1.2 L USM")))
        // The free-text entry is always last.
        #expect(lens.last == .text("rf50"))
    }

    @Test func chipsHaveStableIdsAndNames() {
        #expect(SearchFilter.camera("Canon EOS R5").id == "camera:Canon EOS R5")
        #expect(SearchFilter.lens("RF50mm").label == "RF50mm")
        #expect(SearchFilter.camera("Canon EOS R5").isStructured)
    }
}
