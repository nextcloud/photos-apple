// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// Full-screen pager over a context (SPEC §7.2).
struct MediaViewer: View {
    let ids: [FileID]
    @State private var current: FileID?
    @State private var chromeHidden = false
    @State private var infoItem: MediaItem?
    @State private var confirmDelete = false
    @State private var editing: MediaItem?
    @State private var editingMetadata: MediaItem?
    @State private var extractingText: MediaItem?
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    init(ids: [FileID], startId: FileID) {
        self.ids = ids
        _current = State(initialValue: startId)
    }

    var currentItem: MediaItem? {
        guard let current, let services = session.services else { return nil }
        return try? services.library.item(current)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    ViewerPage(fileId: id, isCurrent: id == current)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .background(Color.black)
        .ignoresSafeArea()
        .onTapGesture { withAnimation { chromeHidden.toggle() } }
        #if os(iOS)
            .statusBarHidden(chromeHidden)
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        #endif
        .toolbar { toolbar }
        .navigationTitle(currentItem.map { $0.timestamp.formatted(date: .abbreviated, time: .shortened) } ?? "")
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .sheet(item: $infoItem) { item in
            NavigationStack { InfoPanel(item: item) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { item in EditorView(item: item) }
        .sheet(item: $editingMetadata) { item in MetadataEditor(items: [item]) }
        .sheet(item: $extractingText) { item in ExtractTextSheet(item: item) }
        .confirmationDialog(String(localized: "Delete this item?", bundle: .module), isPresented: $confirmDelete, titleVisibility: .visible)
        {
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                if let item = currentItem {
                    let next = neighbour(of: item.fileId)
                    Task { await session.delete([item]) }
                    if let next { current = next } else { dismiss() }
                }
            }
        }
    }

    func step(_ delta: Int) {
        guard let current, let index = ids.firstIndex(of: current) else { return }
        let next = index + delta
        if ids.indices.contains(next) { withAnimation { self.current = ids[next] } }
    }

    func neighbour(of id: FileID) -> FileID? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return ids[safe: index + 1] ?? ids[safe: index - 1]
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
                    infoItem = item
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

/// One page: zoomable photo, Live Photo or video.
struct ViewerPage: View {
    let fileId: FileID
    let isCurrent: Bool
    @Environment(SessionModel.self) private var session
    @State private var item: MediaItem?

    var body: some View {
        Group {
            if let item {
                if item.kind == .video {
                    VideoPage(item: item, isCurrent: isCurrent)
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
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .disabled(true)
                    .onAppear { player.play() }
            } else {
                Color.clear
            }
        }
        .task {
            guard let peer = item.livePhotoPeer, let services = session.services,
                let url = try? await services.api.directDownloadURL(fileId: peer)
            else { return }
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}

/// Video playback through a temporary direct-download URL (SPEC §5.5.3).
struct VideoPage: View {
    let item: MediaItem
    let isCurrent: Bool
    @Environment(SessionModel.self) private var session
    @State private var player: AVPlayer?
    @State private var error: String?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
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
            guard player == nil, let services = session.services else { return }
            if MimeTypes.unplayableVideos.contains(item.mimeType) {
                guard session.features.has(.videoRenditions) else {
                    error = String(localized: "This video format can't be played on this device.", bundle: .module)
                    return
                }
                // The server converts on first request (404 while converting); retry for up to 2 minutes.
                for attempt in 0..<12 {
                    if let file = try? await services.api.videoRendition(fileId: item.fileId, etag: item.etag) {
                        player = AVPlayer(url: file)
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
                let url = try await services.api.directDownloadURL(fileId: item.fileId)
                player = AVPlayer(url: url)
                player?.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { player?.pause() }
    }
}
