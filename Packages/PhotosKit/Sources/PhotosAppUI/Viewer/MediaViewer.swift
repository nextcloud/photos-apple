// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// Full-screen pager over a context (SPEC §7.2).
struct MediaViewer: View {
    let ids: [FileID]
    @State private var current: FileID?
    @State private var chromeHidden = false
    @State private var showingInfo = false
    @State private var confirmDelete = false
    @State private var editing: MediaItem?
    @State private var editingMetadata: MediaItem?
    @State private var extractingText: MediaItem?
    /// Incremented to ask the current video page to play or pause (Space).
    @State private var playbackToggle = 0
    /// Edge the pointer is near, to reveal the previous/next button there.
    @State private var hoverEdge: HorizontalEdge?
    @State private var pagerWidth: CGFloat = 0
    @State private var pageSize: CGSize = .zero
    @FocusState private var focused: Bool
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection

    init(ids: [FileID], startId: FileID) {
        self.ids = ids
        _current = State(initialValue: startId)
    }

    var currentItem: MediaItem? {
        guard let current, let services = session.services else { return nil }
        return try? services.library.item(current)
    }

    /// The paging scroll view. Its pages are as large as the scroll view, so whenever that changes size (sidebar,
    /// info inspector, window resize) the offset of the current page changes too and has to be restored.
    var pager: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        ViewerPage(fileId: id, isCurrent: id == current, playbackToggle: playbackToggle)
                            .containerRelativeFrame([.horizontal, .vertical])
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
            .task(id: pageSize) {
                // Once right away, and once more after the sidebar or inspector animation has settled.
                if let current { reader.scrollTo(current, anchor: .leading) }
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled, let current { reader.scrollTo(current, anchor: .leading) }
            }
        }
    }

    var body: some View {
        pager
        // The black backdrop always fills the window; the pages only do so on iPhone. On the Mac and iPad they
        // stay inside the safe area, so nothing hides under the sidebar, the toolbar or the info inspector.
        .modifier(ViewerPageArea())
        .background(Color.black.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pagerWidth = width
        }
        .onContinuousHover { phase in
            hoverEdge = Self.edge(under: phase, width: pagerWidth)
        }
        .overlay { stepButtons }
        .onTapGesture {
            focused = true
            withAnimation { chromeHidden.toggle() }
        }
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
        .navigationTitle(currentItem.map { $0.timestamp.formatted(date: .abbreviated, time: .shortened) } ?? "")
        .onKeyPress(keys: [.leftArrow, .rightArrow, .escape, .space]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]), let key = Self.viewerKey(press.key) else {
                return .ignored
            }
            perform(key)
            return .handled
        }
        #if os(macOS)
            // Escape also has to work while the info inspector (or anything else in the window) has the focus.
            .background {
                Button(String(localized: "Close", bundle: .module)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        #endif
        .infoInspector(isPresented: $showingInfo) {
            if let item = currentItem { InfoPanel(item: item, inInspector: true) }
        }
        .focusedSceneValue(\.gridActions, viewerActions)
        .sheet(item: $editing) { item in EditorView(item: item) }
        .sheet(item: $editingMetadata) { item in MetadataEditor(items: [item]) }
        .sheet(item: $extractingText) { item in ExtractTextSheet(item: item) }
        .confirmationDialog(String(localized: "Delete this item?", bundle: .module), isPresented: $confirmDelete, titleVisibility: .visible)
        {
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                if let item = currentItem {
                    let next = ViewerNavigation.neighbour(in: ids, of: item.fileId)
                    Task { await session.delete([item]) }
                    if let next { current = next } else { dismiss() }
                }
            }
        }
    }

    /// Menu bar actions for the photo shown.
    var viewerActions: GridActions {
        let item = currentItem
        return GridActions(
            selectionCount: item == nil ? 0 : 1,
            allFavorite: item?.isFavorite ?? false,
            toggleFavorite: { if let item { Task { await session.setFavorite([item], !item.isFavorite) } } },
            delete: { confirmDelete = true },
            toggleInfo: { withAnimation { showingInfo.toggle() } },
            addToAlbum: {},
            zoomIn: nil,
            zoomOut: nil
        )
    }

    func step(_ delta: Int) {
        guard let next = ViewerNavigation.target(in: ids, from: current, delta: delta) else { return }
        withAnimation { current = next }
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
        ViewerNavigation.canStep(in: ids, from: current, delta: delta)
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
                Button {
                    Task { await session.setFavorite([item], !item.isFavorite) }
                } label: {
                    Label(String(localized: "Favorite", bundle: .module), systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                Button {
                    withAnimation { showingInfo.toggle() }
                } label: {
                    Label(String(localized: "Info", bundle: .module), systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
                if item.kind == .image {
                    Button {
                        editing = item
                    } label: {
                        Label(String(localized: "Edit", bundle: .module), systemImage: "slider.horizontal.3")
                    }
                }
                Menu {
                    if item.kind == .image {
                        Button {
                            extractingText = item
                        } label: {
                            Label(String(localized: "Extract text", bundle: .module), systemImage: "text.viewfinder")
                        }
                    }
                    if session.features.has(.metadataEdit) && item.permissions.canWrite {
                        Button {
                            editingMetadata = item
                        } label: {
                            Label(String(localized: "Edit date and location", bundle: .module), systemImage: "calendar.badge.clock")
                        }
                    }
                    Button {
                        Task { try? await MediaExport.saveToPhotoLibrary([item], services: session.services!) }
                    } label: {
                        Label(String(localized: "Save to device", bundle: .module), systemImage: "square.and.arrow.down")
                    }
                    if item.isOwnStorage && item.permissions.canDelete {
                        Button {
                            Task { item.isArchived ? await session.unarchive([item]) : await session.archive([item]) }
                        } label: {
                            Label(
                                item.isArchived
                                    ? String(localized: "Unarchive", bundle: .module) : String(localized: "Archive", bundle: .module),
                                systemImage: "archivebox")
                        }
                    }
                } label: {
                    Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                }
                .disabled(!item.permissions.canDelete)
            }
        }
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

    var title: String {
        delta < 0 ? String(localized: "Previous", bundle: .module) : String(localized: "Next", bundle: .module)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: delta < 0 ? "chevron.backward" : "chevron.forward")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: .circle)
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

/// One page: zoomable photo, Live Photo or video.
struct ViewerPage: View {
    let fileId: FileID
    let isCurrent: Bool
    var playbackToggle = 0
    @Environment(SessionModel.self) private var session
    @State private var item: MediaItem?

    var body: some View {
        Group {
            if let item {
                if item.kind == .video {
                    VideoPage(item: item, isCurrent: isCurrent, playbackToggle: playbackToggle)
                } else {
                    ZoomablePhoto(item: item)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: fileId) {
            item = try? session.services?.library.item(fileId)
        }
    }
}

/// Pinch / double-tap zoom with progressive resolution (SPEC §5.5.2).
struct ZoomablePhoto: View {
    let item: MediaItem
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var playingLive = false

    var bucket: Int { scale > 1.5 ? 4096 : 1024 }

    var body: some View {
        ZStack {
            PreviewImage(item: item, bucket: bucket, contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
            if playingLive, item.livePhotoPeer != nil {
                LivePhotoMotion(item: item)
                    .scaleEffect(scale)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.isLivePhoto {
                Label(String(localized: "Live", bundle: .module), systemImage: "livephoto")
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 60)
                    .padding(.leading, 12)
            }
        }
        .contentShape(.rect)
        .gesture(
            MagnifyGesture()
                .onChanged { value in scale = max(1, min(8, lastScale * value.magnification)) }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1 { reset() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                }
                .onEnded { _ in lastOffset = offset },
            including: scale > 1 ? .all : .subviews
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring) {
                if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
            }
        }
        .onLongPressGesture(minimumDuration: 0.3) {
        } onPressingChanged: { pressing in
            guard item.isLivePhoto else { return }
            withAnimation { playingLive = pressing }
        }
        .accessibilityLabel(item.caption ?? item.name)
    }

    func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

/// Plays the motion part of a Live Photo while pressed.
struct LivePhotoMotion: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?

    var body: some View {
        Group {
            if let player = video?.player {
                PlayerSurface(player: player, showsControls: false)
                    .disabled(true)
                    .onAppear { player.play() }
            } else {
                Color.clear
            }
        }
        .task {
            guard let peer = item.livePhotoPeer, let services = session.services else { return }
            // The motion part is a hidden sibling file; without its row fall back to a QuickTime stream.
            let motion = try? services.library.item(peer)
            video = try? await PlayableVideo.load(
                fileId: peer, etag: motion?.etag, name: motion?.name ?? "live.mov", mimeType: motion?.mimeType ?? "video/quicktime",
                originalURL: motion.map { services.originalURL(for: $0) }, services: services, offline: session.offline)
        }
        .onDisappear { video?.player.pause() }
    }
}

/// The system video player.
///
/// On the Mac this wraps `AVPlayerView` directly: SwiftUI's `VideoPlayer` crashes there when it is the first
/// thing to touch AVKit ("failed to demangle superclass of VideoPlayerView"), as it does in this package.
struct PlayerSurface: View {
    let player: AVPlayer
    var showsControls = true

    var body: some View {
        #if os(macOS)
            MacPlayerView(player: player, showsControls: showsControls)
        #else
            VideoPlayer(player: player)
        #endif
    }
}

#if os(macOS)
    private struct MacPlayerView: NSViewRepresentable {
        let player: AVPlayer
        let showsControls: Bool

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = showsControls ? .floating : .none
            view.videoGravity = .resizeAspect
            view.player = player
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            if view.player !== player { view.player = player }
        }
    }
#endif

/// A player together with what keeps its data flowing.
@MainActor
struct PlayableVideo {
    let player: AVPlayer
    /// Retained here: the asset's resource loader only holds its delegate weakly.
    let loader: StreamingAssetLoader?

    init(file: URL) {
        player = AVPlayer(url: file)
        loader = nil
    }

    init(loader: StreamingAssetLoader, fileName: String) {
        player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset(fileName: fileName)))
        self.loader = loader
    }

    /// Prefers a local copy (offline album, already downloaded original); otherwise streams a temporary
    /// direct-download URL through the app's own HTTP client, so certificates the user trusted and the
    /// account's client certificate apply to video like to everything else (SPEC §5.5.3).
    static func load(
        fileId: FileID, etag: String?, name: String, mimeType: String, originalURL: URL?, services: AccountServices,
        offline: OfflineManager?
    ) async throws -> PlayableVideo {
        if let etag {
            if let local = offline?.localFile(fileId: fileId, etag: etag) { return PlayableVideo(file: local) }
            if let originalURL, let cached = services.images.originals.cached(fileId: fileId, etag: etag, url: originalURL) {
                return PlayableVideo(file: cached)
            }
        }
        let url = try await services.api.directDownloadURL(fileId: fileId)
        let source = MediaByteSource(url: url, headers: ["User-Agent": services.connection.userAgent], http: services.http)
        return PlayableVideo(loader: StreamingAssetLoader(source: source, mimeType: mimeType), fileName: name)
    }
}

/// Video playback from the local copy or streamed through the app's HTTP client (SPEC §5.5.3).
struct VideoPage: View {
    let item: MediaItem
    let isCurrent: Bool
    var playbackToggle = 0
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?
    @State private var error: String?

    var player: AVPlayer? { video?.player }

    var body: some View {
        ZStack {
            if let player {
                PlayerSurface(player: player)
            } else {
                PreviewImage(item: item, bucket: 1024, contentMode: .fit)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
        }
        .task(id: isCurrent) {
            if !isCurrent {
                player?.pause()
                return
            }
            guard video == nil, let services = session.services else { return }
            if MimeTypes.unplayableVideos.contains(item.mimeType) {
                guard session.features.has(.videoRenditions) else {
                    error = String(localized: "This video format can't be played on this device.", bundle: .module)
                    return
                }
                // The server converts on first request (404 while converting); retry for up to 2 minutes.
                for attempt in 0..<12 {
                    if let file = try? await services.api.videoRendition(fileId: item.fileId, etag: item.etag) {
                        video = PlayableVideo(file: file)
                        player?.play()
                        return
                    }
                    error = attempt == 0 ? String(localized: "Preparing video…", bundle: .module) : error
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { return }
                }
                error = String(localized: "The server could not convert this video.", bundle: .module)
                return
            }
            do {
                video = try await PlayableVideo.load(
                    fileId: item.fileId, etag: item.etag, name: item.name, mimeType: item.mimeType,
                    originalURL: services.originalURL(for: item), services: services, offline: session.offline)
                player?.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: playbackToggle) {
            guard isCurrent, let player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }
        .onDisappear { player?.pause() }
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
