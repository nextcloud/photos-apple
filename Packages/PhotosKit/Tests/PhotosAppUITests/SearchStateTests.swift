// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// Recent searches (the last eight per account) and what Return searches for.
@Suite struct RecentSearchesTests {
    static let june = SearchFilter.dateRange(
        start: Date(timeIntervalSince1970: 1_685_577_600), end: Date(timeIntervalSince1970: 1_688_169_600), label: "June 2023")

    @Test func theNewestSearchIsOnTopAndOnlyEightAreKept() {
        var recents = RecentSearches()
        for index in 1...10 { recents.add([.text("search \(index)")]) }
        #expect(recents.entries.count == RecentSearches.limit)
        #expect(recents.entries.first == [.text("search 10")])
        #expect(recents.entries.last == [.text("search 3")])
        recents.add([])
        #expect(recents.entries.count == 8)
    }

    @Test func searchingAgainMovesTheSearchUpInsteadOfRepeatingIt() {
        var recents = RecentSearches()
        recents.add([.place("Berlin"), .favorites])
        recents.add([.videos])
        // The same filters in another order are the same search.
        recents.add([.favorites, .place("Berlin")])
        #expect(recents.entries == [[.favorites, .place("Berlin")], [.videos]])
        recents.remove([.place("Berlin"), .favorites])
        #expect(recents.entries == [[.videos]])
        recents.clear()
        #expect(recents.isEmpty)
    }

    @Test func everyKindOfFilterSurvivesStorage() {
        var recents = RecentSearches()
        recents.add([.place("Berlin"), .person("Ada"), .tag(id: 7, name: "holiday")])
        recents.add([.album(id: "own:Trip", title: "Trip"), Self.june, .text("img_12"), .favorites, .videos])
        let restored = RecentSearches(data: recents.data)
        #expect(restored == recents)
        #expect(RecentSearches.title(restored.entries[1]) == "Berlin, Ada, holiday")
        // Damaged or unknown content gives an empty list, not a crash or half a search.
        #expect(RecentSearches(data: Data("nonsense".utf8)).isEmpty)
        let newer = Data(#"[[{"kind":"text","text":"a"},{"kind":"colour","text":"red"}],[{"kind":"videos"}]]"#.utf8)
        #expect(RecentSearches(data: newer).entries == [[.videos]])
    }

    @Test func searchesAreKeptPerAccountInItsDirectory() throws {
        let layout = StorageLayout(container: FileManager.default.temporaryDirectory.appending(path: "recents-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: layout.container) }
        let alice = AccountID(rawValue: "alice@cloud.example.com")
        let bob = AccountID(rawValue: "bob@cloud.example.com")
        var recents = RecentSearches()
        recents.add([.place("Berlin")])
        recents.save(account: alice, layout: layout)
        #expect(RecentSearches.load(account: alice, layout: layout) == recents)
        #expect(RecentSearches.load(account: bob, layout: layout).isEmpty)
        // In the directory that is deleted with the account.
        #expect(RecentSearches.file(account: alice, layout: layout).path.hasPrefix(layout.accountDirectory(alice).path))
        // Clearing removes the file.
        recents.clear()
        recents.save(account: alice, layout: layout)
        #expect(!FileManager.default.fileExists(atPath: RecentSearches.file(account: alice, layout: layout).path))
    }

    @Test func returnTakesTheTopSuggestionOrSearchesTheText() {
        let vocabulary = SearchSuggestions.Vocabulary(places: ["Berlin", "Bern"])
        let suggestions = SearchSuggestions.suggestions(for: "ber", vocabulary: vocabulary)
        #expect(SearchCommit.filter(for: "ber", suggestions: suggestions, active: []) == .place("Berlin"))
        // A suggestion that is a filter already is skipped.
        #expect(SearchCommit.filter(for: "ber", suggestions: suggestions, active: [.place("Berlin")]) == .place("Bern"))
        // Nothing known matches: free text, trimmed.
        #expect(SearchCommit.filter(for: "  img_12 ", suggestions: [], active: []) == .text("img_12"))
        #expect(SearchCommit.filter(for: "img_12", suggestions: [.text("img_12")], active: [.text("img_12")]) == nil)
        #expect(SearchCommit.filter(for: "   ", suggestions: [], active: []) == nil)
    }
}

/// The banner over a grid: which of the account's problems it names.
@Suite struct GridBannerTests {
    func banner(
        signedOut: Bool = false, certificate: String? = nil, failed: Int = 0, status: SyncStatus = .idle(lastSync: Date()),
        hasItems: Bool = true
    ) -> GridBanner? {
        GridBanner.resolve(isSignedOut: signedOut, certificateHost: certificate, failedChanges: failed, status: status, hasItems: hasItems)
    }

    @Test func aFailedSyncAndARevokedLoginShowOverACachedLibrary() {
        #expect(banner() == nil)
        #expect(
            banner(status: .failed(message: "The server is in maintenance mode.", lastSync: nil))
                == .syncFailed(message: "The server is in maintenance mode."))
        #expect(banner(signedOut: true, status: .failed(message: "x", lastSync: nil)) == .signedOut)
        #expect(banner(status: .offline(lastSync: nil)) == .offline)
        #expect(banner(status: .initialSync(itemsFetched: 40)) == .loading(40))
        #expect(banner(status: .syncing) == nil)
    }

    @Test func theMostUrgentProblemIsNamed() {
        let failed = SyncStatus.failed(message: "The certificate of cloud.example.com is not trusted.", lastSync: nil)
        #expect(banner(certificate: "cloud.example.com", failed: 2, status: failed) == .certificateChanged(host: "cloud.example.com"))
        #expect(banner(signedOut: true, certificate: "cloud.example.com", failed: 2, status: failed) == .signedOut)
        #expect(banner(failed: 2, status: failed) == .failedChanges(2))
    }

    @Test func anEmptyGridSaysItInItsEmptyState() {
        #expect(banner(signedOut: true, hasItems: false) == nil)
        #expect(banner(status: .failed(message: "x", lastSync: nil), hasItems: false) == nil)
        #expect(banner(status: .initialSync(itemsFetched: 0), hasItems: false) == nil)
        // These are not said anywhere else.
        #expect(banner(certificate: "h", hasItems: false) == .certificateChanged(host: "h"))
        #expect(banner(status: .offline(lastSync: nil), hasItems: false) == .offline)
    }

    @Test func theConfirmationNamesTheChange() {
        let items = [
            MediaItem(fileId: 1, path: "/a.jpg", mimeType: "image/jpeg"), MediaItem(fileId: 2, path: "/b.jpg", mimeType: "image/jpeg"),
        ]
        var notice = ChangeNotice(change: .archive(items), canUndo: true)
        #expect(ChangeNoticeText.text(notice, trashbin: true).contains("2"))
        let deleted = ChangeNotice(change: .delete(items), canUndo: true)
        #expect(ChangeNoticeText.text(deleted, trashbin: true) != ChangeNoticeText.text(deleted, trashbin: false))
        notice.isReverted = true
        #expect(
            ChangeNoticeText.text(notice, trashbin: true)
                != ChangeNoticeText.text(ChangeNotice(change: .archive(items), canUndo: true), trashbin: true))
    }

    @Test func onlyLoginLinksAreTakenFromAQRCode() {
        #expect(LoginQRCode.loginLink(in: " nc://login/server:https://cloud.example.com&user:alice&password:secret\n") != nil)
        #expect(LoginQRCode.loginLink(in: "https://example.com") == nil)
        #expect(LoginQRCode.loginLink(in: "WIFI:S:home;T:WPA;P:secret;;") == nil)
    }
}
