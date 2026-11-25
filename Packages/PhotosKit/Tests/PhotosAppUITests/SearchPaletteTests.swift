// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// The command palette's commands and the language model's answers checked against the library (SPEC §16.2).
@Suite @MainActor struct SearchPaletteTests {
    static let vocabulary = NaturalSearch.Vocabulary(places: ["Lisbon", "New York"], people: ["Anna Schmidt", "Ben"])

    static func grid(selected: Int, cull: Bool = true) -> GridActions {
        var actions = GridActions(
            selectionCount: selected, allFavorite: false, toggleFavorite: {}, delete: {}, toggleInfo: {}, addToAlbum: {}, zoomIn: nil,
            zoomOut: nil)
        if cull { actions.cull = { _ in } }
        actions.slideshow = {}
        actions.addToRecentAlbum = { _ in }
        return actions
    }

    static let main = MainActions(
        available: [.library, .albums], go: { _ in }, focusSearch: {}, newAlbum: {}, upload: {}, openPublicLink: {}, syncNow: {})

    @Test func modelAnswersKeepOnlyWhatTheLibraryKnows() throws {
        let filters = NaturalSearchModel.validated(
            mediaType: "Videos", people: ["anna schmidt", "Zoe"], places: ["lisbon", "Atlantis"],
            things: ["beach", "a dog running", "Anna Schmidt"],
            start: "2026-06-01", end: "2026-08-31", favorites: true, rating: 9, vocabulary: Self.vocabulary)
        #expect(filters.contains(.videos))
        #expect(filters.contains(.person("Anna Schmidt")))
        #expect(!filters.contains(.person("Zoe")))
        #expect(filters.contains(.place("Lisbon")))
        #expect(!filters.contains(.place("Atlantis")))
        #expect(filters.contains(.label("beach")))
        // A sentence, or a name already understood, is not a thing photos show.
        #expect(!filters.contains { if case .label(let word) = $0 { word != "beach" } else { false } })
        #expect(filters.contains(.favorites))
        #expect(!filters.contains { if case .rating = $0 { true } else { false } })
        let date = try #require(
            filters.first { if case .dateRange = $0 { true } else { false } })
        guard case .dateRange(let start, let end, _) = date else { return }
        let calendar = Calendar.current
        #expect(start == calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        #expect(end == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        // Dates that are not dates are left out.
        let none = NaturalSearchModel.validated(
            mediaType: "any", people: [], places: [], things: [], start: "summer", end: "", favorites: false, rating: 0,
            vocabulary: Self.vocabulary)
        #expect(none.isEmpty)
    }

    @Test func selectionCommandsNeedASelection() {
        let none = PaletteCommands.items(main: Self.main, grid: Self.grid(selected: 0))
        #expect(none.contains { $0.action == .command(.newAlbum) })
        #expect(none.contains { $0.action == .command(.slideshow) })
        #expect(!none.contains { $0.action == .command(.toggleFavorite) })
        let some = PaletteCommands.items(main: Self.main, grid: Self.grid(selected: 3))
        #expect(some.contains { $0.action == .command(.toggleFavorite) })
        #expect(some.contains { $0.action == .command(.pick) })
        #expect(some.first { $0.action == .command(.delete) }?.subtitle == PaletteWording.selection(Self.grid(selected: 3)))
        // Without rating rights (a shared photo): no flags.
        let readOnly = PaletteCommands.items(main: Self.main, grid: Self.grid(selected: 1, cull: false))
        #expect(!readOnly.contains { $0.action == .command(.pick) })
    }

    @Test func typedIntentsAddToAnAlbumOrRate() {
        let albums = [
            Album(kind: .own, name: "Summer", title: "Summer"), Album(kind: .own, name: "Winter", title: "Winter"),
        ]
        let add = PaletteCommands.intentItems("add to summ", albums: albums, grid: Self.grid(selected: 2))
        #expect(add.map(\.action) == [.addToAlbum(id: "own:Summer", title: "Summer")])
        #expect(PaletteCommands.intentItems("add to summ", albums: albums, grid: Self.grid(selected: 0)).isEmpty)
        #expect(PaletteCommands.intentItems("4 stars", albums: albums, grid: Self.grid(selected: 1)).map(\.action) == [.rate(4)])
        #expect(PaletteCommands.intentItems("4 stars", albums: albums, grid: Self.grid(selected: 1, cull: false)).isEmpty)
    }

    @Test func recentEntriesArePerAccount() throws {
        let layout = StorageLayout(container: FileManager.default.temporaryDirectory.appending(path: "palette-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: layout.container) }
        let alice = AccountID(rawValue: "alice@cloud.example.com")
        PaletteRecents.save(["album:own:Summer", "go:library"], account: alice, layout: layout)
        #expect(PaletteRecents.load(account: alice, layout: layout) == ["album:own:Summer", "go:library"])
        #expect(PaletteRecents.load(account: AccountID(rawValue: "bob@cloud.example.com"), layout: layout).isEmpty)
    }

    @Test func newChipsSurviveRecentSearches() {
        var recents = RecentSearches()
        recents.add([.photos, .label("beach"), .rating(atLeast: 4)])
        let restored = RecentSearches(data: recents.data)
        #expect(restored.entries == [[.photos, .label("beach"), .rating(atLeast: 4)]])
    }

    @Test func destinationsHaveWordsPeopleUse() {
        let items = PaletteDestinations.items(available: [.library, .recentlyDeleted, .search, .collections])
        #expect(items.contains { $0.action == .go("recentlyDeleted") && $0.keywords.contains("trash") })
        #expect(!items.contains { $0.action == .go("search") || $0.action == .go("collections") })
    }
}
