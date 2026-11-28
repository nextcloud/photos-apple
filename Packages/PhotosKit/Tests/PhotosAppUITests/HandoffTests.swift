// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI

/// Handoff between the user's devices (SPEC §22.2): what a window advertises, what the other device does with it.
@Suite struct HandoffTests {
    let alice = Account(
        serverURL: URL(string: "https://cloud.example.com")!, userId: "alice", loginName: "alice@example.com", displayName: "Alice")
    let bob = Account(serverURL: URL(string: "https://cloud.example.com")!, userId: "bob", loginName: "bob", displayName: "Bob")
    let carol = Account(
        serverURL: URL(string: "http://nas.local:8080/nextcloud")!, userId: "carol", loginName: "carol", displayName: "Carol")

    @Test func thePayloadIsTheAccountLinkAndAVersion() throws {
        let info = try #require(HandoffActivity.userInfo(for: HandoffContent(.album(id: "own:Lisbon 2025")), account: alice))
        #expect(info[HandoffActivity.linkKey] as? String == "nextcloudphotos://alice@cloud.example.com/albums/Lisbon%202025")
        #expect(info[HandoffActivity.versionKey] as? Int == HandoffActivity.version)
        // Nothing else: no names, no secrets.
        #expect(info.count == 2)
        #expect(HandoffActivity.link(in: info)?.absoluteString == info[HandoffActivity.linkKey] as? String)
    }

    @Test func onlyAccountLinksOfTheAppAreTakenFromAnActivity() {
        #expect(HandoffActivity.link(in: nil) == nil)
        #expect(HandoffActivity.link(in: [HandoffActivity.linkKey: "https://cloud.example.com/apps/photos"]) == nil)
        // A link without an account would open in whatever account the other device shows.
        #expect(HandoffActivity.link(in: [HandoffActivity.linkKey: "nextcloudphotos://albums/Trip"]) == nil)
        #expect(HandoffActivity.link(in: [HandoffActivity.linkKey: 42]) == nil)
        #expect(HandoffActivity.link(in: [HandoffActivity.linkKey: "nextcloudphotos://alice@cloud.example.com/photo/7"]) != nil)
    }

    @Test func theSameAccountOpensAtOnceAnotherLoggedInOneThroughTheLinkQuestion() throws {
        let link = try #require(DeepLink.photo(fileId: 7).url(for: alice))
        #expect(HandoffArrival.resolve(link: link, webpage: nil, accounts: [alice, bob], active: alice.id) == .open(link))
        // Alice is logged in here but Bob is shown: `AppModel.open` asks before it switches (`LinkPrompt.switchAccount`).
        #expect(HandoffArrival.resolve(link: link, webpage: nil, accounts: [alice, bob], active: bob.id) == .open(link))
        #expect(IncomingLink.resolve(link, accounts: [alice, bob], active: bob.id) == .switchAccount([alice.id], .photo(fileId: 7)))
    }

    @Test func anAccountThatIsNotHereOffersTheWebPage() throws {
        let link = try #require(DeepLink.album(id: "own:Trip").url(for: alice))
        let web = HandoffActivity.webpageURL(for: .album(id: "own:Trip"), serverURL: alice.serverURL)
        #expect(
            HandoffArrival.resolve(link: link, webpage: web, accounts: [bob], active: bob.id)
                == .otherAccount(name: "alice@cloud.example.com", webpage: web))
        // No account at all on this device (the login screen): the same.
        #expect(
            HandoffArrival.resolve(link: link, webpage: web, accounts: [], active: nil)
                == .otherAccount(name: "alice@cloud.example.com", webpage: web))
        // A web page that is not http(s) is not offered.
        let other = try #require(URL(string: "file:///etc/hosts"))
        #expect(
            HandoffArrival.resolve(link: link, webpage: other, accounts: [], active: nil)
                == .otherAccount(name: "alice@cloud.example.com", webpage: nil))
        #expect(HandoffArrival.resolve(link: nil, webpage: web, accounts: [alice], active: alice.id) == .ignore)
    }

    @Test func theWebPageIsTheSamePlaceInTheWebApp() {
        func web(_ link: DeepLink, _ account: Account? = nil) -> String? {
            HandoffActivity.webpageURL(for: link, serverURL: (account ?? alice).serverURL)?.absoluteString
        }
        #expect(web(.album(id: "own:Lisbon 2025")) == "https://cloud.example.com/index.php/apps/photos/albums/Lisbon%202025")
        #expect(web(.album(id: "shared:Trip (bob)")) == "https://cloud.example.com/index.php/apps/photos/sharedalbums/Trip%20(bob)")
        #expect(web(.photo(fileId: 4711)) == "https://cloud.example.com/index.php/f/4711")
        #expect(web(.place(name: "Lisbon")) == "https://cloud.example.com/index.php/apps/photos/places/Lisbon")
        #expect(web(.person(name: "Anna")) == "https://cloud.example.com/index.php/apps/photos/faces/Anna")
        #expect(web(.folder(path: "/Photos/2024")) == "https://cloud.example.com/index.php/apps/photos/folders/Photos/2024")
        #expect(web(.memory(id: "years-3")) == "https://cloud.example.com/index.php/apps/photos/thisday")
        #expect(web(.memory(id: "trip-1714000000")) == "https://cloud.example.com/index.php/apps/photos/")
        #expect(web(.library(at: 42)) == "https://cloud.example.com/index.php/apps/photos/")
        #expect(web(.destination("sharedAlbums")) == "https://cloud.example.com/index.php/apps/photos/sharedalbums")
        #expect(web(.destination("onThisDay")) == "https://cloud.example.com/index.php/apps/photos/thisday")
        // Screens the web app does not have open its start page.
        #expect(web(.destination("cleanUp")) == "https://cloud.example.com/index.php/apps/photos/")
        // A server in a sub-folder, on http with a port.
        #expect(web(.album(id: "own:A/B"), carol) == "http://nas.local:8080/nextcloud/index.php/apps/photos/albums/A%2FB")
    }

    @MainActor @Test func theScreenThatAppearedLastIsAdvertised() {
        let registry = HandoffRegistry()
        let albums = UUID()
        let album = UUID()
        let viewer = UUID()
        #expect(registry.current == nil)
        registry.register(albums, HandoffContent(.destination("albums")))
        registry.register(album, HandoffContent(.album(id: "own:Trip")))
        #expect(registry.current?.link == .album(id: "own:Trip"))
        registry.register(viewer, HandoffContent(.photo(fileId: 1)))
        // Paging in the viewer keeps it on top.
        registry.update(viewer, HandoffContent(.photo(fileId: 2)))
        #expect(registry.current?.link == .photo(fileId: 2))
        // The album under it changing does not take the place of the viewer.
        registry.update(album, HandoffContent(.album(id: "own:Trip 2")))
        #expect(registry.current?.link == .photo(fileId: 2))
        // Closing the viewer brings back the album.
        registry.remove(viewer)
        #expect(registry.current?.link == .album(id: "own:Trip 2"))
        // A screen with nothing to advertise any more steps back.
        registry.update(album, nil)
        #expect(registry.current?.link == .destination("albums"))
        // Coming back to the list makes it the newest again.
        registry.register(album, HandoffContent(.album(id: "own:Trip")))
        registry.register(albums, HandoffContent(.destination("albums")))
        #expect(registry.current?.link == .destination("albums"))
    }

    @Test func aDestinationAdvertisesItselfExceptThoseOfThisDevice() {
        #expect(DestinationView.handoffLink(.albums) == .destination("albums"))
        #expect(DestinationView.handoffLink(.cleanUp) == .destination("cleanUp"))
        // The Library advertises its position itself; search, Settings and Backup are of this device.
        for destination: AppDestination in [.library, .favorites, .search, .settings, .backup, .collections] {
            #expect(DestinationView.handoffLink(destination) == nil)
        }
    }

    @Test func aMemoryIsFoundByItsIdInTheDevicesMemories() throws {
        // Memories are made from the library: one trip of eight photos two days apart from everything else.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<8).map { MemoryItem(fileId: FileID($0 + 1), timestamp: start.addingTimeInterval(Double($0) * 600)) }
        let trip = try #require(Memories.trips(items).first)
        func memory(_ id: String) -> Memory {
            var copy = trip
            copy.id = id
            return copy
        }
        let snapshot = MemoriesSnapshot(onThisDay: [memory("years-2")], trips: [memory("trip-1")], recap: memory("recap-2024"))
        #expect(MemoryRouteScreen.memory("trip-1", in: snapshot)?.id == "trip-1")
        #expect(MemoryRouteScreen.memory("recap-2024", in: snapshot)?.id == "recap-2024")
        #expect(MemoryRouteScreen.memory("years-2", in: snapshot)?.id == "years-2")
        #expect(MemoryRouteScreen.memory("trip-9", in: snapshot) == nil)
    }
}
