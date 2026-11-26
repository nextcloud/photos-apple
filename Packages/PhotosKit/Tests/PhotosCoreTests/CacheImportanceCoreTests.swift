// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// What the viewer and the Library tell the caches (SPEC §18.2).
@Suite(.timeLimit(.minutes(1))) struct CacheImportanceCoreTests {
    let sandbox = Sandbox()
    let server = StubServer()

    func makeServices() throws -> AccountServices {
        try AccountServices(
            account: makeAccount("alice", server: server.url.absoluteString), appPassword: "password", http: server.http(),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "tests", layout: sandbox.layout,
            onUnauthorized: {})
    }

    @Test func aPhotoShownForASecondIsViewedAndStaysInFocusUntilTheViewerMovesOn() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let store = CacheImportanceStore(database: services.database)
        // Paged on after a moment: focus moved, no view.
        let quick = Task { await services.viewerShows(1, neighbours: [2]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(services.images.cache.memory.focus == .init(current: 1, neighbours: [2]))
        quick.cancel()
        await quick.value
        #expect(services.images.cache.memory.focus == .init())
        #expect(try store.recentlyViewed().isEmpty)
        // Looked at: remembered after a second, focus kept while it is shown.
        let looked = Task { await services.viewerShows(2, neighbours: [1, 3]) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(try store.recentlyViewed().map(\.fileId) == [2])
        #expect(services.images.cache.memory.focus.current == 2)
        looked.cancel()
        await looked.value
        #expect(services.images.cache.memory.focus.current == nil)
    }

    @Test func theEvictionContextFollowsTheWholeLibrarySetting() async throws {
        defer { sandbox.remove() }
        let services = try makeServices()
        let now = Date()
        try services.library.upsert([
            MediaItem(
                fileId: 7, path: "/Photos/a.jpg", mimeType: "image/jpeg", size: 1, etag: "abc", modifiedAt: now, capturedAt: now,
                width: 1, height: 1)
        ])
        await services.noteCacheRole(.memoryCover, fileIds: [7, 8])
        let defaults = UserDefaults(suiteName: "evict-\(UUID().uuidString)")!
        // Off (unset is the platform's default, on on the Mac; SPEC §18.3.1).
        defaults.set(false, forKey: CacheLimits.wholeLibraryThumbnailsKey)
        var context = AccountServices.evictionContext(services.database, defaults: defaults)
        #expect(context.libraryEtags == nil)
        #expect(context.prominent == [7, 8])
        #expect(context.tiers[7] == 4)  // taken today
        #expect(context.tiers[8] == 3)  // a memory cover
        defaults.set(true, forKey: CacheLimits.wholeLibraryThumbnailsKey)
        context = AccountServices.evictionContext(services.database, defaults: defaults)
        #expect(context.libraryEtags == [7: "abc"])
    }
}
