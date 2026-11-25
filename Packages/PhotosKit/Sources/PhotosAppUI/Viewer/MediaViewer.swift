// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Full-screen pager over a context (SPEC §7.2).
struct MediaViewer: View {
    let ids: [FileID]
    /// Copies of one shot behind a tile of the grid, by the tile's id (`ViewerStart.stacks`).
    let stacks: [FileID: [FileID]]
    /// Opened from the Library: "Show in library" is not offered.
    let fromLibrary: Bool
    /// Told the tile of the photo shown whenever it changes: the zoom transition goes back into that tile.
    var currentChanged: (@MainActor (FileID) -> Void)?
    /// The copy a stack's page shows, chosen in the strip of its copies, by the tile's id (SPEC VW-6).
    @State private var chosenCopies: [FileID: FileID] = [:]
    /// The page shown: a photo, or the tile of a stack (`currentFileId` is the copy it shows).
    @State private var current: FileID?
    @State private var chromeHidden = false
    @State private var showingInfo = false
    @State private var confirmDelete = false
    @State private var editing: MediaItem?
    @State private var editingMetadata: MediaItem?
    /// The undo history from the More menu (iPhone, iPad; SPEC §16.3.4).
    @State private var showingUndoHistory = false
    @State private var extractingText: MediaItem?
    @State private var addingToAlbum: MediaItem?
    @State private var tagging: MediaItem?
    /// "Make Sticker" (SPEC §15.8.2).
    @State private var stickerItem: MediaItem?
    /// Nextcloud's own sharing of the photo shown (SPEC SH-7).
    @State private var nextcloudShare: SharingTarget?
    /// Slideshow from the photo shown through the viewer's photos (SPEC VW-5).
    @State private var slideshow: SlideshowRequest?
    /// "Show Similar" for the photo shown (SPEC §15.5).
    @State private var similarTo: MediaItem?
    /// "Then and now" of the place of the photo shown (SPEC §15.6).
    @State private var thenAndNow: ThenAndNowStart?
    /// "Send as postcard…" for the photo shown (SPEC §16.7.1).
    @State private var postcard: PostcardStart?
    /// Photos that left the context while the viewer is open (deleted, archived): their pages are gone.
    @State private var removed: Set<FileID> = []
    /// Zoom In / Zoom Out / Zoom to Fit from the menu bar, carried out by the page shown; and that page's scale.
    @State private var zoomCommand: ViewerZoomCommand?
    @State private var zoomScale: CGFloat = ViewerZoom.minimumScale
    /// Where the page is while it is dragged down to close the viewer and while it lands in its tile (iPhone, iPad).
    @State private var dismissPose = ViewerDismissPose.rest
    /// The page fades out instead of flying into its tile (Reduce Motion).
    @State private var exitOpacity: Double = 1
    /// The page's frame in global coordinates, to land the photo in its tile.
    @State private var pageFrame: CGRect = .zero
    /// Top of the info card in global coordinates while it is a sheet (iPhone): the photo moves up above it.
    @State private var infoTop: CGFloat?
    /// The top safe area: the badges on the photo go below the floating controls.
    @State private var topInset: CGFloat = 0
    /// Counted up to put the current page back in place after a page was taken out.
    @State private var realignments = 0
    /// Save to Photos / Export…, with its progress and result.
    @State private var saver = MediaSaveModel()
    /// Incremented to ask the current video page to play or pause (Space).
    @State private var playbackToggle = 0
    /// Edge the pointer is near, to reveal the previous/next button there.
    @State private var hoverEdge: HorizontalEdge?
    @State private var pagerWidth: CGFloat = 0
    @State private var pageSize: CGSize = .zero
    @FocusState private var focused: Bool
    /// The page VoiceOver is on; moved along when the photo is changed with a swipe up or down (adjustable action).
    @AccessibilityFocusState private var accessibilityPage: FileID?
    /// Haptic triggers (iPhone, iPad).
    @State private var favoriteToggles = 0
    @State private var deletions = 0
    /// Ratings and flags given here (SPEC §15.2).
    @State private var culling = CullingModel()
    /// The backdrop's colour from the photo, following the pager (SPEC §16.8.1).
    @State private var tint = ViewerTint()
    @Environment(SessionModel.self) private var session
    /// The window's undo manager: favourite, archive and delete made here are undone with Edit › Undo (⌘Z, shake).
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.showInFolder) private var showInFolder
    @Environment(\.showInTimeline) private var showInTimeline
    @Environment(\.colorScheme) private var colorScheme
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.viewerExit) private var viewerExit

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
            .infoInspector(isPresented: $showingInfo) {
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
            let isSheet = false
        #else
            let isSheet: Bool = horizontalSizeClass == .compact
        #endif
        guard showingInfo, isSheet, let infoTop else { return (1, 0) }
        let top: CGFloat = topInset + 56 - pageFrame.minY
        return ViewerStage.infoPlacement(content: currentContentSize, page: pageSize, top: top, bottom: infoTop - pageFrame.minY - 8)
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
            .overlay(alignment: .top) { stackStrip.viewerChromeDepth() }
            .keyFocusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
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
                    cullingKey(key)
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

    /// Menu bar actions for the photo shown.
    var viewerActions: GridActions {
        let item: MediaItem? = currentItem
        let isImage: Bool = item?.kind == .image
        let zoomed: Bool = ViewerZoom.isZoomed(zoomScale)
        var actions = GridActions(
            selectionCount: item == nil ? 0 : 1,
            allFavorite: item?.isFavorite ?? false,
            toggleFavorite: { if let item { toggleFavorite(item) } },
            delete: { if item?.permissions.canDelete == true { confirmDelete = true } },
            toggleInfo: { toggleInfo() },
            addToAlbum: { addingToAlbum = item },
            zoomIn: isImage && zoomScale < ViewerZoom.maximumScale - ViewerZoom.epsilon ? { zoom(.zoomIn) } : nil,
            zoomOut: isImage && zoomed ? { zoom(.zoomOut) } : nil
        )
        actions.zoomToFit = isImage && zoomed ? { zoom(.fit) } : nil
        guard let item else { return actions }
        if isImage {
            actions.edit = { editing = item }
            // Image ▸ Rotate: an edit of the photo shown (SPEC §16.3), undoable.
            actions.rotate = { clockwise in
                let undoManager = undoManager
                Task { await session.rotate([item], clockwise: clockwise, undoManager: undoManager) }
            }
        }
        if canEditMetadata(item) { actions.editDateAndLocation = { editingMetadata = item } }
        actions.export = { save(item) }
        if let services = session.services { actions.shareItems = [ShareableMedia(item: item, services: services)] }
        actions.shareTitle = item.name
        actions.slideshow = { playSlideshow() }
        if session.features.has(.systemtags) {
            let ids = cullingIds
            actions.cull = { command in culling.apply(command, ids: ids, session: session, undoManager: undoManager) }
        }
        #if os(macOS)
            if isImage, !item.isCollectionChild {
                actions.editWith = EditWithTarget(item: item) { app in ExternalEditCenter.shared.open(item, with: app, session: session) }
            }
            if DesktopPictureAction.isOffered(item) { actions.useAsDesktopPicture = { DesktopPictureAction.use(item, session: session) } }
        #endif
        return actions
    }

    func zoom(_ kind: ViewerZoomCommand.Kind) {
        zoomCommand = ViewerZoomCommand(id: (zoomCommand?.id ?? 0) + 1, kind: kind)
    }

    func canEditMetadata(_ item: MediaItem) -> Bool {
        item.permissions.canWrite && !item.isCollectionChild
    }

    /// Saves the original: into a folder the user picks on the Mac (as "Export…" in the grid), to the photo library elsewhere.
    func save(_ item: MediaItem) {
        guard let services = session.services else { return }
        saver.save([item], services: services)
    }

    /// An archived photo leaves the place it was opened from, so the viewer moves on. Unarchiving stays: the photo
    /// is shown again everywhere, and "Archive" in the same menu takes it back.
    func toggleArchive(_ item: MediaItem) {
        let undoManager = undoManager
        if item.isArchived {
            Task { await session.perform(.unarchive([item]), undoManager: undoManager) }
        } else {
            Task { await session.perform(.archive([item]), undoManager: undoManager) }
            remove([item.fileId])
        }
    }

    /// Follows changes announced by the session: a photo archived or deleted elsewhere (or again, with Redo) leaves
    /// the viewer; one brought back with Undo gets its page back, where it was in the context.
    func apply(_ change: ViewerPageChange) {
        switch change {
        case .none:
            break
        case .remove(let ids):
            let gone: Set<FileID> = ids.filter { isInContext($0) }
            guard !gone.isEmpty else { return }
            remove(gone)
        case .restore(let ids):
            let library = session.services?.library
            // Only photos that are in the library again (a restore from the trash bin can fail).
            let back: Set<FileID> = removed.intersection(ids).filter { id in (try? library?.item(id)) != nil }
            guard !back.isEmpty else { return }
            removed.subtract(back)
            realignments += 1
        }
    }

    /// A photo of this viewer: a page, or a copy in a stack.
    func isInContext(_ id: FileID) -> Bool {
        ids.contains(id) || ViewerStacks.tile(of: id, in: stacks) != nil
    }

    /// The photos are gone from this context (deleted, archived). A stack's page stays while one of its copies does and
    /// shows that one; a page that is gone is taken out and the next one shown — the previous one after the last, and
    /// the viewer closes after the only one.
    func remove(_ gone: Set<FileID>) {
        let after: Set<FileID> = removed.union(gone)
        if let current, ViewerStacks.pages([current], stacks: stacks, removed: after).isEmpty {
            // The other pages first, so that the page shown next is one that stays.
            removed = after.subtracting(ViewerStacks.copies(of: current, stacks: stacks))
            guard let next = ViewerNavigation.neighbour(in: shownIds, of: current) else {
                dismiss()
                return
            }
            self.current = next
        }
        removed = after
        realignments += 1
    }

    // MARK: Page events

    var pageEvents: ViewerPage.Events {
        ViewerPage.Events(
            tapped: { pageTapped() },
            scaleChanged: { scale in zoomScale = scale },
            verticalDrag: { phase in handleSwipe(phase) })
    }

    /// A tap on a photo hides or shows the bars (iPhone, iPad); on the Mac it gives the viewer the keyboard.
    func pageTapped() {
        focused = true
        #if os(iOS)
            withAnimation(reduceMotion ? nil : .default) { chromeHidden.toggle() }
        #endif
    }

    /// Swipe down closes the viewer, swipe up shows the info panel (SPEC VW-1, §7.4). Dragged down, the photo follows
    /// the finger and shrinks while the grid comes back behind it; let go, it lands in its tile or springs back
    /// (SPEC §17.1). With the info card open, a swipe down closes the card.
    func handleSwipe(_ phase: ViewerSwipe.Phase) {
        switch phase {
        case .changed(let translation):
            guard !showingInfo, translation.height > 0 || dismissPose != .rest else { return }
            if dismissPose == .rest { viewerExit?.setTileHidden(landingTile != nil) }
            dismissPose = ViewerDismissal.dragPose(
                translation: CGSize(width: translation.width, height: max(0, translation.height)), page: pageSize,
                photo: currentPhotoRect)
        case .ended(let translation, let velocity):
            switch ViewerSwipe.outcome(translation: translation.height, velocity: velocity.dy) {
            case .dismiss:
                if showingInfo {
                    toggleInfo()
                } else {
                    land(velocity: velocity)
                }
            case .showInfo:
                settle(velocity: .zero)
                if !showingInfo { toggleInfo() }
            case .none:
                settle(velocity: velocity)
            }
        case .cancelled:
            settle(velocity: .zero)
        }
    }

    /// The tile of the page shown, when the grid behind has it on screen.
    var landingTile: CGRect? {
        guard let current, let tile = viewerExit?.tileFrame(current) else { return nil }
        let screen: CGRect = pageFrame.isEmpty ? CGRect(origin: .zero, size: pageSize) : pageFrame
        return ViewerDismissal.isLandable(tile: tile, screen: screen) ? tile : nil
    }

    /// Lands the photo in its tile with a spring that starts at the finger's speed, then closes at once. Without a tile
    /// on screen the viewer closes the usual way; with Reduce Motion the photo fades out where it is.
    func land(velocity: CGVector) {
        guard let viewerExit, let tile = landingTile else {
            viewerExit?.setTileHidden(false)
            dismiss()
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                exitOpacity = 0
            } completion: {
                viewerExit.closeImmediately()
            }
            return
        }
        let target: ViewerDismissPose = ViewerDismissal.landingPose(
            tile: tile, pageOrigin: pageFrame.origin, page: pageSize, photo: currentPhotoRect)
        let speed: Double = ViewerDismissal.springVelocity(velocity, from: dismissPose.offset, to: target.offset)
        withAnimation(.interpolatingSpring(duration: 0.38, bounce: 0, initialVelocity: speed)) {
            dismissPose = target
        } completion: {
            viewerExit.closeImmediately()
        }
    }

    /// Back to the full stage: a spring from the finger's speed, or at once with Reduce Motion.
    func settle(velocity: CGVector) {
        guard dismissPose != .rest else { return }
        let speed: Double = ViewerDismissal.springVelocity(velocity, from: dismissPose.offset, to: .zero)
        withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: speed)) {
            dismissPose = .rest
        } completion: {
            if dismissPose == .rest { viewerExit?.setTileHidden(false) }
        }
    }

    func step(_ delta: Int) {
        guard let next = ViewerNavigation.target(in: shownIds, from: current, delta: delta) else { return }
        // Reduce Motion: the next photo replaces the current one instead of sliding in.
        withAnimation(reduceMotion ? nil : .default) { current = next }
    }

    func toggleFavorite(_ item: MediaItem) {
        favoriteToggles += 1
        let undoManager = undoManager
        Task { await session.perform(.favorite([item], value: !item.isFavorite), undoManager: undoManager) }
    }

    /// The files a rating or flag goes to: the photo shown, or every copy of a stacked tile (as in the grid).
    var cullingIds: [FileID] {
        if let current, let members = stacks[current], members.count > 1 { return members.filter { !removed.contains($0) } }
        return currentFileId.map { [$0] } ?? []
    }

    func toggleInfo() {
        withAnimation(reduceMotion ? nil : .default) { showingInfo.toggle() }
    }

    /// What VoiceOver offers on a page: swipe up/down for the next or previous photo, and the main actions in the
    /// actions rotor (share stays a button in the toolbar: a share sheet cannot be opened without one).
    var accessibilityActions: ViewerPage.AccessibilityActions {
        ViewerPage.AccessibilityActions(
            step: { delta in
                step(delta)
                accessibilityPage = current
            },
            toggleFavorite: { if let item = currentItem { toggleFavorite(item) } },
            showInfo: { toggleInfo() },
            delete: { if currentItem?.permissions.canDelete == true { confirmDelete = true } },
            zoom: { kind in zoom(kind) })
    }

    /// The viewer's plain keys. On iPhone and iPad the rating keys are among them: the viewer is not focusable there, so
    /// the `onKeyPress` of `viewerCulling` does not get them (see `hardwareKeys`).
    static var hardwareKeys: [KeyEquivalent] {
        var keys: [KeyEquivalent] = [.leftArrow, .rightArrow, .escape, .space]
        #if os(iOS)
            keys += "pxu012345".map { KeyEquivalent($0) }
        #endif
        return keys
    }

    /// A rating or flag key (iPhone and iPad), as `viewerCulling` handles it on the Mac.
    func cullingKey(_ key: KeyEquivalent) {
        guard session.features.has(.systemtags), let command = CullingCommand(key: key.character) else { return }
        culling.apply(command, ids: cullingIds, session: session, undoManager: undoManager)
        if CullingSettings.autoAdvance {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                step(1)
            }
        }
    }

    static func viewerKey(_ key: KeyEquivalent) -> ViewerNavigation.Key? {
        switch key {
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .escape: .escape
        case .space: .space
        default: nil
        }
    }

    func perform(_ key: ViewerNavigation.Key) {
        let isVideo = currentItem?.kind == .video
        switch ViewerNavigation.command(for: key, isVideo: isVideo, rightToLeft: layoutDirection == .rightToLeft) {
        case .previous: step(-1)
        case .next: step(1)
        case .close: dismiss()
        case .togglePlayback: playbackToggle += 1
        }
    }

    /// The edge whose previous/next button the pointer is close enough to reveal.
    static func edge(under phase: HoverPhase, width: CGFloat) -> HorizontalEdge? {
        guard case .active(let location) = phase, width > 0 else { return nil }
        let zone = min(140, width / 4)
        if location.x < zone { return .leading }
        if location.x > width - zone { return .trailing }
        return nil
    }

    /// Previous/next buttons at the edges: shown under the pointer (Mac, iPad with a pointer), always there for accessibility.
    var stepButtons: some View {
        HStack {
            ViewerStepButton(delta: -1, isVisible: hoverEdge == .leading, isEnabled: canStep(-1)) { step(-1) }
            Spacer(minLength: 0)
            ViewerStepButton(delta: 1, isVisible: hoverEdge == .trailing, isEnabled: canStep(1)) { step(1) }
        }
        .padding(.horizontal, 12)
    }

    func canStep(_ delta: Int) -> Bool {
        ViewerNavigation.canStep(in: shownIds, from: current, delta: delta)
    }

    #if os(iOS)
        /// The floating glass controls (SPEC §17.1); a tap on the photo hides and shows them.
        var stageControls: some View {
            ViewerStageControls(
                item: currentItem, isVisible: !chromeHidden, dismissProgress: dismissPose.progress,
                close: { dismiss() },
                toggleFavorite: { item in toggleFavorite(item) },
                toggleInfo: { toggleInfo() },
                edit: { item in editing = item },
                delete: { confirmDelete = true },
                more: { item in moreActions(item) }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.top
            } action: { inset in
                topInset = inset
            }
        }
    #endif

    #if !os(iOS)
        @ToolbarContentBuilder var toolbar: some ToolbarContent {
            toolbarItems
        }
    #endif

    @ToolbarContentBuilder var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: viewerPlacement) {
            if let item = currentItem {
                ShareMediaButton(items: [item])
                    .help(String(localized: "Share", bundle: .module))
                Button {
                    toggleFavorite(item)
                } label: {
                    // Says what pressing it does; the filled heart shows the state.
                    Label(Self.favoriteTitle(remove: item.isFavorite), systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                .help(Self.favoriteTitle(remove: item.isFavorite))
                Button {
                    toggleInfo()
                } label: {
                    Label(String(localized: "Info", bundle: .module), systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help(String(localized: "Info", bundle: .module))
                #if os(visionOS)
                    // Spatial photos and panoramas (SPEC §6.2 visionOS specifics).
                    SpatialViewerButton(item: item)
                #endif
                if item.kind == .image {
                    Button {
                        editing = item
                    } label: {
                        Label(String(localized: "Edit", bundle: .module), systemImage: "slider.horizontal.3")
                    }
                    .help(String(localized: "Edit", bundle: .module))
                }
                Menu {
                    moreActions(item)
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "More", bundle: .module))
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
                .help(String(localized: "Delete", bundle: .module))
                .disabled(!item.permissions.canDelete)
            }
        }
    }

    /// The More menu: add to album, save · extract text, edit date and location · archive.
    @ViewBuilder func moreActions(_ item: MediaItem) -> some View {
        let albumTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Add to Album…", bundle: .module),
            other: LocalizedStringResource("Add to album…", bundle: .module))
        Button {
            addingToAlbum = item
        } label: {
            Label(albumTitle, systemImage: "rectangle.stack.badge.plus")
        }
        if session.features.has(.systemtags) {
            Button {
                tagging = item
            } label: {
                Label(TagWording.menuTitle, systemImage: "tag")
            }
        }
        Button {
            save(item)
        } label: {
            Label(PhotosCommands.exportTitle, systemImage: "square.and.arrow.down")
        }
        .disabled(saver.isRunning)
        EditedItemMenuItems(item: item, saver: saver)
        if item.permissions.canShare && session.services != nil {
            Button {
                nextcloudShare = SharingTarget(item: item)
            } label: {
                Label(String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus")
            }
        }
        PostcardMenuItem(item: item, start: $postcard)
        Button {
            playSlideshow()
        } label: {
            Label(SlideshowRequest.menuTitle, systemImage: SlideshowRequest.systemImage)
        }
        #if os(macOS)
            if DesktopPictureAction.isOffered(item) {
                Button {
                    DesktopPictureAction.use(item, session: session)
                } label: {
                    Label(DesktopPictureAction.title, systemImage: DesktopPictureAction.systemImage)
                }
            }
        #endif
        ThenAndNowMenuItem(item: item, start: $thenAndNow)
        if showInFolder != nil {
            Button {
                showFolder(item)
            } label: {
                Label(ShowInFolderAction.title, systemImage: ShowInFolderAction.systemImage)
            }
        }
        if showInTimeline != nil, !fromLibrary, ShowInTimelineAction.isOffered(for: item) {
            Button {
                showTimeline(item)
            } label: {
                Label(ShowInTimelineAction.title, systemImage: ShowInTimelineAction.systemImage)
            }
        }
        if SimilarPhotosAction.isOffered(for: item.kind) {
            Button {
                similarTo = item
            } label: {
                Label(SimilarPhotosAction.title, systemImage: SimilarPhotosAction.systemImage)
            }
        }
        Divider()
        if item.kind == .image {
            Button {
                extractingText = item
            } label: {
                Label(String(localized: "Extract text", bundle: .module), systemImage: "text.viewfinder")
            }
            Button {
                stickerItem = item
            } label: {
                Label(StickerWording.menuTitle, systemImage: "face.smiling")
            }
        }
        if canEditMetadata(item) {
            Button {
                editingMetadata = item
            } label: {
                Label(String(localized: "Edit date and location", bundle: .module), systemImage: "calendar.badge.clock")
            }
        }
        if session.features.has(.systemtags) {
            Divider()
            CullingMenuItems { command in
                culling.apply(command, ids: cullingIds, session: session, undoManager: undoManager)
            }
        }
        #if !os(macOS)
            // The Mac has it in the Edit menu.
            Button {
                showingUndoHistory = true
            } label: {
                Label(ChangeWording.historyMenuTitle, systemImage: "clock.arrow.circlepath")
            }
        #endif
        if item.isOwnStorage && item.permissions.canDelete {
            Divider()
            Button {
                toggleArchive(item)
            } label: {
                Label(
                    item.isArchived
                        ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                    systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
    }

    /// Opens the folder browser at the photo's folder; the viewer closes, as Back would leave it.
    func showFolder(_ item: MediaItem) {
        guard let showInFolder else { return }
        dismiss()
        showInFolder(item)
    }

    /// Opens the Library at the photo's day with the photo highlighted; the viewer closes.
    func showTimeline(_ item: MediaItem) {
        guard let showInTimeline else { return }
        dismiss()
        showInTimeline(item)
    }

    /// A slideshow of the viewer's photos, from the one shown on (SPEC VW-5).
    func playSlideshow() {
        let title: String = String(localized: "Slideshow", bundle: .module)
        slideshow = SlideshowRequest(title: title, ids: shownIds.map { fileId(ofPage: $0) }, startId: currentFileId)
    }

    /// After the slideshow the viewer shows the photo it ended on.
    func showAfterSlideshow(_ last: FileID) {
        let page: FileID = shownIds.contains(last) ? last : (ViewerStacks.tile(of: last, in: stacks) ?? last)
        guard shownIds.contains(page), page != current else { return }
        current = page
        realignments += 1
    }

    // MARK: Stacks

    /// The copies of the stack shown, the tile's first; nil for a photo that is in no stack (or has one copy left).
    var currentStack: [FileID]? {
        guard let current, stacks[current] != nil else { return nil }
        let copies: [FileID] = ViewerStacks.copies(of: current, stacks: stacks, removed: removed)
        return copies.count > 1 ? copies : nil
    }

    /// Shows another copy of the stack on its page.
    func choose(copy: FileID) {
        guard let current else { return }
        chosenCopies[current] = copy
        zoomScale = ViewerZoom.minimumScale
    }

    /// Above a stacked photo: a strip of its copies (RAW, HEIC, JPEG…); the one shown is marked, another one is shown
    /// with a tap or click. On iPhone and iPad it sits below the floating controls.
    @ViewBuilder var stackStrip: some View {
        if let copies = currentStack, let shown = currentFileId, !chromeHidden {
            StackStrip(copies: copies, shown: shown) { copy in choose(copy: copy) }
                #if os(iOS)
                    .padding(.top, 62)
                #else
                    .padding(.top, 10)
                #endif
        }
    }

    /// "Copy 2 of 3 · IMG_1234.DNG".
    static func copyPosition(index: Int, count: Int, name: String) -> String {
        String(localized: "Copy \(index + 1) of \(count) · \(name)", bundle: .module)
    }

    /// What the favourite button does: title case on the Mac, sentence case elsewhere.
    static func favoriteTitle(remove: Bool) -> String {
        remove
            ? PlatformWording.title(
                mac: LocalizedStringResource("Remove from Favorites", bundle: .module),
                other: LocalizedStringResource("Remove from favorites", bundle: .module))
            : PlatformWording.title(
                mac: LocalizedStringResource("Add to Favorites", bundle: .module),
                other: LocalizedStringResource("Add to favorites", bundle: .module))
    }

    var viewerPlacement: ToolbarItemPlacement {
        #if os(visionOS)
            // A glass ornament under the window, beside the photo rather than over it (SPEC §17.7).
            .bottomOrnament
        #else
            .primaryAction
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

/// Round previous/next button at an edge of the viewer.
private struct ViewerStepButton: View {
    let delta: Int
    let isVisible: Bool
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var increasedContrast: Bool { contrast == .increased || reduceTransparency }

    var title: String {
        delta < 0 ? String(localized: "Previous", bundle: .module) : String(localized: "Next", bundle: .module)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: delta < 0 ? "chevron.backward" : "chevron.forward")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(OverlayLegibility.scrimOpacity(base: 0.45, increased: increasedContrast)), in: .circle)
                .contentShape(.circle)
                // Only the artwork fades: a button with zero opacity would also vanish for VoiceOver and keyboard users.
                .opacity(isVisible && isEnabled ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isVisible)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isVisible)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Zoom In / Zoom Out / Zoom to Fit in the actions menu of assistive technologies (photos only).
private struct ZoomAccessibilityActions: ViewModifier {
    let isPhoto: Bool
    let zoom: (ViewerZoomCommand.Kind) -> Void

    func body(content: Content) -> some View {
        if isPhoto {
            content
                .accessibilityAction(named: Text("Zoom In", bundle: .module)) { zoom(.zoomIn) }
                .accessibilityAction(named: Text("Zoom Out", bundle: .module)) { zoom(.zoomOut) }
                .accessibilityAction(named: Text("Zoom to Fit", bundle: .module)) { zoom(.fit) }
        } else {
            content
        }
    }
}

/// Favourite, Info and Delete in the actions menu of assistive technologies.
private struct ViewerPageActions: ViewModifier {
    let offered: Bool
    let favoriteTitle: String
    let actions: ViewerPage.AccessibilityActions

    func body(content: Content) -> some View {
        if offered {
            content
                .accessibilityAction(named: Text(favoriteTitle)) { actions.toggleFavorite() }
                .accessibilityAction(named: Text("Info", bundle: .module)) { actions.showInfo() }
                .accessibilityAction(named: Text("Delete", bundle: .module)) { actions.delete() }
        } else {
            content
        }
    }
}

/// One page: zoomable photo, Live Photo or video.
struct ViewerPage: View {
    /// The viewer's actions, offered to VoiceOver on the page.
    struct AccessibilityActions {
        var step: (Int) -> Void = { _ in }
        var toggleFavorite: () -> Void = {}
        var showInfo: () -> Void = {}
        var delete: () -> Void = {}
        var zoom: (ViewerZoomCommand.Kind) -> Void = { _ in }
    }

    /// What the page tells the viewer. Taps are reported by photo pages only: a video page leaves every touch to
    /// the system player, whose controls must not sit under a gesture of the viewer.
    @MainActor
    struct Events {
        var tapped: () -> Void = {}
        var scaleChanged: (CGFloat) -> Void = { _ in }
        var verticalDrag: (ViewerSwipe.Phase) -> Void = { _ in }
    }

    let fileId: FileID
    let isCurrent: Bool
    var playbackToggle = 0
    /// "3 of 120".
    var position = ""
    var actions = AccessibilityActions()
    var zoomCommand: ViewerZoomCommand?
    var events = Events()
    /// Favourite, Info and Delete for assistive technologies; not in Guest Mode (SPEC §16.8.3).
    var offersActions = true
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var item: MediaItem?
    /// The library was asked for the photo; with no `item`, the library does not have it (any more).
    @State private var isLoaded = false
    /// Names of the recognised people, loaded for the photo shown while VoiceOver runs.
    @State private var people: [String] = []

    var body: some View {
        Group {
            if let item {
                if item.kind == .video {
                    // The player's own controls stay reachable inside the page.
                    VideoPage(item: item, isCurrent: isCurrent, playbackToggle: playbackToggle, verticalDrag: events.verticalDrag)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(description(of: item))
                } else {
                    ZoomablePhoto(item: item, isCurrent: isCurrent, command: zoomCommand, events: photoEvents)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(description(of: item))
                        .accessibilityValue(position)
                        .accessibilityAddTraits(.isImage)
                        // The zoom gestures of VoiceOver and other assistive technologies.
                        .accessibilityZoomAction { action in
                            switch action.direction {
                            case .zoomIn: actions.zoom(.zoomIn)
                            case .zoomOut: actions.zoom(.zoomOut)
                            @unknown default: break
                            }
                        }
                        // Swipe up or down with VoiceOver: next or previous photo.
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: actions.step(1)
                            case .decrement: actions.step(-1)
                            @unknown default: break
                            }
                        }
                }
            } else if isLoaded {
                // Removed by a sync or a delete made elsewhere: say so instead of loading for ever.
                ContentUnavailableView(
                    String(localized: "This item is no longer available", bundle: .module), systemImage: "photo",
                    description: Text("It was deleted or moved on the server.", bundle: .module)
                )
                // On the stage's colour (black or white).
                .foregroundStyle(.primary)
            } else {
                // Read from the local index in a few milliseconds: nothing to show for that moment.
                Color.clear
            }
        }
        .modifier(ViewerPageActions(offered: offersActions, favoriteTitle: favoriteActionTitle, actions: actions))
        .modifier(ZoomAccessibilityActions(isPhoto: item?.kind == .image, zoom: actions.zoom))
        .task(id: fileId) {
            // Observed, so the VoiceOver favourite action and description follow a toggle.
            guard let library = session.services?.library else { return }
            do {
                for try await value in library.observeItem(fileId) {
                    item = value
                    isLoaded = true
                }
            } catch {}
        }
        .task(id: PeopleRequest(fileId: fileId, wanted: isCurrent && voiceOver)) {
            guard isCurrent, voiceOver, item?.kind == .image, let path = item?.path, session.features.has(.recognize),
                let services = session.services
            else { return }
            let faces = (try? await services.api.faceDetections(userPath: path)) ?? []
            people = faces.compactMap(\.title).filter { !$0.isEmpty }
        }
    }

    var photoEvents: ZoomSurfaceEvents {
        let isCurrent: Bool = isCurrent
        let events: Events = events
        return ZoomSurfaceEvents(
            // A page that is paged away goes back to the fitted size; that is not the scale of the photo shown.
            scaleChanged: { scale in if isCurrent { events.scaleChanged(scale) } },
            tapped: events.tapped,
            verticalDrag: { phase in if isCurrent { events.verticalDrag(phase) } })
    }

    struct PeopleRequest: Hashable {
        var fileId: FileID
        var wanted: Bool
    }

    var favoriteActionTitle: String {
        MediaViewer.favoriteTitle(remove: item?.isFavorite ?? false)
    }

    /// "Photo, 22 November 2026 at 14:03, Lisbon, with Anna and Ben, Favorite, A dog on the beach".
    func description(of item: MediaItem) -> String {
        AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
            place: item.place, people: people, isFavorite: item.isFavorite,
            // The server's caption, else the description written on this device (SPEC §16.2).
            caption: item.caption ?? session.services?.descriptions.text(of: item.fileId))
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
    }
#endif

/// What a change announced by the session (`SessionModel.lastChange`) means for the viewer's pages.
enum ViewerPageChange: Equatable {
    case none
    /// The photos left the context (archived, deleted): their pages are taken out.
    case remove(Set<FileID>)
    /// The change was undone: the photos are back and so are their pages.
    case restore(Set<FileID>)

    init(_ notice: ChangeNotice) {
        let ids: Set<FileID>
        switch notice.change {
        case .archive, .delete:
            // Only the photos the change really altered (an archived photo is not archived again).
            ids = Set(notice.change.fileIds)
        default:
            self = .none
            return
        }
        guard !ids.isEmpty else {
            self = .none
            return
        }
        self = notice.isReverted ? .restore(ids) : .remove(ids)
    }
}
