// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosDomain

/// The links Handoff carries for a memory and for the Library's position (SPEC §22.2).
@Suite struct ContinuityLinkTests {
    private func link(_ string: String) -> DeepLink? { URL(string: string).flatMap(DeepLink.init(url:)) }

    @Test func aMemoryLinkCarriesTheMemoryId() {
        #expect(link("nextcloudphotos://memories/trip-1714000000") == .memory(id: "trip-1714000000"))
        #expect(link("nextcloudphotos://memories/years-3") == .memory(id: "years-3"))
        // Without an id it is still the Memories screen.
        #expect(link("nextcloudphotos://memories") == .destination("memories"))
    }

    @Test func aLibraryLinkWithAFileIdIsThePosition() {
        #expect(link("nextcloudphotos://library/4711") == .library(at: 4711))
        #expect(link("nextcloudphotos://timeline/4711") == .library(at: 4711))
        #expect(link("nextcloudphotos://library") == .destination("library"))
        #expect(link("nextcloudphotos://timeline") == .destination("library"))
        // Not a file id: not a link the app opens.
        #expect(link("nextcloudphotos://library/abc") == nil)
        #expect(link("nextcloudphotos://library/0") == nil)
        #expect(link("nextcloudphotos://library/1/2") == nil)
    }

    @Test func theNewLinksSurviveTheRequestAndTheAccountLink() throws {
        let account = Account(
            serverURL: try #require(URL(string: "https://cloud.example.com/nc")), userId: "alice", loginName: "alice", displayName: "Alice")
        for original in [DeepLink.memory(id: "recap-2024"), .library(at: 42)] {
            #expect(DeepLink(request: original.request) == original)
            let url = try #require(original.url(for: account))
            #expect(IncomingLink.resolve(url, accounts: [account], active: account.id) == .open(original))
        }
        let memory = DeepLink.memory(id: "years-2").url(for: account)?.absoluteString
        #expect(memory == "nextcloudphotos://alice@cloud.example.com/nc/memories/years-2")
        let position = DeepLink.library(at: 42).url(for: account)?.absoluteString
        #expect(position == "nextcloudphotos://alice@cloud.example.com/nc/library/42")
    }
}
