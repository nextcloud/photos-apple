// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Timeline views: All media, Photos, Videos, Favorites (SPEC §7.1).
struct TimelineScreen: View {
    let filter: MediaFilter
    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var mediaKind: MediaFilter
    @AppStorage(TimelineDisplay.stackCopiesKey) private var stackCopies = true
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true
    /// Photos are being selected: the memories strip makes room for the grid.
    @State private var gridSelection = GridSelectionState()
    @State private var memories: [Memory] = []
    /// "Show in library" from elsewhere: the Library scrolls to the photo and highlights it.
    @Environment(\.timelineReveal) private var reveal
    /// Picks, rejected, star ratings… (SPEC §15.2).
    @State private var cullingFilter: CullingFilter = .all
    @State private var deleteRejected: DeleteRejectedConfirmation?
    @State private var nothingRejected = false
    /// Not `@Environment(\.undoManager)`: on iPad that rendered the timeline again each time the sidebar hosted it, an
    /// endless loop (see `UndoManagerBox`).
    @State private var undoBox = UndoManagerBox()
    private var undoManager: UndoManager? { undoBox.manager }
    /// Years, months, days or all photos (SPEC §15.5).
    @State private var zoom = LibraryZoomModel()
    /// Moments: titles on the day headers (SPEC §16.1).
    @AppStorage(TimelineDisplay.showsMomentsKey) private var showsMoments = true
    @State private var moments = LibraryMomentsModel()
    @State private var openedMoment: Memory?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The memories strip is at the top of the whole library, not of a filtered one (SPEC TL-3), and not while selecting.
    var showsMemoriesStrip: Bool {
        filter == .all && mediaKind == .all && cullingFilter == .all && showsMemories && !gridSelection.isSelecting
    }

    /// Moment titles are on the day headers of the whole library, not of a filtered one.
    var showsMomentHeaders: Bool {
        filter == .all && mediaKind == .all && cullingFilter == .all && showsMoments
    }

    var momentsKey: LibraryMomentsModel.LoadKey {
        LibraryMomentsModel.LoadKey(
            memories: MemoriesStrip.loadKey(session.syncStatus, isShown: true),
            excluded: session.excludedFolders + (session.partners?.hiddenFolders ?? []), isOn: filter == .all && showsMoments)
    }

    /// What the grid observes: the media kind, whether copies of a photo are stacked and which partner folders are
    /// hidden (Settings › Partner sharing, or the toolbar button).
    struct Query: Hashable {
        var kind: MediaFilter
        var stacksCopies: Bool
        var hiddenPartnerFolders: [String] = []
        var culling: CullingFilter = .all
        /// The device's photos that are not backed up stand in it (SPEC §21.1).
        var showsDevice = false
    }

    var query: Query {
        Query(
            kind: mediaKind, stacksCopies: stackCopies, hiddenPartnerFolders: session.partners?.hiddenFolders ?? [], culling: cullingFilter,
            showsDevice: cullingFilter == .all && session.backup.deviceLayer.showsInLibrary(of: session.account.id))
    }

    /// While the first sync runs, the whole library's shape from the server's month counts (extended Photos API): the
    /// grid and its year index reach back to the oldest photo before it is loaded. Only for the unfiltered library,
    /// which is what the counts are of. Stock servers have no counts: the grid shows what is loaded.
    var skeleton: TimelineSkeleton? {
        guard mediaKind == .all, cullingFilter == .all, case .initialSync = session.syncStatus else { return nil }
        return session.initialSyncSkeleton
    }

    /// The media kind the Library opens with (Photos, Videos and Favorites from links, menus and old sidebar rows; SPEC
    /// §19.2): the Library itself, filtered, with the filter shown and clearable.
    let initialKind: MediaFilter

    /// `filter` is a timeline of its own (only those photos, with its own title); `initialKind` is the Library opened with
    /// that filter set in its filter menu.
    init(filter: MediaFilter = .all, initialKind: MediaFilter = .all) {
        self.filter = filter
        let kind: MediaFilter = filter == .all ? (Self.debugKind ?? initialKind) : filter
        self.initialKind = kind
        _mediaKind = State(initialValue: kind)
    }

    /// Debug builds: `PHOTOS_DEBUG_LIBRARY_KIND=favorites` (photos, videos) opens the Library with that filter
    /// (screenshots, UI tests).
    static var debugKind: MediaFilter? {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LIBRARY_KIND"] {
            case "photos": return .photos
            case "videos": return .videos
            case "favorites": return .favorites
            default: return nil
            }
        #else
            return nil
        #endif
    }

    var title: String {
        switch filter {
        case .photos: String(localized: "Photos", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        case .favorites: String(localized: "Favorites", bundle: .module)
        default: String(localized: "Library", bundle: .module)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
                filterChips
                if showsMemoriesStrip && !memories.isEmpty {
                    MemoriesStrip(memories: memories)
                }
            #endif
            grid
                .libraryZoomLevels(zoom, feed: feed, isSelecting: gridSelection.isSelecting)
        }
        #if !os(macOS)
            // Under the title, floating over the photos like the zoom picker at the bottom (SPEC §19.2). Not a
            // `safeAreaBar`: there the chips were laid out but not drawn (iOS 27.2 simulator).
            .overlay(alignment: .top) { filterChips }
        #endif
        .animation(reduceMotion ? nil : .snappy, value: filtersShown)
        // Photos, Videos or Favorites asked for again while the Library is shown (a link, a menu command).
        .onChange(of: initialKind) { _, kind in
            if filter == .all { mediaKind = kind }
        }
        .readsUndoManager(into: undoBox)
        .task(id: MemoriesStrip.loadKey(session.syncStatus, isShown: filter == .all && showsMemories)) {
            guard filter == .all, showsMemories, let services = session.services else { return }
            if let loaded = await MemoriesStrip.load(services) { memories = loaded }
        }
        .task(id: momentsKey) {
            guard momentsKey.isOn, let services = session.services else {
                moments.clear()
                return
            }
            let hidden = session.hiddenPeopleFile.map { HiddenPeople.load(from: $0).names } ?? []
            await moments.load(services, excludedFolders: momentsKey.excluded, hiddenPeople: hidden)
        }
        .onChange(of: showsMomentHeaders ? moments.headers : .none, initial: true) { _, headers in
            zoom.moments = headers
        }
        .navigationDestination(item: $openedMoment) { memory in MemoryScreen(memory: memory) }
        .onPreferenceChange(GridSelectionState.Key.self) { state in
            gridSelection = state
        }
        .task(id: query) { observe() }
        .onAppear {
            seedFromLaunchPrefetch()
            zoom.setGridStep = { [columns = $columns] step in columns.wrappedValue = step }
            zoom.openMoment = { [moments, opened = $openedMoment] id in opened.wrappedValue = moments.memory(id) }
        }
        .onChange(of: skeleton, initial: true) { _, skeleton in feed.setSkeleton(skeleton) }
        // The photo is looked for among all media (the iPhone's picker may show only videos or favourites).
        .onChange(of: reveal?.pending, initial: true) { _, pending in
            if filter == .all, pending != nil { mediaKind = .all }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.transfers.upload(urls.map { UploadSource(file: $0, isTemporary: false) })
            return !urls.isEmpty
        }
        // File ▸ Import from iPhone or iPad (Continuity Camera, Mac; SPEC §16.5.3): into the upload folder.
        .continuityCameraImport()
        // Pull to refresh reconciles only when the last walk through the library is a while ago ("Sync now" always does).
        .refreshable { await session.syncNow(reconcile: .refresh) }
        .confirmationDialog(
            deleteRejected?.title ?? "", isPresented: Binding(get: { deleteRejected != nil }, set: { if !$0 { deleteRejected = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                if let items = deleteRejected?.items {
                    let undoManager = undoManager
                    Task { await session.perform(.delete(items), undoManager: undoManager) }
                }
            }
        } message: {
            Text(
                session.features.has(.trashbin)
                    ? String(localized: "The items are moved to the trash bin of your Nextcloud.", bundle: .module)
                    : String(localized: "The trash bin is disabled on your server: deleted items cannot be restored.", bundle: .module))
        }
        .alert(DeleteRejectedConfirmation.nothingTitle, isPresented: $nothingRejected) {
        } message: {
            Text(DeleteRejectedConfirmation.nothingMessage)
        }
    }

    /// "Delete Rejected…": every rejected photo of the library (own or with delete permission), after a confirmation.
    func requestDeleteRejected() {
        let items = session.rejectedItems().filter(\.permissions.canDelete)
        if items.isEmpty {
            nothingRejected = true
        } else {
            deleteRejected = DeleteRejectedConfirmation(items: items)
        }
    }

    var grid: some View {
        MediaGridScreen(
            feed: feed,
            title: title,
            showsHeaders: true,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage,
            columns: $columns,
            waitsForFirstSync: true,
            reveal: filter == .all ? reveal : nil,
            isLibrary: filter == .all,
            deleteRejected: session.features.has(.systemtags) ? { requestDeleteRejected() } : nil,
            moments: showsMomentHeaders ? moments.headers : .none,
            openMoment: { id in openedMoment = moments.memory(id) },
            gridHeader: memoriesHeader,
            trailingItem: accountButton
        ) {
            // While something runs: uploads, a card import, photos open in other apps (SPEC §19.2).
            TransfersIndicator()
            PhotographerStatusItems()
            #if os(macOS)
                // Mac: "12 not backed up" while something is (SPEC §21.1); the other platforms have it in the account
                // menu. Only here: an empty view among the toolbar items changed how iOS built the Library's toolbar,
                // and the accessibility audit found an element without a description over the grid.
                if filter == .all { BackupSummaryToolbarItem() }
            #endif
            // One filter menu on every platform (SPEC §19.2); a timeline of its own (Photos, Videos, Favorites) has none.
            if filter == .all {
                LibraryFilterMenu(
                    kind: $mediaKind, culling: $cullingFilter, offersCulling: session.features.has(.systemtags)
                ) { requestDeleteRejected() }
            }
            #if os(macOS)
                // Mac: Years, Months, Days, All Photos, as in Apple Photos' toolbar (SPEC §15.5). The one zoom control:
                // the grid's own steps are ⌘+ and ⌘−, View ▸ Zoom In/Out and a pinch (SPEC §19.2).
                LibraryZoomPicker(model: zoom, gridStep: columns)
            #endif
        }
    }

    /// The active filters under the title, each clearing itself (only the Library has them).
    @ViewBuilder var filterChips: some View {
        if filter == .all && !gridSelection.isSelecting {
            LibraryFilterChips(kind: $mediaKind, culling: $cullingFilter)
        }
    }

    /// What the chips' animation follows.
    var filtersShown: LibraryFilters {
        LibraryFilters(
            kind: mediaKind, culling: cullingFilter, hidesPartnerPhotos: LibraryFilterMenu.hidesPartners(session.partners))
    }

    /// The account button (avatar) with Settings, account switching and Upload, after Select; the Library's own, not a
    /// timeline's (iPhone, iPad, Vision Pro; SPEC §19.2).
    var accountButton: AnyView? {
        #if os(macOS)
            return nil
        #else
            return filter == .all ? AnyView(AccountMenuButton()) : nil
        #endif
    }

    /// The memories scroll with the photos (edge to edge, SPEC §17.2); the Mac keeps them above its grid.
    var memoriesHeader: AnyView? {
        #if os(macOS)
            return nil
        #else
            guard showsMemoriesStrip, !memories.isEmpty else { return nil }
            return AnyView(MemoriesStrip(memories: memories))
        #endif
    }

    /// The folders the Library leaves out: `.nomedia` folders and, while partner photos are hidden, the partners' folders.
    static func excludedFolders(_ session: SessionModel) -> [String] {
        session.excludedFolders + (session.partners?.hiddenFolders ?? [])
    }

    /// At launch: the Library's first items and its memories, read while the window was built
    /// (`LibraryLaunchPrefetch`), so that the first frame shows them instead of waiting for `observe()` and the strip's
    /// `.task`, which run only after it.
    func seedFromLaunchPrefetch() {
        guard filter == .all else { return }
        let prefetch = LibraryLaunchPrefetch.shared
        if mediaKind == .all, cullingFilter == .all, skeleton == nil, !feed.loaded {
            let key = LibraryLaunchPrefetch.Key(
                account: session.account.id.rawValue, excludedFolders: Self.excludedFolders(session), stacksCopies: stackCopies)
            if let model = prefetch.take(key) { feed.seed(model) }
        }
        if showsMemories, memories.isEmpty, let cards = prefetch.takeMemories(account: session.account.id.rawValue) {
            memories = cards
        }
    }

    func observe() {
        guard let services = session.services else { return }
        let library = services.library
        let excluded = Self.excludedFolders(session)
        let kind = mediaKind
        let culling = cullingFilter
        // Coalesced: a running sync commits page after page; a single change (a favourite) still arrives at once.
        let query: @Sendable () -> GridStream = {
            library.observeGrid(kind, excludedFolders: excluded, culling: culling, coalescing: .milliseconds(300))
        }
        let evidence = SimilarIndexing.isEnabled() ? StoredBurstEvidence(database: services.database) : nil
        // The device's photos that are not on the server yet, merged in by capture time (SPEC §21.1), before the stacks
        // are made: a burst of device photos stacks like the server's.
        let shown: Bool = self.query.showsDevice
        let timeline: @Sendable () -> GridStream =
            shown ? DeviceLibraryTimeline.merged(query, layer: session.backup.deviceLayer, kind: kind) : query
        feed.observe(stackCopies ? TimelineStacking.stacked(timeline, evidence: evidence) : timeline, flat: false)
    }

    var emptyTitle: String {
        // While the first sync runs the grid shows a skeleton; these are for a library that could not be loaded.
        switch session.syncStatus {
        case .offline(lastSync: nil): return String(localized: "You're offline", bundle: .module)
        case .failed(_, lastSync: nil): return String(localized: "Couldn't load your library", bundle: .module)
        default: break
        }
        if cullingFilter != .all {
            return String(localized: "No matching photos", bundle: .module, comment: "Library filtered by rating or flag: nothing matches.")
        }
        switch mediaKind {
        case .favorites: return String(localized: "No favorites yet", bundle: .module)
        case .videos: return String(localized: "No videos", bundle: .module)
        default: return String(localized: "No photos yet", bundle: .module)
        }
    }

    var emptyMessage: String {
        switch session.syncStatus {
        case .offline(lastSync: nil):
            return String(localized: "Your library is loaded as soon as the server can be reached.", bundle: .module)
        case .failed(let message, lastSync: nil): return message
        default: break
        }
        if cullingFilter != .all {
            return String(
                localized: "No photos match “\(CullingWording.filterTitle(cullingFilter))”.", bundle: .module,
                comment: "Library filtered by rating or flag: nothing matches. The placeholder is the filter, e.g. Picks.")
        }
        let folders = session.features.userConfig.photosSourceFolders.joined(separator: ", ")
        return String(localized: "Photos and videos in \(folders) on your Nextcloud appear here.", bundle: .module)
    }
}
