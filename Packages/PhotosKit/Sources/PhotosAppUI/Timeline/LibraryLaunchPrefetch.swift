// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import Synchronization

/// The Library's first items and its memories strip, read while the window builds its first screen (SPEC §10, §20.6).
///
/// Without it the Library asked the store only from its `.task`s, which run after the window's whole first update and
/// layout: the first frame had no photos, and the grid, then the memories strip arrived in further full updates (in the
/// simulator the pictures waited a second behind the strip's first layout). The reads start when the root view is first
/// built and run off the main thread; the Library takes the results when it appears, if they are for the same account
/// and the same query, so its first frame already has the grid and the strip. The live observation and the strip's own
/// load start as before and replace them (unchanged results change nothing on screen).
///
/// The results are kept behind a lock, not on the main actor: the main actor is busy with that first update, and the
/// Library must be able to take them before it is free again.
final class LibraryLaunchPrefetch: Sendable {
    /// What the grid read was made for: the Library takes the result only for exactly this query.
    struct Key: Equatable, Sendable {
        var account: String
        var excludedFolders: [String]
        var stacksCopies: Bool
    }

    private struct State {
        var started = false
        var key: Key?
        var model: GridModel?
        var memories: [Memory]?
        /// Taken (or given up): a result that comes later is not kept.
        var tookModel = false
        var tookMemories = false
    }

    static let shared = LibraryLaunchPrefetch()

    /// An unused result is dropped after this long (the window may show another place than the Library).
    let lifetime: Duration
    private let state = Mutex(State())
    private let reads = Mutex<[Task<Void, Never>]>([])

    init(lifetime: Duration = .seconds(30)) {
        self.lifetime = lifetime
    }

    /// Starts the reads once per process, for the session's account. Cheap to call again.
    @MainActor
    func start(_ session: SessionModel?) {
        guard let session, let services = session.services, !state.withLock({ $0.started }) else { return }
        let key = Key(
            account: session.account.id.rawValue, excludedFolders: TimelineScreen.excludedFolders(session),
            stacksCopies: UserDefaults.standard.object(forKey: TimelineDisplay.stackCopiesKey) as? Bool ?? true)
        let library = services.library
        let showsMemories = UserDefaults.standard.object(forKey: TimelineDisplay.showsMemoriesKey) as? Bool ?? true
        let items: @Sendable () async throws -> [GridMedia] = {
            try await library.fetchGridItems(.all, excludedFolders: key.excludedFolders)
        }
        let memories: @Sendable () async -> [Memory] = { await Self.memoryCards(services) }
        start(key, items: items, memories: showsMemories ? memories : nil)
    }

    /// The memories strip's cards, as `MemoriesStrip.load` makes them, without the main actor.
    private static func memoryCards(_ services: AccountServices) async -> [Memory] {
        let snapshot: MemoriesSnapshot = (try? await services.library.memories()) ?? MemoriesSnapshot()
        let cards: [Memory] = MemoriesStrip.cards(snapshot)
        // As the strip's own load does: memory covers rank higher for the caches (SPEC §18.2).
        await services.noteCacheRole(.memoryCover, fileIds: Set(cards.map(\.cover)))
        return cards
    }

    /// Starts reading with `items` (and `memories`) for `key`, once per instance.
    func start(
        _ key: Key, items: @escaping @Sendable () async throws -> [GridMedia],
        memories: (@Sendable () async -> [Memory])? = nil
    ) {
        let isFirst: Bool = state.withLock { state in
            guard !state.started else { return false }
            state.started = true
            state.key = key
            return true
        }
        guard isFirst else { return }
        let gridRead = Task.detached(priority: .userInitiated) { [self] in
            guard let items = try? await items(), !items.isEmpty else { return }
            let tiles = key.stacksCopies ? TimelineStacking.collapse(items) : items
            let model = GridModel(items: tiles, sectioning: GridFeed.librarySectioning)
            state.withLock { state in
                if !state.tookModel { state.model = model }
            }
        }
        var started = [gridRead]
        if let memories {
            started.append(
                Task.detached(priority: .userInitiated) { [self] in
                    let cards = await memories()
                    state.withLock { state in
                        if !state.tookMemories { state.memories = cards }
                    }
                })
        }
        let all = started
        reads.withLock { $0 = all }
        // Nothing unused stays in memory.
        let lifetime = lifetime
        Task.detached(priority: .utility) { [self] in
            for read in all { await read.value }
            try? await Task.sleep(for: lifetime)
            state.withLock { state in
                state.model = nil
                state.memories = nil
            }
        }
    }

    /// Waits until the reads have finished (tests).
    func readsFinished() async {
        for read in reads.withLock({ $0 }) { await read.value }
    }

    /// The prefetched grid model if it is ready and for `key`. Handed out once: after the first call nothing is handed
    /// out (a later Library observes the store as before).
    func take(_ key: Key) -> GridModel? {
        state.withLock { state in
            defer {
                state.model = nil
                state.tookModel = true
            }
            guard state.key == key else { return nil }
            return state.model
        }
    }

    /// What is stored now, without taking it (tests).
    func peekModel() -> GridModel? { state.withLock { $0.model } }
    func peekMemories() -> [Memory]? { state.withLock { $0.memories } }

    /// The prefetched memories strip if it is ready and for `account`; handed out once, like `take(_:)`.
    func takeMemories(account: String) -> [Memory]? {
        state.withLock { state in
            defer {
                state.memories = nil
                state.tookMemories = true
            }
            guard state.key?.account == account else { return nil }
            return state.memories
        }
    }
}
