// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// "Show Similar" (SPEC §15.5): the photos that look like one photo, most alike first, worked out on this device from
/// Vision feature prints (`SimilarityIndex`). When the photo was taken in a series (a burst, several tries at one scene),
/// the best shot of that series is suggested, and the others can be deleted in one go.
enum SimilarPhotosAction {
    static var title: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show Similar", bundle: .module, comment: "Menu: photos that look like this one."),
            other: LocalizedStringResource("Show similar", bundle: .module, comment: "Menu: photos that look like this one."))
    }

    static let systemImage = "sparkle.magnifyingglass"

    /// Offered for photos (not videos) while the feature is on.
    static func isOffered(for kind: MediaKind) -> Bool {
        kind == .image && SimilarIndexing.isEnabled()
    }
}

/// What a search from one photo found.
struct SimilarPhotosResult: Sendable {
    /// The photo itself first, then the others, most alike first.
    var items: [GridMedia]
    /// The shots of the photo's moment (time order), when there are several.
    var moment: [FileID]
    /// The best of `moment`, and why (SPEC §21.4).
    var best: FileID?
    var reasons: [BestShot.Reason] = []
    /// Shots of `moment` analysed for the best shot so far.
    var analysed = 0
    /// Images indexed so far, and all images: the search covers the indexed ones.
    var indexed: Int
    var total: Int

    var isComplete: Bool { indexed >= total }
}

@MainActor
@Observable
final class SimilarPhotosModel {
    enum Phase {
        case searching
        case found(SimilarPhotosResult)
        /// The photo could not be analysed (no preview, offline and not cached).
        case unavailable
    }

    private(set) var phase = Phase.searching

    /// Searches, and searches again every few seconds while the library is still being indexed (results grow).
    func run(item: MediaItem, services: AccountServices) async {
        while !Task.isCancelled {
            guard let result = await Self.search(item: item, services: services) else {
                phase = .unavailable
                return
            }
            phase = .found(result)
            // The shots of the moment are analysed for the best shot (their 1024 px previews, loaded if needed), then
            // the suggestion is worked out again.
            if result.moment.count > 1, result.analysed < result.moment.count {
                let analysed = await BestShotService(services: services).signals(of: result.moment, fetch: true)
                if analysed.count > result.analysed { continue }
            }
            guard !result.isComplete else { return }
            // The user is waiting for this: the cached previews not compared yet are indexed now, a few seconds at a time
            // (unless the device is in Low Power Mode, warm, or low on battery), and the search runs again on what grew.
            if SimilarIndexing.Conditions.current.allowsForegroundWork {
                let indexer = SimilarityIndexer(database: services.database, cache: services.images.cache, index: services.similarity)
                let deadline = ContinuousClock.now + .seconds(4)
                let indexed = await Task.detached(priority: .utility) {
                    (try? await indexer.run(batchSize: 24) { ContinuousClock.now < deadline }) ?? 0
                }.value
                if indexed > 0 { continue }
            }
            try? await Task.sleep(for: .seconds(6))
        }
    }

    /// Searches once more (after the other shots were deleted).
    func refresh(item: MediaItem, services: AccountServices) async {
        if let result = await Self.search(item: item, services: services) { phase = .found(result) }
    }

    nonisolated static func search(item: MediaItem, services: AccountServices) async -> SimilarPhotosResult? {
        let index = services.similarity
        try? await index.refresh()
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: 256, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.connection.originalURL(path: item.path))
        let images = services.images
        guard
            let print = try? await index.featurePrint(
                of: .init(fileId: item.fileId, etag: item.etag), image: { await images.preview(request) }),
            let matches = try? await index.similar(to: print, excluding: item.fileId)
        else { return nil }
        let ids = matches.map(\.fileId)
        let fetched = (try? await services.library.fetchItems(ids)) ?? [:]
        let similarity = Dictionary(matches.map { ($0.fileId, $0.similarity) }, uniquingKeysWith: { first, _ in first })
        let found = ids.compactMap { fetched[$0] }
        let moment = SimilarSeries.moment(
            of: (item.fileId, item.timestamp), in: found.map { ($0.fileId, $0.timestamp, similarity[$0.fileId] ?? 0) })
        var choice: BestShot.Choice?
        var analysed = 0
        if moment.count > 1 {
            // What was analysed so far; `run` analyses the rest and asks again.
            let signals = (try? BestShotStore(database: services.database).signals(of: moment)) ?? [:]
            analysed = signals.count
            let byId = Dictionary((found + [item]).map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            choice = BestShotService(services: services).choose(moment.compactMap { byId[$0] }, signals: signals)
        }
        let progress = (try? SimilarityStore(database: services.database).progress()) ?? (indexed: 0, total: 0)
        return SimilarPhotosResult(
            items: [GridMedia(item)] + found.map(GridMedia.init), moment: moment.count > 1 ? moment : [], best: choice?.best,
            reasons: choice?.reasons ?? [], analysed: analysed, indexed: progress.indexed, total: progress.total)
    }
}

extension View {
    /// Presents "Show Similar" for the item set in `item`.
    func similarPhotosSheet(_ item: Binding<MediaItem?>) -> some View {
        sheet(item: item) { item in
            SimilarPhotosScreen(item: item)
                #if os(macOS)
                    .frame(minWidth: 640, idealWidth: 860, minHeight: 520, idealHeight: 720)
                #endif
        }
    }
}

struct SimilarPhotosScreen: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = SimilarPhotosModel()
    @State private var feed = GridFeed()
    @State private var columns = GridColumns.step(GridColumns.default, zoomIn: true)
    @State private var confirmKeepBest = false

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done", bundle: .module)) { dismiss() }
                    }
                }
        }
        .task {
            guard let services = session.services else { return }
            await model.run(item: item, services: services)
        }
        .onChange(of: resultItems, initial: true) { _, items in feed.apply(items, flat: true) }
    }

    var resultItems: [GridMedia] {
        if case .found(let result) = model.phase { return result.items }
        return []
    }

    var result: SimilarPhotosResult? {
        if case .found(let result) = model.phase { return result }
        return nil
    }

    var title: String {
        String(localized: "Similar Photos", bundle: .module, comment: "Title of the screen with the photos that look like one photo.")
    }

    @ViewBuilder var content: some View {
        switch model.phase {
        case .searching:
            // The grid's shape right away; the search over the sketches takes a moment at most.
            GridSkeleton(zoomStep: columns, showsHeader: false)
                .navigationTitle(title)
        case .unavailable:
            ContentUnavailableView(
                String(localized: "Can't compare this photo", bundle: .module),
                systemImage: SimilarPhotosAction.systemImage,
                description: Text("Its preview couldn't be loaded or analysed on this device. Try again later.", bundle: .module)
            )
            .navigationTitle(title)
        case .found(let result):
            MediaGridScreen(
                feed: feed, title: title, showsHeaders: false,
                emptyTitle: String(localized: "No similar photos", bundle: .module),
                emptyMessage: String(localized: "Photos that look like this one appear here.", bundle: .module),
                columns: $columns
            ) {
                EmptyView()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if result.moment.count > 1 || !result.isComplete { header(result) }
            }
        }
    }

    /// The best shot of the photo's moment, and how much of the library was compared.
    @ViewBuilder func header(_ result: SimilarPhotosResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let best = result.best, let bestItem = result.items.first(where: { $0.fileId == best }) {
                HStack(spacing: 12) {
                    SummaryPhoto(item: bestItem, bucket: 256)
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Label(String(localized: "Best shot", bundle: .module), systemImage: "star.fill")
                            .font(.headline)
                            .foregroundStyle(.yellow, .primary)
                        Text(
                            "The best of \(result.moment.count) shots taken at this moment, by sharpness and composition.",
                            bundle: .module, comment: "Show Similar: explains the suggested best shot of a series."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        if result.analysed > 0 {
                            Text(BestShotWording.summary(result.reasons))
                                .font(.footnote.weight(.medium))
                        }
                    }
                    Spacer(minLength: 0)
                    if !deletableOthers(result).isEmpty {
                        Button(keepBestTitle) { confirmKeepBest = true }
                            .buttonStyle(.bordered)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !result.isComplete {
                Label {
                    Text(
                        "Compared with \(result.indexed.formatted()) of \(result.total.formatted()) photos so far. More are compared as their previews are loaded.",
                        bundle: .module, comment: "Show Similar: the on-device index is not complete yet.")
                } icon: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .confirmationDialog(
            String(localized: "Delete \(deletableOthers(result).count) other shots?", bundle: .module),
            isPresented: $confirmKeepBest, titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: .module), role: .destructive) { keepBest(result) }
        } message: {
            Text(
                "The best shot is kept. The others are moved to the trash bin of your Nextcloud, where they can be restored.",
                bundle: .module)
        }
    }

    var keepBestTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Keep Best…", bundle: .module, comment: "Show Similar: delete the other shots of a series."),
            other: LocalizedStringResource("Keep best…", bundle: .module, comment: "Show Similar: delete the other shots of a series."))
    }

    func deletableOthers(_ result: SimilarPhotosResult) -> [FileID] {
        result.moment.filter { $0 != result.best }
    }

    /// Deletes the other shots of the moment (undoable, through the outbox like every delete).
    func keepBest(_ result: SimilarPhotosResult) {
        guard let library = session.services?.library, let map = try? library.items(deletableOthers(result)) else { return }
        let items = map.values.filter(\.permissions.canDelete)
        guard !items.isEmpty else { return }
        let services = session.services
        Task {
            await session.perform(.delete(Array(items)), undoManager: nil)
            if let services { await model.refresh(item: item, services: services) }
        }
    }
}
