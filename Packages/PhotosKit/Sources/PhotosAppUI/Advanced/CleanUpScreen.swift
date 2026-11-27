// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Clean up (SPEC §19.3)

/// The sections of Clean up, in the order shown: what can be deleted on the Nextcloud, then what can be removed from
/// this device (iPhone and iPad).
enum CleanUpSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case duplicates, similarShots, largeVideos, screenshots, device

    var id: String { rawValue }

    /// The sections this device offers: removing backed-up photos from the device exists on iPhone and iPad only.
    static var available: [CleanUpSection] {
        #if os(iOS)
            allCases
        #else
            allCases.filter { $0 != .device }
        #endif
    }

    /// The section that an older place of the app opens (SPEC §19.3): its destinations, deep links and menu commands
    /// keep working and land in Clean up.
    static func opened(by destination: AppDestination) -> CleanUpSection? {
        switch destination {
        case .duplicates: .duplicates
        // "Free up server space" listed large videos first, then screenshots and screen recordings (right below).
        case .freeSpace: .largeVideos
        default: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case .duplicates: String(localized: "Duplicates", bundle: .module)
        case .similarShots:
            String(
                localized: "Similar shots", bundle: .module,
                comment: "Clean up: series of photos of one scene taken one after the other (bursts, retakes).")
        case .largeVideos: String(localized: "Large videos", bundle: .module)
        case .screenshots:
            String(
                localized: "Screenshots and screen recordings", bundle: .module,
                comment: "Clean up: the section with screenshots and screen recordings.")
        case .device: DeviceWording.freeUpTitle
        }
    }

    var systemImage: String {
        switch self {
        case .duplicates: "square.on.square"
        case .similarShots: "square.stack.3d.down.right"
        case .largeVideos: "video"
        case .screenshots: "camera.viewfinder"
        case .device: "arrow.up.trash"
        }
    }

    var tint: Color {
        switch self {
        case .duplicates: .blue
        case .similarShots: .purple
        case .largeVideos: .orange
        case .screenshots: .teal
        case .device: .green
        }
    }

    /// The categories of "Free up space" (`Cleanup`) a section shows.
    var cleanupCategories: [Cleanup.Category] {
        switch self {
        case .largeVideos: [.largeVideos]
        case .screenshots: [.screenshots, .screenRecordings]
        default: []
        }
    }
}

/// What one section found: how many, how much space, a few pictures, and the files deleting would remove.
struct CleanUpFinding: Sendable {
    var count: Int
    /// The files offered for deletion and their sizes (the total counts each file once across sections).
    var files: [(id: FileID, size: Int64)]
    /// A few items to show in the row, largest or best first.
    var previews: [MediaItem]

    var bytes: Int64 { CleanUpTotals.bytes(files) }

    static let previewCount = 6
}

/// The state of "Similar shots": they need the on-device comparison of "Show Similar" (SPEC §15.5).
struct SimilarShotsFinding: Sendable {
    var finding: CleanUpFinding
    /// Photos compared so far, and all photos: series among the photos not compared yet are not found yet.
    var indexed: Int
    var total: Int

    var isComplete: Bool { indexed >= total }
}

/// Everything Clean up shows, loaded off the main actor.
@MainActor @Observable final class CleanUpModel {
    var duplicates: CleanUpFinding?
    /// Nil while loading or when the comparison is off (`similarEnabled`).
    var similar: SimilarShotsFinding?
    var similarEnabled = SimilarIndexing.isEnabled()
    var freeSpace: [Cleanup.Category: CleanUpFinding]?
    /// Free storage of this device in bytes (iPhone, iPad).
    var deviceAvailable: Int64?
    private(set) var loaded = false

    func finding(_ section: CleanUpSection) -> CleanUpFinding? {
        switch section {
        case .duplicates: return duplicates
        case .similarShots: return similar?.finding
        case .largeVideos, .screenshots:
            guard let freeSpace else { return nil }
            let parts: [CleanUpFinding] = section.cleanupCategories.compactMap { freeSpace[$0] }
            return CleanUpFinding(
                count: parts.reduce(0) { $0 + $1.count }, files: parts.flatMap(\.files),
                previews: Array(parts.flatMap(\.previews).sorted { $0.size > $1.size }.prefix(CleanUpFinding.previewCount)))
        case .device: return nil
        }
    }

    /// Bytes that all sections on the Nextcloud together can free, each file counted once; nil until all are loaded.
    var serverTotal: Int64? {
        guard let duplicates, let freeSpace, similar != nil || !similarEnabled else { return nil }
        var files: [(id: FileID, size: Int64)] = duplicates.files
        files += similar?.finding.files ?? []
        for finding in freeSpace.values { files += finding.files }
        return CleanUpTotals.bytes(files)
    }

    /// Loads (or reloads, after something was deleted) every section at once; old values stay until new ones arrive.
    func load(services: AccountServices) async {
        similarEnabled = SimilarIndexing.isEnabled()
        deviceAvailable = Self.availableDeviceSpace()
        let library = services.library
        let database = services.database
        let enabled = similarEnabled
        async let duplicateSets = Self.duplicates(library)
        async let categories = Self.freeSpace(library)
        async let series = enabled ? Self.similarShots(database: database, library: library) : nil
        duplicates = await duplicateSets
        freeSpace = await categories
        similar = await series
        loaded = true
    }

    nonisolated static func duplicates(_ library: LibraryStore) async -> CleanUpFinding {
        let sets = await DuplicateSet.load(library)
        var files: [(id: FileID, size: Int64)] = []
        for set in sets {
            for copy in set.copies where copy.fileId != set.suggested.fileId && copy.permissions.canDelete {
                files.append((copy.fileId, copy.size))
            }
        }
        let previews: [MediaItem] = sets.prefix(CleanUpFinding.previewCount).compactMap { set in
            set.copies.first { $0.fileId == set.suggested.fileId }
        }
        return CleanUpFinding(count: sets.count, files: files, previews: previews)
    }

    nonisolated static func freeSpace(_ library: LibraryStore) async -> [Cleanup.Category: CleanUpFinding] {
        let categories = await FreeSpaceScreen.load(library)
        var result: [Cleanup.Category: CleanUpFinding] = [:]
        for category in categories {
            result[category.category] = CleanUpFinding(
                count: category.items.count, files: category.items.map { ($0.fileId, $0.size) },
                previews: Array(category.items.prefix(CleanUpFinding.previewCount)))
        }
        return result
    }

    nonisolated static func similarShots(database: AccountDatabase, library: LibraryStore) async -> SimilarShotsFinding {
        let store = SimilarityStore(database: database)
        let groups = (try? await store.similarShots()) ?? []
        let progress = (try? store.progress()) ?? (indexed: 0, total: 0)
        var files: [(id: FileID, size: Int64)] = []
        // Sizes come with the items; only the previews' items are read here, the screen reads the rest.
        let ids: [FileID] = groups.flatMap(\.others)
        let items = (try? await library.fetchItems(ids + groups.prefix(CleanUpFinding.previewCount).map(\.best))) ?? [:]
        for id in ids { if let item = items[id] { files.append((id, item.size)) } }
        let previews: [MediaItem] = groups.prefix(CleanUpFinding.previewCount).compactMap { items[$0.best] }
        return SimilarShotsFinding(
            finding: CleanUpFinding(count: groups.count, files: files, previews: previews), indexed: progress.indexed,
            total: progress.total)
    }

    /// Storage still free on this device for things the user wants to keep (what Settings › General › Storage shows).
    nonisolated static func availableDeviceSpace() -> Int64? {
        #if os(iOS)
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        #else
            return nil
        #endif
    }
}

/// One place for getting space back (SPEC §19.3): duplicates, similar shots, large videos, screenshots and screen
/// recordings on the Nextcloud, and on iPhone and iPad the photos that can be removed from the device because they are
/// on the server. Each section shows what it found with its size and opens the screen that reviews and deletes it.
struct CleanUpScreen: View {
    /// Scrolled to and highlighted when the screen opens (the older Duplicates and Free up space places open here).
    var initialSection: CleanUpSection?

    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CleanUpModel()
    @State private var highlighted: CleanUpSection?
    @State private var didShowInitialSection = false

    init(initialSection: CleanUpSection? = nil) {
        self.initialSection = initialSection
    }

    static var title: String {
        String(localized: "Clean up", bundle: .module, comment: "Title of the screen that brings together the ways to free space.")
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    CleanUpTotalView(total: model.serverTotal)
                }
                Section {
                    ForEach(CleanUpSection.available.filter { $0 != .device }) { section in
                        row(section)
                    }
                } header: {
                    Text("On your Nextcloud", bundle: .module, comment: "Clean up: header of the sections that delete on the server.")
                } footer: {
                    Text(
                        "Nothing is deleted until you confirm. Deleting here deletes on your Nextcloud server and so on all your devices and the web.",
                        bundle: .module, comment: "Clean up: footer of the sections that delete on the server.")
                }
                #if os(iOS)
                    Section {
                        row(.device)
                    } header: {
                        Text(DeviceWording.sectionTitle)
                    }
                #endif
            }
            #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: false))
            #endif
            .navigationTitle(Self.title)
            .task {
                guard let services = session.services else { return }
                await model.load(services: services)
                showInitialSection(proxy)
            }
            // A sync that changed the library (the first one after signing in, too) changes what can be cleaned up.
            .onChange(of: session.syncStatus.isWorking) { _, working in
                guard !working, let services = session.services else { return }
                Task { await model.load(services: services) }
            }
        }
    }

    func row(_ section: CleanUpSection) -> some View {
        NavigationLink {
            detail(section)
        } label: {
            CleanUpRow(section: section, model: model)
        }
        .id(section)
        .listRowBackground(highlighted == section ? Color.accentColor.opacity(0.14) : nil)
        .accessibilityIdentifier("cleanUp.\(section.rawValue)")
    }

    @ViewBuilder func detail(_ section: CleanUpSection) -> some View {
        switch section {
        case .duplicates: DuplicatesScreen()
        case .similarShots: SimilarShotsScreen()
        case .largeVideos, .screenshots: FreeSpaceScreen(categories: section.cleanupCategories)
        case .device:
            #if os(iOS)
                if session.backup.authorization == .authorized || session.backup.authorization == .limited {
                    FreeUpSpaceView()
                } else {
                    BackupScreen()
                }
            #else
                EmptyView()
            #endif
        }
    }

    /// Scrolls to the section the screen was opened for, and lights it up for a moment.
    func showInitialSection(_ proxy: ScrollViewProxy) {
        guard let initialSection, !didShowInitialSection, CleanUpSection.available.contains(initialSection) else { return }
        didShowInitialSection = true
        proxy.scrollTo(initialSection, anchor: .top)
        highlighted = initialSection
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { highlighted = nil }
        }
    }
}

/// The headline of Clean up: how much all sections on the Nextcloud can free together.
struct CleanUpTotalView: View {
    var total: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let total {
                if total > 0 {
                    Text(
                        "Up to \(Formatters.bytes(total)) can be freed", bundle: .module,
                        comment: "Clean up: the headline. The placeholder is a size."
                    )
                    .font(.title2.weight(.semibold))
                    Text(
                        "Review each section below and choose what to delete.", bundle: .module,
                        comment: "Clean up: below the headline with the size that can be freed."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    // Not a Label: at the largest text sizes the audit took its wrapped title for clipped (SPEC §20.3).
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.seal").accessibilityHidden(true)
                        Text("Nothing to clean up", bundle: .module)
                    }
                    .font(.title3.weight(.semibold))
                    Text(
                        "No duplicates, similar shots, large videos or screenshots were found on your Nextcloud.", bundle: .module,
                        comment: "Clean up: shown when no section found anything."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for files to clean up…", bundle: .module)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cleanUp.total")
    }
}

/// A section of Clean up: icon, title, what it found with its size, and a few of the pictures.
struct CleanUpRow: View {
    let section: CleanUpSection
    let model: CleanUpModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(section.tint.gradient, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title).font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                let previews: [MediaItem] = model.finding(section)?.previews ?? []
                if !previews.isEmpty {
                    CleanUpPreviewStrip(items: previews)
                }
            }
            Spacer(minLength: 0)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let bytes, bytes > 0 {
                Text(Formatters.bytes(bytes)).font(.callout.weight(.medium)).monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    var isLoading: Bool {
        switch section {
        case .device: false
        case .similarShots: model.similarEnabled && model.similar == nil
        default: model.finding(section) == nil
        }
    }

    var bytes: Int64? { model.finding(section)?.bytes }

    /// What the section found, in words.
    var summary: String {
        if section == .device {
            if let available = model.deviceAvailable {
                return String(
                    localized: "\(Formatters.bytes(available)) available", bundle: .module,
                    comment: "Clean up: free storage on the iPhone or iPad. The placeholder is a size.")
            }
            return String(
                localized: "Remove photos and videos that are safely on your Nextcloud.", bundle: .module,
                comment: "Clean up: what the section about the device's own photos does.")
        }
        if section == .similarShots && !model.similarEnabled {
            return String(
                localized: "Turn on “Find similar photos” in Settings to find series of similar shots.", bundle: .module,
                comment: "Clean up: similar shots need the on-device comparison, which is off.")
        }
        guard let finding = model.finding(section) else {
            return String(localized: "Looking…", bundle: .module, comment: "Clean up: a section is still being searched.")
        }
        let size = Formatters.bytes(finding.bytes)
        switch section {
        case .duplicates:
            return finding.count == 0
                ? String(localized: "No duplicates", bundle: .module)
                : String(
                    localized: "\(finding.count) sets of identical copies · \(size) can be freed", bundle: .module,
                    comment: "Clean up: duplicates found. Placeholders: number of sets, size.")
        case .similarShots:
            return finding.count == 0
                ? String(localized: "No series of similar shots", bundle: .module, comment: "Clean up: no similar shots found.")
                : String(
                    localized: "\(finding.count) series · \(size) in the shots besides the best", bundle: .module,
                    comment: "Clean up: similar shots found. Placeholders: number of series, size of the other shots.")
        case .largeVideos:
            return finding.count == 0
                ? String(localized: "No videos over 100 MB", bundle: .module, comment: "Clean up: no large videos found.")
                : String(
                    localized: "\(finding.count) videos over 100 MB · \(size)", bundle: .module,
                    comment: "Clean up: large videos found. Placeholders: number of videos, their size.")
        case .screenshots:
            return finding.count == 0
                ? String(localized: "No screenshots or screen recordings", bundle: .module, comment: "Clean up: none found.")
                : String(
                    localized: "\(finding.count) items · \(size)", bundle: .module,
                    comment: "Clean up: screenshots and screen recordings found. Placeholders: number, size.")
        case .device:
            return ""
        }
    }

    /// A second line where the section needs one.
    var note: String? {
        switch section {
        case .similarShots:
            guard let similar = model.similar, !similar.isComplete else { return nil }
            return String(
                localized: "Compared \(similar.indexed.formatted()) of \(similar.total.formatted()) photos on this device so far.",
                bundle: .module, comment: "Clean up: the on-device comparison for similar shots is not complete yet.")
        case .device:
            return String(
                localized: "Remove photos and videos that are safely on your Nextcloud.", bundle: .module,
                comment: "Clean up: what the section about the device's own photos does."
            )
            .nilIfEqual(to: summary)
        default:
            return nil
        }
    }
}

extension String {
    fileprivate func nilIfEqual(to other: String) -> String? { self == other ? nil : self }
}

/// A few small pictures of what a section found (decorative: the row's text says what it is).
struct CleanUpPreviewStrip: View {
    let items: [MediaItem]
    @ScaledMetric(relativeTo: .body) private var side = 40.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                PreviewImage(item: item, bucket: 256)
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: 5))
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Similar shots

/// One series with its items and the shot the user keeps.
struct SimilarShotSet: Identifiable, Sendable {
    var group: SimilarShots.Group
    var items: [FileID: MediaItem]

    var id: FileID { group.id }

    nonisolated static func load(database: AccountDatabase, library: LibraryStore) async -> [SimilarShotSet] {
        let groups = (try? await SimilarityStore(database: database).similarShots()) ?? []
        let items = (try? await library.fetchItems(groups.flatMap(\.ids))) ?? [:]
        return groups.map { group in
            SimilarShotSet(group: group, items: items.filter { group.ids.contains($0.key) })
        }
    }

    /// The shot (its files) that holds `fileId`.
    func shot(of fileId: FileID) -> [FileID] {
        group.shots.first { $0.contains(fileId) } ?? [fileId]
    }

    /// The files deleted when the shot of `keptId` is kept: those of every other shot the user may delete.
    func deletable(keeping keptId: FileID) -> [MediaItem] {
        let kept = Set(shot(of: keptId))
        return group.ids.filter { !kept.contains($0) }.compactMap { items[$0] }.filter(\.permissions.canDelete)
    }
}

/// Series of similar shots across the library (SPEC §19.3), each with the best shot suggested; the user can keep another
/// one, then delete the rest from the server.
struct SimilarShotsScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var sets: [SimilarShotSet] = []
    /// The shot the user picked to keep instead of the suggested one, by series.
    @State private var chosen: [FileID: FileID] = [:]
    @State private var loaded = false
    @State private var enabled = SimilarIndexing.isEnabled()
    @State private var progress: (indexed: Int, total: Int)?
    @State private var pending: PendingServerDeletion?
    /// Series whose best shot is being analysed now, and how many (SPEC §21.4).
    @State private var analysing: (done: Int, total: Int)?

    /// How many series are listed at once; deleting some brings the next ones in.
    static let listed = 100
    /// How many of the first series are analysed for their best shot while the screen is open; the rest are analysed in
    /// the background (`BestShotAnalyzer.run`) or when the user scrolls back after a while.
    static let analysedOnOpen = 24

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !sets.isEmpty {
                    Text(
                        "Photos taken one after the other that look alike. The best shot is suggested: a favorite, else the one with open eyes and smiles that is sharpest and best exposed. The other shots can be deleted from your Nextcloud.",
                        bundle: .module, comment: "Similar shots: explanation above the list."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    if let analysing {
                        Label {
                            Text(
                                "Choosing the best shots on this device… \(analysing.done.formatted()) of \(analysing.total.formatted()) series",
                                bundle: .module, comment: "Similar shots: the on-device best-shot analysis is running.")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let progress, progress.indexed < progress.total {
                        Label {
                            Text(
                                "Compared \(progress.indexed.formatted()) of \(progress.total.formatted()) photos on this device so far.",
                                bundle: .module, comment: "Clean up: the on-device comparison for similar shots is not complete yet.")
                        } icon: {
                            Image(systemName: SimilarPhotosAction.systemImage)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(sets.prefix(Self.listed)) { set in
                    SimilarShotSetView(
                        set: set, keptId: chosen[set.id] ?? set.group.best, userChose: chosen[set.id] != nil,
                        keep: { id in chosen[set.id] = set.shot(of: id).contains(set.group.best) ? nil : id },
                        delete: { items in
                            pending = PendingServerDeletion(items: items) {
                                sets.removeAll { $0.id == set.id }
                                chosen[set.id] = nil
                            }
                        })
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if !enabled {
                ContentUnavailableView {
                    Label(String(localized: "Similar shots are off", bundle: .module), systemImage: SimilarPhotosAction.systemImage)
                } description: {
                    Text(
                        "Finding them needs “Find similar photos”, which compares the previews on this device. Nothing leaves the device.",
                        bundle: .module, comment: "Similar shots: the on-device comparison is turned off.")
                } actions: {
                    Button(String(localized: "Turn On", bundle: .module, comment: "Similar shots: turns on Find similar photos.")) {
                        turnOn()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if !loaded {
                ProgressView(String(localized: "Looking for similar shots…", bundle: .module))
            } else if sets.isEmpty {
                ContentUnavailableView(
                    String(localized: "No similar shots", bundle: .module), systemImage: "checkmark.seal",
                    description: Text(emptyMessage))
            }
        }
        .navigationTitle(CleanUpSection.similarShots.title)
        .serverDeleteConfirmation($pending, session: session)
        .task(id: enabled) { await load() }
    }

    var emptyMessage: String {
        if let progress, progress.indexed < progress.total {
            return String(
                localized:
                    "None found among the \(progress.indexed.formatted()) photos compared so far. More are compared while the device is charging or idle.",
                bundle: .module, comment: "Similar shots: none found yet, the comparison is not complete.")
        }
        return String(
            localized: "Series of photos taken one after the other that look alike appear here.", bundle: .module,
            comment: "Similar shots: none found.")
    }

    /// Finds the series, and while the comparison is not complete, compares the cached previews not compared yet a few
    /// seconds at a time and looks again, as "Show Similar" does while the user waits (not in Low Power Mode, when
    /// warm or low on battery).
    func load() async {
        guard enabled, let services = session.services else { return }
        while !Task.isCancelled {
            sets = await SimilarShotSet.load(database: services.database, library: services.library)
            let progress = try? SimilarityStore(database: services.database).progress()
            self.progress = progress
            loaded = true
            await analyseBestShots(services)
            guard let progress, progress.indexed < progress.total, SimilarIndexing.Conditions.current.allowsForegroundWork else {
                return
            }
            let indexer = SimilarityIndexer(database: services.database, cache: services.images.cache, index: services.similarity)
            let deadline = ContinuousClock.now + .seconds(4)
            let indexed = await Task.detached(priority: .utility) {
                (try? await indexer.run(batchSize: 24) { ContinuousClock.now < deadline }) ?? 0
            }.value
            // Nothing more can be compared now (the other previews are not on this device yet).
            if indexed == 0 { return }
        }
    }

    /// Analyses the shots of the first series that are not analysed yet (SPEC §21.4), a few series at a time, loading
    /// their 1024 px previews where needed, and lists again after each step so the suggestions follow.
    func analyseBestShots(_ services: AccountServices) async {
        let pending = sets.prefix(Self.analysedOnOpen).filter { $0.group.analysed < $0.group.shots.count }
        guard !pending.isEmpty else { return }
        let service = BestShotService(services: services)
        analysing = (0, pending.count)
        defer { analysing = nil }
        var done = 0
        for start in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled else { return }
            let step = pending[start..<min(start + 4, pending.count)]
            let shots: [FileID] = step.flatMap { $0.group.shots.compactMap(\.first) }
            let analysed = await service.signals(of: shots, fetch: true)
            done += step.count
            analysing = (done, pending.count)
            // Nothing could be analysed (the simulator, or offline): no point in going on.
            if analysed.isEmpty { return }
            sets = await SimilarShotSet.load(database: services.database, library: services.library)
        }
    }

    /// Turns the on-device comparison on (the same setting as Settings › Search) and schedules it.
    func turnOn() {
        UserDefaults.standard.set(true, forKey: SimilarIndexing.enabledKey)
        SimilarIndexing.schedule()
        enabled = true
    }
}

/// One series: its shots side by side, the kept one marked; a click or tap keeps another one.
struct SimilarShotSetView: View {
    let set: SimilarShotSet
    let keptId: FileID
    let userChose: Bool
    let keep: (FileID) -> Void
    let delete: ([MediaItem]) -> Void

    var body: some View {
        let deletable: [MediaItem] = set.deletable(keeping: keptId)
        let freed: Int64 = deletable.reduce(0) { $0 + $1.size }
        let kept: Set<FileID> = Set(set.shot(of: keptId))
        let date: Date? = set.items[set.group.best]?.timestamp
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(set.group.shots.count) similar shots · \(Formatters.bytes(freed)) can be freed", bundle: .module,
                    comment: "Similar shots: heading of a series. Placeholders: number of shots, size."
                )
                .font(.headline)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(set.group.ids, id: \.self) { id in
                        if let item = set.items[id] {
                            DuplicateCopyCard(item: item, kept: kept.contains(id)) { keep(id) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text(verbatim: "\(reason) \(hint)").font(.callout).foregroundStyle(.secondary)
            if deletable.isEmpty {
                Text("You don't have permission to delete the other shots.", bundle: .module).font(.callout).foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Delete \(deletable.count) other shots…", bundle: .module), role: .destructive) {
                    delete(deletable)
                }
            }
        }
    }

    var reason: String {
        if userChose { return String(localized: "You chose which shot to keep.", bundle: .module) }
        if set.group.kept.contains(where: { set.items[$0]?.isFavorite == true }) {
            return String(localized: "The favorite is kept.", bundle: .module)
        }
        guard set.group.analysed > 0 else {
            return String(
                localized: "The sharpest and best composed shot is kept.", bundle: .module,
                comment: "Similar shots: why a shot is suggested (Vision's aesthetics score, or the middle of a burst).")
        }
        let why = String(
            localized: "Best shot: \(BestShotWording.summary(set.group.reasons)).", bundle: .module,
            comment: "Similar shots: why a shot is suggested. The placeholder is a list such as Sharpest, eyes open.")
        return set.group.analysed < set.group.shots.count ? why + " " + BestShotWording.preliminary : why
    }

    var hint: String {
        #if os(macOS)
            String(localized: "Click another shot to keep that one instead.", bundle: .module)
        #else
            String(localized: "Tap another shot to keep that one instead.", bundle: .module)
        #endif
    }
}
