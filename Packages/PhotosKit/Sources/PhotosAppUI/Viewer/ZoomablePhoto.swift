// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// A photo page: pinch, double-tap and keyboard zoom in a real scroll view (`ZoomSurface`), with progressive
/// resolution (SPEC §5.5.2) and Live Photo playback while pressed. An edited photo shows its edit (SPEC §16.3); a Loop
/// or Bounce plays by itself, and a RAW file can be developed at full quality on demand.
struct ZoomablePhoto: View {
    let item: MediaItem
    var isCurrent = true
    var command: ViewerZoomCommand?
    var events = ZoomSurfaceEvents()
    @State private var image: CGImage?
    /// Set once the photo was zoomed far enough to need the large preview; it is kept afterwards.
    @State private var needsDetail = false
    @State private var playingLive = false
    /// The RAW developed by Core Image (with its edit), shown instead of the preview (SPEC §16.3.2).
    @State private var developed: CGImage?
    @State private var developing = false
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock.shared
    /// No Live Text in Guest Mode: its menu copies, shares and looks things up (SPEC §16.8.3).
    @Environment(\.isGuestPresentation) private var isGuestPresentation

    var bucket: Int { needsDetail ? 4096 : 1024 }

    /// The photo's edit; read through the session so the page follows changes.
    var edit: EditRecipe? { session.edit(of: item.fileId) }

    var shown: CGImage? { developed ?? image }

    /// The photo's shape: of the image shown, else what the server says, else unknown (the page is filled).
    var contentSize: CGSize {
        if let shown { return CGSize(width: shown.width, height: shown.height) }
        if let width = item.width, let height = item.height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        return .zero
    }

    /// Live Text and Visual Look Up (SPEC VW-4) for the photo shown, once its preview is there.
    var analysesLiveText: Bool {
        LiveTextPolicy.analyzes(
            isCurrent: isCurrent, hasImage: image != nil, sceneIsActive: scenePhase == .active, requiresUnlock: lock.requiresUnlock)
            && !isGuestPresentation
    }

    /// Loop and Bounce play by themselves (not with Reduce Motion: then they play while pressed, like a Live Photo).
    var playsEffect: Bool {
        guard let live = edit?.live, live.playsByItself, item.isLivePhoto else { return false }
        return isCurrent && !reduceMotion
    }

    var surfaceEvents: ZoomSurfaceEvents {
        var surface: ZoomSurfaceEvents = events
        let scaleChanged: (CGFloat) -> Void = events.scaleChanged
        surface.scaleChanged = { scale in
            if scale >= ViewerZoom.highResolutionScale { needsDetail = true }
            scaleChanged(scale)
        }
        surface.pressing = { pressing in
            guard item.isLivePhoto else { return }
            withAnimation { playingLive = pressing }
        }
        return surface
    }

    struct LoadKey: Hashable {
        var fileId: FileID
        var etag: String
        var bucket: Int
        var edit: String
    }

    var body: some View {
        ZStack {
            ZoomSurface(
                image: shown ?? BlurHashCache.image(item.blurhash), contentSize: contentSize, command: command, isCurrent: isCurrent,
                animates: !reduceMotion, pressEnabled: item.isLivePhoto, liveText: analysesLiveText, events: surfaceEvents)
            motion
        }
        .overlay(alignment: .topLeading) {
            if item.isLivePhoto {
                let effect: LivePhotoEffect.Effect = edit?.live?.effect ?? .live
                Label(LiveEffectWording.title(effect), systemImage: LiveEffectWording.symbol(effect))
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 60)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if EditRendering.isRAW(name: item.name) && isCurrent { rawButton }
        }
        .task(id: LoadKey(fileId: item.fileId, etag: item.etag, bucket: bucket, edit: edit?.renderingDigest ?? "")) { await load() }
        .onChange(of: edit) { _, _ in developed = nil }
    }

    /// The Live Photo's motion: its Loop or Bounce playing by itself, or the motion while pressed.
    @ViewBuilder var motion: some View {
        let live: LivePhotoEffect? = edit?.live
        if playsEffect, let live {
            LiveEffectPlayer(item: item, effect: live.effect, recipe: edit)
                .allowsHitTesting(false)
        } else if playingLive, item.livePhotoPeer != nil {
            if let live, live.playsByItself {
                LiveEffectPlayer(item: item, effect: live.effect, recipe: edit)
                    .background(.black)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            } else {
                LivePhotoMotion(item: item)
                    .background(.black)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    /// "RAW": the full-quality development of the RAW file, on demand (it downloads the whole file).
    var rawButton: some View {
        let title: String = String(
            localized: "Show the RAW file at full quality", bundle: .module, comment: "Viewer: help of the RAW button.")
        return Button {
            if developed != nil {
                developed = nil
            } else {
                Task { await develop() }
            }
        } label: {
            HStack(spacing: 4) {
                if developing { ProgressView().controlSize(.mini) }
                Text("RAW", bundle: .module, comment: "Viewer: button that develops the RAW file at full quality.")
                if developed != nil { Image(systemName: "checkmark") }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(developing)
        .padding(.top, 60)
        .padding(.trailing, 12)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(developed != nil ? .isSelected : [])
    }

    /// As `PreviewImage`: what is in memory at once, then the preview of the wanted size (edited, if it has an edit).
    func load() async {
        guard let services = session.services else { return }
        let etag: String = services.images.displayedEtag(fileId: item.fileId, etag: item.etag)
        if let cached = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: etag, upTo: bucket) { image = cached }
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
        if let loaded = await services.images.preview(request) { image = loaded }
    }

    /// Develops the RAW original with Core Image at up to 4096 px, with the photo's edit.
    func develop() async {
        guard let services = session.services else { return }
        developing = true
        defer { developing = false }
        let item = item
        let recipe = edit
        guard
            let file = try? await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        else { return }
        developed = await Self.developed(file, name: item.name, recipe: recipe)
    }

    nonisolated static func developed(_ file: URL, name: String, recipe: EditRecipe?) async -> CGImage? {
        guard let loaded = EditRendering.loadOriginal(file, name: name, raw: recipe?.raw, maxPixelSize: 4096) else { return nil }
        let output: CIImage = recipe.map { EditRendering.apply($0, to: loaded.image, developed: loaded.developed) } ?? loaded.image
        return PhotoEditor.context.createCGImage(output, from: output.extent.integral)
    }
}
