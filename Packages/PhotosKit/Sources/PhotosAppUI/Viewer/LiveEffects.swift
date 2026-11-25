// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import AVKit
import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// Live Photo effects in the viewer and editor (SPEC §16.3.3): the motion part on the device, and the Loop and Bounce
/// videos made from it.
enum LiveEffectFiles {
    /// The motion part (MOV) of a Live Photo, downloaded into the originals cache.
    static func motion(of item: MediaItem, services: AccountServices) async throws -> URL {
        guard let peer = item.livePhotoPeer, let motion = try services.library.item(peer) else { throw CocoaError(.fileNoSuchFile) }
        return try await services.images.originals.original(
            fileId: peer, etag: motion.etag, url: services.originalURL(for: motion))
    }

    /// Where the played Loop and Bounce videos are kept: the system may clear them, they are made again.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "LiveEffects")
    }

    /// The video the viewer loops for `effect`: the motion itself for a Loop without edits, else a video made once (with
    /// the edit's look on every frame) and kept.
    static func playable(_ item: MediaItem, effect: LivePhotoEffect.Effect, recipe: EditRecipe?, services: AccountServices) async throws
        -> URL
    {
        let motion = try await motion(of: item, services: services)
        let looksEdited = recipe.map { !$0.edits.isIdentity || !($0.raw?.isIdentity ?? true) } ?? false
        if effect == .loop && !looksEdited { return motion }
        let digest = recipe?.renderingDigest ?? "plain"
        let target = directory.appending(path: "\(item.livePhotoPeer ?? item.fileId)-\(effect.rawValue)-\(digest).mp4")
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { return target }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: "\(UUID().uuidString).mp4")
        try await LivePhotoEffects.writeVideo(of: motion, effect: effect, edits: recipe, to: partial)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }
}

/// Plays a Live Photo's Loop or Bounce over and over, silently, as Photos does.
struct LiveEffectPlayer: View {
    let item: MediaItem
    let effect: LivePhotoEffect.Effect
    var recipe: EditRecipe?
    @Environment(SessionModel.self) private var session
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    struct Key: Hashable {
        var fileId: FileID
        var effect: LivePhotoEffect.Effect
        var digest: String
    }

    var body: some View {
        Group {
            if let player {
                PlayerSurface(player: player, showsControls: false)
                    .disabled(true)
            } else {
                Color.clear
            }
        }
        .task(id: Key(fileId: item.fileId, effect: effect, digest: recipe?.renderingDigest ?? "")) { await load() }
        .onDisappear { stop() }
    }

    func load() async {
        stop()
        guard let services = session.services,
            let file = try? await LiveEffectFiles.playable(item, effect: effect, recipe: recipe, services: services),
            !Task.isCancelled
        else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: file))
        player = queue
        queue.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
    }
}

/// The viewer's More menu items for an edited photo (SPEC §16.3): the original instead of the edit, Loop and Bounce as a
/// video or GIF, and Revert to Original.
struct EditedItemMenuItems: View {
    let item: MediaItem
    let saver: MediaSaveModel
    @Environment(SessionModel.self) private var session
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if item.kind == .image, let edit = session.edit(of: item.fileId), let services = session.services {
            let exportOriginal: String = PlatformWording.title(
                mac: LocalizedStringResource(
                    "Export Original…", bundle: .module, comment: "Viewer menu (Mac): exports the unedited file of an edited photo."),
                other: LocalizedStringResource(
                    "Save Original to Photos", bundle: .module, comment: "Viewer menu: saves the unedited file of an edited photo."))
            Button {
                saver.save([item], services: services, originals: true)
            } label: {
                Label(exportOriginal, systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(saver.isRunning)
            ShareLink(item: ShareableMedia(item: item, services: services, original: true), preview: SharePreview(item.name)) {
                Label(
                    String(
                        localized: "Share Original", bundle: .module, comment: "Viewer menu: shares the unedited file of an edited photo."),
                    systemImage: "square.and.arrow.up.on.square")
            }
            if let live = edit.live, live.playsByItself, item.isLivePhoto {
                let title: String = LiveEffectWording.title(live.effect)
                ShareLink(item: ShareableLiveEffect(item: item, gif: false, services: services), preview: SharePreview(title)) {
                    Label(
                        String(
                            localized: "Share \(title) as Video", bundle: .module,
                            comment: "Viewer menu: shares a Live Photo's Loop or Bounce as a video. %@ is the effect, e.g. Bounce."),
                        systemImage: "video")
                }
                ShareLink(item: ShareableLiveEffect(item: item, gif: true, services: services), preview: SharePreview(title)) {
                    Label(
                        String(
                            localized: "Share \(title) as GIF", bundle: .module,
                            comment: "Viewer menu: shares a Live Photo's Loop or Bounce as an animated GIF. %@ is the effect."),
                        systemImage: "photo.stack")
                }
            }
            Button(role: .destructive) {
                let undoManager = undoManager
                Task { await session.revertToOriginal([item], undoManager: undoManager) }
            } label: {
                Label(
                    PlatformWording.title(
                        mac: LocalizedStringResource("Revert to Original", bundle: .module),
                        other: LocalizedStringResource(
                            "Revert to original", bundle: .module, comment: "Viewer menu: removes the photo's edits (undoable).")),
                    systemImage: "arrow.uturn.backward.circle")
            }
        }
    }
}

/// "Loop", "Bounce", "Long Exposure": the effect's name, as in Photos.
enum LiveEffectWording {
    static func title(_ effect: LivePhotoEffect.Effect) -> String {
        switch effect {
        case .live: String(localized: "Live", bundle: .module, comment: "Live Photo effect: plays when pressed (the default).")
        case .loop: String(localized: "Loop", bundle: .module, comment: "Live Photo effect: plays over and over.")
        case .bounce: String(localized: "Bounce", bundle: .module, comment: "Live Photo effect: plays forward and backward.")
        case .longExposure:
            String(
                localized: "Long Exposure", bundle: .module,
                comment: "Live Photo effect: the frames blended into one picture, like a long shutter time.")
        }
    }

    static func symbol(_ effect: LivePhotoEffect.Effect) -> String {
        switch effect {
        case .live: "livephoto"
        case .loop: "infinity"
        case .bounce: "arrow.left.and.right"
        case .longExposure: "camera.aperture"
        }
    }
}
