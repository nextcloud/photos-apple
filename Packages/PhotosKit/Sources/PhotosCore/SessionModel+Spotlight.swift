// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

// Spotlight and the App Intent entities of the active account (SPEC §7.23).

extension SessionModel {
    /// Called after Spotlight was brought up to date; the app updates the App Shortcuts' album and person parameters.
    public static var collectionsIndexed: @MainActor () -> Void = {}

    /// Brings the account's Spotlight items up to date. Runs after every sync (`afterSync`); Spotlight is only written when
    /// what may be indexed changed, or with `force` (app lock or a hidden person changed).
    public func updateSpotlight(force: Bool = false) async {
        guard let services, !isStopped else { return }
        if AppLockSettings.isEnabled() {
            // Spotlight shows results outside the app, also on the lock screen: nothing while app lock is on.
            if force || spotlightEntries != [] {
                spotlightEntries = []
                Task { await SpotlightIndexer.shared.removeAll() }
            }
            return
        }
        let directory = services.layout.accountDirectory(account.id)
        let entries = await Task.detached(priority: .utility) {
            let library = (try? SpotlightContent.library(services.database, collections: services.collections)) ?? .init()
            return SpotlightContent.entries(library, hiddenPeople: HiddenPeopleFile.names(in: directory), appLockEnabled: false)
        }.value
        guard !isStopped, force || entries != spotlightEntries else { return }
        spotlightEntries = entries
        // Not awaited: Core Spotlight may answer late or not at all (it never does in the iOS test host), and the sync that
        // called this must not wait for it, because logout waits for the session's tasks. The indexer is an actor, so the
        // writes still happen in order.
        let account = account
        Task {
            await SpotlightIndexer.shared.update(account, entries: entries)
            Self.collectionsIndexed()
        }
    }

    /// The albums and named people that Shortcuts and Siri can offer (`AlbumEntity`, `PersonEntity`): the same as Spotlight,
    /// so nothing hidden is offered, and nothing while app lock is on.
    public func intentEntries() async -> [SpotlightEntry] {
        guard let services, !AppLockSettings.isEnabled() else { return [] }
        let directory = services.layout.accountDirectory(account.id)
        return await Task.detached(priority: .userInitiated) {
            let library = (try? SpotlightContent.library(services.database, collections: services.collections)) ?? .init()
            return SpotlightContent.entries(library, hiddenPeople: HiddenPeopleFile.names(in: directory), appLockEnabled: false)
        }.value
    }
}
