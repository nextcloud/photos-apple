// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Full-screen pager over a context (SPEC §7.2).
struct MediaViewer: View {
    // State the extensions in MediaViewer+*.swift use is internal rather than private (SPEC §20.7).
    let ids: [FileID]
    /// Copies of one shot behind a tile of the grid, by the tile's id (`ViewerStart.stacks`).
    let stacks: [FileID: [FileID]]
    /// Opened from the Library: "Show in library" is not offered.
    let fromLibrary: Bool
    /// Told the tile of the photo shown whenever it changes: the zoom transition goes back into that tile.
    var currentChanged: (@MainActor (FileID) -> Void)?
    /// The copy a stack's page shows, chosen in the strip of its copies, by the tile's id (SPEC VW-6).
    @State var chosenCopies: [FileID: FileID] = [:]
    /// The page shown: a photo, or the tile of a stack (`currentFileId` is the copy it shows).
    @State var current: FileID?
    @State var chromeHidden = false
    @State var showingInfo = false
    /// Whether the info card was open when the vertical swipe in progress began; nil between swipes.
    @State var swipeBeganWithInfo: Bool?
    @State var confirmDelete = false
    @State var editing: MediaItem?
    @State var editingMetadata: MediaItem?
    /// The undo history from the More menu (iPhone, iPad; SPEC §16.3.4).
    @State var showingUndoHistory = false
    @State var extractingText: MediaItem?
    @State var addingToAlbum: MediaItem?
    @State var tagging: MediaItem?
    /// "Make Sticker" (SPEC §15.8.2).
    @State var stickerItem: MediaItem?
    /// Nextcloud's own sharing of the photo shown (SPEC SH-7).
    @State var nextcloudShare: SharingTarget?
    /// Slideshow from the photo shown through the viewer's photos (SPEC VW-5).
    @State var slideshow: SlideshowRequest?
    /// "Show Similar" for the photo shown (SPEC §15.5).
    @State var similarTo: MediaItem?
    /// "Then and now" of the place of the photo shown (SPEC §15.6).
    @State var thenAndNow: ThenAndNowStart?
    /// "Send as postcard…" for the photo shown (SPEC §16.7.1).
    @State var postcard: PostcardStart?
    /// Photos that left the context while the viewer is open (deleted, archived): their pages are gone.
    @State var removed: Set<FileID> = []
    /// Zoom In / Zoom Out / Zoom to Fit from the menu bar, carried out by the page shown; and that page's scale.
    @State var zoomCommand: ViewerZoomCommand?
    @State var zoomScale: CGFloat = ViewerZoom.minimumScale
    /// Where the page is while it is dragged down to close the viewer and while it lands in its tile (iPhone, iPad).
    @State var dismissPose = ViewerDismissPose.rest
    /// The page fades out instead of flying into its tile (Reduce Motion).
    @State var exitOpacity: Double = 1
    /// The page's frame in global coordinates, to land the photo in its tile.
    @State var pageFrame: CGRect = .zero
    /// Top of the info card in global coordinates while it is a sheet (iPhone): the photo moves up above it.
    @State private var infoTop: CGFloat?
    /// The top safe area: the badges on the photo go below the floating controls.
    @State var topInset: CGFloat = 0
    /// Counted up to put the current page back in place after a page was taken out.
    @State var realignments = 0
    /// Save to Photos / Export…, with its progress and result.
    @State var saver = MediaSaveModel()
    /// Incremented to ask the current video page to play or pause (Space).
    @State var playbackToggle = 0
    /// Edge the pointer is near, to reveal the previous/next button there.
    @State var hoverEdge: HorizontalEdge?
    @State private var pagerWidth: CGFloat = 0
    @State var pageSize: CGSize = .zero
    /// The page size the info card's placement is computed from (`infoPlacement`). It follows `pageSize` only by whole
    /// points: the placement scales and moves the page, after which the pager measured itself a few points taller or
    /// shorter, and feeding that back made placement and measurement chase each other without end (round 11: with the
    /// info card open on a portrait photo the main thread never became idle).
    @State var placementPageSize: CGSize = .zero
    @FocusState var focused: Bool
    /// The page VoiceOver is on; moved along when the photo is changed with a swipe up or down (adjustable action).
    @AccessibilityFocusState var accessibilityPage: FileID?
    /// Haptic triggers (iPhone, iPad).
    @State var favoriteToggles = 0
    @State private var deletions = 0
    /// Ratings and flags given here (SPEC §15.2).
    @State var culling = CullingModel()
    /// The backdrop's colour from the photo, following the pager (SPEC §16.8.1).
    @State private var tint = ViewerTint()
    @Environment(SessionModel.self) var session
    /// The window's undo manager: favourite, archive and delete made here are undone with Edit › Undo (⌘Z, shake).
    @Environment(\.undoManager) var undoManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dismiss) var dismiss
    @Environment(\.layoutDirection) var layoutDirection
    @Environment(\.showInFolder) var showInFolder
    @Environment(\.showInTimeline) var showInTimeline
    @Environment(\.colorScheme) private var colorScheme
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.viewerExit) var viewerExit

    init(
        ids: [FileID], startId: FileID, stacks: [FileID: [FileID]] = [:], fromLibrary: Bool = false,
        currentChanged: (@MainActor (FileID) -> Void)? = nil
    ) {
        self.ids = ids
        self.stacks = stacks
        self.fromLibrary = fromLibrary
        self.currentChanged = currentChanged
        // A copy that is not a tile of its own opens on its stack's page.
        _current = State(initialValue: ids.contains(startId) ? startId : (ViewerStacks.tile(of: startId, in: stacks) ?? startId))
        if !ids.contains(startId), let tile = ViewerStacks.tile(of: startId, in: stacks) {
            _chosenCopies = State(initialValue: [tile: startId])
        }
    }

    /// The row of the current photo, observed so the favourite heart (and the value the next toggle sends) follows
    /// changes made here or elsewhere — whatever screen opened the viewer.
    @State private var observedItem: MediaItem?

    /// The pages: the context the viewer was opened with (a stack is one page), without what was deleted or archived here.
    var shownIds: [FileID] {
        ViewerStacks.pages(ids, stacks: stacks, removed: removed)
    }

    /// The photo a page shows: itself, or the copy of its stack chosen in the strip.
    func fileId(ofPage page: FileID) -> FileID {
        ViewerStacks.shown(page: page, stacks: stacks, chosen: chosenCopies, removed: removed) ?? page
    }

    /// The photo shown now.
    var currentFileId: FileID? { current.map { fileId(ofPage: $0) } }

    struct PagerLayout: Hashable {
        var size: CGSize
        var realignments: Int
    }

    var currentItem: MediaItem? {
        guard let shown = currentFileId else { return nil }
        // Right after paging, until the observation of the new photo has delivered its first value.
        if let observedItem, observedItem.fileId == shown { return observedItem }
        return try? session.services?.library.item(shown)
    }

    /// The paging scroll view. Its pages are as large as the scroll view, so whenever that changes size (sidebar,
    /// info inspector, window resize) the offset of the current page changes too and has to be restored.
    var pager: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    let pages: [FileID] = shownIds
                    ForEach(pages, id: \.self) { id in
                        ViewerPage(
                            fileId: fileId(ofPage: id), isCurrent: id == current, playbackToggle: playbackToggle,
                            position: pages.firstIndex(of: id).map { AccessibilityText.position(index: $0, count: pages.count) } ?? "",
                            actions: accessibilityActions, zoomCommand: zoomCommand, events: pageEvents
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .accessibilityFocused($accessibilityPage, equals: id)
                        .id(id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Double.self) { geometry in
                ViewerTint.pagePosition(offset: geometry.contentOffset.x, width: geometry.containerSize.width)
            } action: { _, position in
                tint.scrollPosition = position
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                pageSize = size
                if ViewerStage.isNewPlacementSize(size, old: placementPageSize) { placementPageSize = size }
            }
            .task(id: PagerLayout(size: pageSize, realignments: realignments)) {
                // Once right away, and once more after the sidebar or inspector animation has settled.
                if let current { reader.scrollTo(current, anchor: .leading) }
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled, let current { reader.scrollTo(current, anchor: .leading) }
            }
        }
    }

    var body: some View {
        // In two parts: one long chain of modifiers takes the compiler too long to type-check.
        page
            .infoInspector(isPresented: $showingInfo, compactSheet: true) {
                // Beside the photo itself: no thumbnail of it on top of the panel.
                if let item = currentItem {
                    InfoPanel(item: item, inInspector: true, showsPreview: false)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).minY
                        } action: { top in
                            infoTop = top
                        }
                }
            }
            .focusedSceneValue(\.gridActions, viewerActions)
            .photoEditor($editing)
            .sheet(item: $editingMetadata) { item in BatchFixSheet(items: [item]) }
            .undoHistorySheet(isPresented: $showingUndoHistory)
            .sheet(item: $extractingText) { item in ExtractTextSheet(item: item) }
            .sheet(item: $addingToAlbum) { item in AlbumPickerSheet(items: [item]) }
            .sheet(item: $tagging) { item in TagEditorSheet(items: [item]) }
            .similarPhotosSheet($similarTo)
            .sheet(item: $stickerItem) { item in StickerSheet(item: item) }
            .sheet(item: $nextcloudShare) { target in
                if let services = session.services { FileSharingSheet(target: target, api: services.api.sharing) }
            }
            .slideshow($slideshow) { last in showAfterSlideshow(last) }
            .thenAndNowSheet($thenAndNow)
            .postcardSheet($postcard)
            .mediaSaveStatus(saver)
            // The photo shown continues on another device (SPEC §22.2); not an archived one or a Live Photo's video.
            .handoff(DeepLink.mayOpen(currentItem) ? currentFileId.map { DeepLink.photo(fileId: $0) } : nil)
            .confirmationDialog(
                String(localized: "Delete this item?", bundle: .module), isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                    // Only a photo that really is deleted leaves the viewer (a read-only one stays).
                    if let item = currentItem, item.permissions.canDelete {
                        deletions += 1
                        let undoManager = undoManager
                        Task { await session.perform(.delete([item]), undoManager: undoManager) }
                        remove([item.fileId])
                    }
                }
            }
            .photosHaptic(.impact(weight: .light), trigger: favoriteToggles)
            .photosHaptic(.impact(weight: .medium), trigger: deletions)
            // "Moved 1 item to the trash bin · Undo", as in the grid.
            .overlay(alignment: .bottom) { ChangeNoticeToast() }
            .animation(.default, value: session.lastChange?.id)
            .onChange(of: session.lastChange) { _, notice in
                if let notice { apply(ViewerPageChange(notice)) }
            }
    }

    /// The stage is dark in Dark Mode and while the controls are hidden, light otherwise; Vision Pro's windows are glass,
    /// where the viewer stays dark (SPEC §17.1).
    var stageScheme: ColorScheme {
        #if os(visionOS)
            .dark
        #else
            ViewerStage.isDark(darkAppearance: colorScheme == .dark, controlsHidden: chromeHidden) ? .dark : .light
        #endif
    }

    /// The photo's shape, for where it is on the page.
    var currentContentSize: CGSize {
        guard let item = currentItem, let width = item.width, let height = item.height, width > 0, height > 0 else { return pageSize }
        return CGSize(width: width, height: height)
    }

    /// The photo's rectangle on the page shown.
    var currentPhotoRect: CGRect {
        ViewerDismissal.photoRect(content: currentContentSize, page: pageSize)
    }

    /// With the info card open as a sheet (iPhone), the photo moves up and shrinks to stay in view above it, as in
    /// Photos; beside an inspector column (iPad, Mac) it stays where it is.
    var infoPlacement: (scale: CGFloat, offsetY: CGFloat) {
        #if os(macOS)
            return (1, 0)
        #else
            let isSheet: Bool = horizontalSizeClass == .compact
            guard showingInfo, isSheet, let infoTop else { return (1, 0) }
            let top: CGFloat = topInset + 56 - pageFrame.minY
            return ViewerStage.infoPlacement(
                content: currentContentSize, page: placementPageSize, top: top, bottom: infoTop - pageFrame.minY - 8)
        #endif
    }

    /// The pager with its backdrop, controls, keyboard and focus.
    var page: some View {
        let placement = infoPlacement
        return
            pager
            // Badges on the photo (Live, RAW) go below the floating controls.
            .environment(\.viewerControlsInset, topInset + 60)
            // The backdrop always fills the window; the pages do so on iPhone and iPad, where the controls float over
            // them. On the Mac they stay inside the safe area, so nothing hides under the toolbar or the inspector.
            .modifier(ViewerPageArea())
            // Dragged down to close: the photo follows the finger and shrinks, the backdrop fades to the grid behind,
            // and the photo lands in its tile (`land`).
            .viewerDismissPose(dismissPose, page: pageSize)
            .opacity(exitOpacity)
            .scaleEffect(placement.scale)
            .offset(y: placement.offsetY)
            .background {
                ViewerBackdrop(tint: tint)
                    .opacity((1 - Double(dismissPose.progress)) * exitOpacity)
                    .ignoresSafeArea()
                    // Where the page is on screen, measured here: the page itself is moved and scaled.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        pageFrame = frame
                    }
            }
            .environment(\.colorScheme, stageScheme)
            .modifier(ViewerTintTracking(tint: tint, pages: shownIds.map { fileId(ofPage: $0) }, current: currentFileId))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                pagerWidth = width
            }
            #if os(iOS)
                .overlay { stageControls }
            #endif
            .onContinuousHover { phase in
                hoverEdge = Self.edge(under: phase, width: pagerWidth)
            }
            .overlay { stepButtons.viewerChromeDepth() }
            // A device photo has controls of its own (SPEC §21.1).
            .overlay(alignment: .bottom) { DeviceViewerControls(fileId: currentFileId, isHidden: chromeHidden) { remove([$0]) } }
            .overlay(alignment: .top) { stackStrip.viewerChromeDepth() }
            .keyFocusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            #if DEBUG
                // Screenshots: `PHOTOS_DEBUG_VIEWER_INFO=1` opens the info of the viewer that opens at launch.
                .task {
                    guard ViewerStart.takeDebugInfo(), (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
                    showingInfo = true
                }
            #endif
            .onChange(of: showingInfo) { _, showing in
                if !showing {
                    focused = true
                    infoTop = nil
                }
            }
            #if os(iOS)
                // The stage: no bars, the controls float over the photo (`ViewerStageControls`).
                .statusBarHidden(chromeHidden)
                .toolbar(.hidden, for: .navigationBar, .bottomBar)
                // The navigation stack's own background stays clear: while the photo is dragged down to close, the
                // grid shows through as the backdrop fades.
                .containerBackground(.clear, for: .navigation)
            #else
                .toolbar { toolbar }
            #endif
            .onChange(of: current) { _, id in
                zoomScale = ViewerZoom.minimumScale
                if let id { currentChanged?(id) }
            }
            // SPEC §18.2: the photo and its neighbours stay decoded under memory pressure; a second on screen is a view.
            .task(id: currentFileId) { await session.services?.viewerShows(currentFileId, neighbours: neighbourFileIds) }
            // The neighbours' previews are loaded ahead (SPEC §18.1.2).
            .modifier(ViewerNeighbourPrefetch(pages: shownIds.map { fileId(ofPage: $0) }, current: currentFileId))
            .task(id: currentFileId) {
                guard let current = currentFileId, let library = session.services?.library else { return }
                do {
                    for try await item in library.observeItem(current) { observedItem = item }
                } catch {}
            }
            .navigationTitle(currentItem.map { $0.timestamp.formatted(date: .abbreviated, time: .shortened) } ?? "")
            .hardwareKeys(Self.hardwareKeys) { key in
                if let key = Self.viewerKey(key) {
                    perform(key)
                } else {
                    otherKey(key)
                }
            }
            .viewerCulling(culling, ids: cullingIds, chromeHidden: chromeHidden) { step(1) }
            #if os(macOS)
                // Escape also has to work while the info inspector (or anything else in the window) has the focus.
                .background {
                    Button(String(localized: "Close", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            #endif
    }
}

/// Where the pages are laid out: edge to edge on iPhone and iPad, under the floating controls (SPEC §7.2, §17.1), the
/// visible area elsewhere.
///
/// A scroll view that merely respects the safe area still extends under the sidebar and toolbar with content
/// insets, which shifts paged content. So the pager is given exactly the safe area as its frame, from outside it. On
/// iPad only the top and bottom are left: the info inspector beside the photo is not covered.
private struct ViewerPageArea: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                content.ignoresSafeArea()
            } else {
                content.ignoresSafeArea(.container, edges: .vertical)
            }
        #else
            fitted(content)
        #endif
    }

    func fitted(_ content: Content) -> some View {
        content.clipped()
    }
}

#if DEBUG
    extension ViewerStart {
        /// `PHOTOS_DEBUG_VIEWER=<index>` (debug builds): the viewer to open at launch, once per process.
        @MainActor private static var debugStartUsed = false

        @MainActor static func debugStart(ids: [FileID]) -> ViewerStart? {
            guard !debugStartUsed, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_VIEWER"], let index = Int(raw),
                ids.indices.contains(index)
            else { return nil }
            debugStartUsed = true
            return ViewerStart(ids: ids, startId: ids[index])
        }

        /// `PHOTOS_DEBUG_VIEWER_INFO=1` with `PHOTOS_DEBUG_VIEWER`: the first viewer shows its info; true once.
        @MainActor private static var debugInfoUsed = false

        @MainActor static func takeDebugInfo() -> Bool {
            guard debugStartUsed, !debugInfoUsed, ProcessInfo.processInfo.environment["PHOTOS_DEBUG_VIEWER_INFO"] != nil else {
                return false
            }
            debugInfoUsed = true
            return true
        }
    }
#endif
