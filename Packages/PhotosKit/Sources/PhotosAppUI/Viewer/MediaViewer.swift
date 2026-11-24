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
    @State private var extractingText: MediaItem?
    @State private var addingToAlbum: MediaItem?
    @State private var tagging: MediaItem?
    /// Nextcloud's own sharing of the photo shown (SPEC SH-7).
    @State private var nextcloudShare: SharingTarget?
    /// Slideshow from the photo shown through the viewer's photos (SPEC VW-5).
    @State private var slideshow: SlideshowRequest?
    /// Photos that left the context while the viewer is open (deleted, archived): their pages are gone.
    @State private var removed: Set<FileID> = []
    /// Zoom In / Zoom Out / Zoom to Fit from the menu bar, carried out by the page shown; and that page's scale.
    @State private var zoomCommand: ViewerZoomCommand?
    @State private var zoomScale: CGFloat = ViewerZoom.minimumScale
    /// How far the page is dragged down to close the viewer (iPhone, iPad).
    @State private var dragTranslation: CGFloat = 0
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
    @Environment(SessionModel.self) private var session
    /// The window's undo manager: favourite, archive and delete made here are undone with Edit › Undo (⌘Z, shake).
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.showInFolder) private var showInFolder
    @Environment(\.showInTimeline) private var showInTimeline

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
                if let item = currentItem { InfoPanel(item: item, inInspector: true, showsPreview: false) }
            }
            .focusedSceneValue(\.gridActions, viewerActions)
            .sheet(item: $editing) { item in EditorView(item: item) }
            .sheet(item: $editingMetadata) { item in MetadataEditor(items: [item]) }
            .sheet(item: $extractingText) { item in ExtractTextSheet(item: item) }
            .sheet(item: $addingToAlbum) { item in AlbumPickerSheet(items: [item]) }
            .sheet(item: $tagging) { item in TagEditorSheet(items: [item]) }
            .sheet(item: $nextcloudShare) { target in
                if let services = session.services { FileSharingSheet(target: target, api: services.api.sharing) }
            }
            .slideshow($slideshow) { last in showAfterSlideshow(last) }
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

    /// The pager with its backdrop, bars, keyboard and focus.
    var page: some View {
        pager
            // The black backdrop always fills the window; the pages only do so on iPhone. On the Mac and iPad they
            // stay inside the safe area, so nothing hides under the sidebar, the toolbar or the info inspector.
            .modifier(ViewerPageArea())
            // Dragged down to close: the page follows the finger and shrinks, the backdrop fades to what is behind.
            .scaleEffect(ViewerSwipe.pageScale(progress: dismissProgress))
            .offset(y: max(0, dragTranslation))
            .background(Color.black.opacity(1 - dismissProgress).ignoresSafeArea())
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                pagerWidth = width
            }
            .onContinuousHover { phase in
                hoverEdge = Self.edge(under: phase, width: pagerWidth)
            }
            .overlay { stepButtons }
            .overlay(alignment: .top) { stackStrip }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: showingInfo) { _, showing in
                if !showing { focused = true }
            }
            #if os(iOS)
                .statusBarHidden(chromeHidden)
                .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            #endif
            .toolbar { toolbar }
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
            .onKeyPress(keys: [.leftArrow, .rightArrow, .escape, .space]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]), let key = Self.viewerKey(press.key) else {
                    return .ignored
                }
                perform(key)
                return .handled
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
        if isImage { actions.edit = { editing = item } }
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
        #endif
        return actions
    }

    func zoom(_ kind: ViewerZoomCommand.Kind) {
        zoomCommand = ViewerZoomCommand(id: (zoomCommand?.id ?? 0) + 1, kind: kind)
    }

    func canEditMetadata(_ item: MediaItem) -> Bool {
        session.features.has(.metadataEdit) && item.permissions.canWrite
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

    var dismissProgress: CGFloat {
        ViewerSwipe.dismissProgress(translation: dragTranslation, height: pageSize.height)
    }

    /// Swipe down closes the viewer, swipe up shows the info panel (SPEC VW-1, §7.4).
    func handleSwipe(_ phase: ViewerSwipe.Phase) {
        switch phase {
        case .changed(let translation):
            dragTranslation = translation
        case .ended(let translation, let velocity):
            switch ViewerSwipe.outcome(translation: translation, velocity: velocity) {
            case .dismiss:
                // The page stays where the finger left it; the cover takes it away from there.
                dismiss()
            case .showInfo:
                dragTranslation = 0
                if !showingInfo { toggleInfo() }
            case .none:
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { dragTranslation = 0 }
            }
        case .cancelled:
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { dragTranslation = 0 }
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

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
                }
            }
        #endif
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
        if item.permissions.canShare && session.services != nil {
            Button {
                nextcloudShare = SharingTarget(item: item)
            } label: {
                Label(String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus")
            }
        }
        Button {
            playSlideshow()
        } label: {
            Label(SlideshowRequest.menuTitle, systemImage: SlideshowRequest.systemImage)
        }
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
        Divider()
        if item.kind == .image {
            Button {
                extractingText = item
            } label: {
                Label(String(localized: "Extract text", bundle: .module), systemImage: "text.viewfinder")
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
    /// with a tap or click.
    @ViewBuilder var stackStrip: some View {
        if let copies = currentStack, let shown = currentFileId, !chromeHidden {
            StackStrip(copies: copies, shown: shown) { copy in choose(copy: copy) }
                .padding(.top, 10)
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
        #if os(iOS)
            .bottomBar
        #else
            .primaryAction
        #endif
    }
}

/// Where the pages are laid out: edge to edge on iPhone (SPEC §7.2), the visible area elsewhere.
///
/// A scroll view that merely respects the safe area still extends under the sidebar and toolbar with content
/// insets, which shifts paged content. So the pager is given exactly the safe area as its frame, from outside it.
private struct ViewerPageArea: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                content.ignoresSafeArea()
            } else {
                fitted(content)
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
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .accessibilityAction(named: Text(favoriteActionTitle)) { actions.toggleFavorite() }
        .accessibilityAction(named: Text("Info", bundle: .module)) { actions.showInfo() }
        .accessibilityAction(named: Text("Delete", bundle: .module)) { actions.delete() }
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
            place: item.place, people: people, isFavorite: item.isFavorite, caption: item.caption)
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
