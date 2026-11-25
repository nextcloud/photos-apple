// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore

/// The Library's moments (SPEC §16.1): built off the main actor after each sync from the local index, titled by the rules
/// of `LibraryMoments`, and — where the on-device language model is available — worded more nicely, a few at a time,
/// newest first. Worded titles are kept in the account's database (`MomentTitleStore`) and reused while the moment's
/// facts stay the same.
@MainActor
@Observable
final class LibraryMomentsModel {
    /// The titles the grid's day headers and the days show.
    private(set) var headers = MomentHeaders.none
    @ObservationIgnored private(set) var moments: [LibraryMoment] = []
    @ObservationIgnored private var byId: [String: LibraryMoment] = [:]
    @ObservationIgnored private var ruleHeaders = MomentHeaders.none
    /// Titles of the language model, by moment id.
    @ObservationIgnored private var worded: [String: String] = [:]
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "moments")

    /// Moments worded by the language model after each build, newest first; the others keep their rule titles.
    static let wordedPerBuild = 24

    /// Loaded again when a sync has finished, when the day changes and when moments are switched on.
    struct LoadKey: Hashable {
        var memories: MemoriesStrip.LoadKey
        var excluded: [String]
        var isOn: Bool
    }

    /// Builds the moments of the library and then words the newest titles. Cancelled with the task that runs it.
    func load(_ services: AccountServices, excludedFolders: [String], hiddenPeople: Set<String>) async {
        let started = ContinuousClock.now
        guard let items = try? await services.library.momentItems(excludedFolders: excludedFolders, hiddenPeople: hiddenPeople),
            !Task.isCancelled
        else { return }
        let built = await Task.detached(priority: .utility) { LibraryMoments.build(items) }.value
        guard !Task.isCancelled else { return }
        moments = built
        byId = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ruleHeaders = LibraryMoments.headers(built)
        let titled = built.filter { $0.title != nil }
        let store = MomentTitleStore(database: services.database)
        worded = (try? await store.titles(for: titled.map { ($0.id, $0.facts.key) })) ?? [:]
        headers = ruleHeaders.replacingTitles(worded)
        Self.logger.debug(
            "\(built.count) moments (\(titled.count) titled) of \(items.count) items in \(ContinuousClock.now - started, privacy: .public)")
        await word(titled.prefix(Self.wordedPerBuild).filter { worded[$0.id] == nil }, store: store)
    }

    /// Words the titles of `moments` one after the other with the on-device language model, where there is one.
    private func word(_ moments: [LibraryMoment], store: MomentTitleStore) async {
        guard !moments.isEmpty, MomentTitleWriter.isAvailable else { return }
        let writer = MomentTitleWriter()
        for moment in moments {
            guard !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            let title: String?
            do {
                title = try await writer.title(for: moment.facts)
            } catch {
                Self.logger.debug("wording moment titles stopped: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let title, !Task.isCancelled else { continue }
            worded[moment.id] = title
            headers = ruleHeaders.replacingTitles(worded)
            try? await store.save(id: moment.id, facts: moment.facts.key, title: title)
        }
    }

    func clear() {
        moments = []
        byId = [:]
        ruleHeaders = .none
        worded = [:]
        headers = .none
    }

    /// The moment as a memory: its grid, slideshow and film, "Save as album" and the other memory actions.
    func memory(_ id: String) -> Memory? {
        guard let moment = byId[id] else { return nil }
        return moment.memory(title: title(of: moment))
    }

    func title(of moment: LibraryMoment) -> String {
        worded[moment.id] ?? moment.title?.text() ?? DateRangeLabel.string(from: moment.start, to: moment.end)
    }
}

extension TimelineDisplay {
    /// Moment titles on the Library's day headers (SPEC §16.1). On by default.
    static let showsMomentsKey = "showsMoments"
}
