// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import SwiftUI

#if os(iOS)
    import MediaPlayer
#endif

/// Music for memory slideshows (SPEC ME-4), optional and off by default. The app ships no music (it would need licensed
/// tracks), so the user picks one: an audio file (copied into the app's own storage, so it keeps working after the
/// original moves), or on iPhone and iPad a song of the Music library, played by the app's own queue of the system
/// music player (that also plays Apple Music songs, which no file access could). One choice for every memory.
struct SlideshowMusic: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        /// A file in `SlideshowMusicStore.folder`, by name.
        case file(String)
        /// A song of the Music library (`MPMediaItem.persistentID`).
        case library(UInt64)
    }

    var source: Source
    /// What the menu shows: the file's or the song's name.
    var title: String

    /// The choice stored in the defaults (JSON), nil for none or for something unreadable.
    init?(stored: String) {
        guard !stored.isEmpty, let decoded = try? JSONDecoder().decode(Self.self, from: Data(stored.utf8)) else { return nil }
        self = decoded
    }

    init(source: Source, title: String) {
        self.source = source
        self.title = title
    }

    var stored: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Where the choice is kept: the app's defaults (not the account: it is how this device plays slideshows) and, for a
/// file, a copy in Application Support. Choosing something else deletes the copy.
@MainActor enum SlideshowMusicStore {
    static let key = "memorySlideshowMusic"

    static var folder: URL { URL.applicationSupportDirectory.appending(path: "SlideshowMusic", directoryHint: .isDirectory) }

    static func current(defaults: UserDefaults = .standard) -> SlideshowMusic? {
        SlideshowMusic(stored: defaults.string(forKey: key) ?? "")
    }

    /// Stores a choice (nil: no music) and removes copied files that are no longer chosen.
    static func save(_ music: SlideshowMusic?, defaults: UserDefaults = .standard, folder: URL = folder) {
        if let music { defaults.set(music.stored, forKey: key) } else { defaults.removeObject(forKey: key) }
        var keep: String?
        if case .file(let name) = music?.source { keep = name }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != keep { try? FileManager.default.removeItem(at: file) }
    }

    /// Copies a chosen audio file (from the file importer, possibly outside the sandbox) into the app's folder.
    static func importFile(_ url: URL, folder: URL = folder) throws -> SlideshowMusic {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
        return SlideshowMusic(source: .file(name), title: url.deletingPathExtension().lastPathComponent)
    }

    static func fileURL(_ name: String, folder: URL = folder) -> URL { folder.appending(path: name) }

    /// The music as a file the app may read (beat detection, video export): a chosen file, or a song of the Music
    /// library that is stored on the device and not protected. Nil for Apple Music songs: their DRM lets them play but
    /// not be read or put into a video.
    static func readableURL(for music: SlideshowMusic) -> URL? {
        switch music.source {
        case .file(let name):
            return fileURL(name)
        case .library(let id):
            #if os(iOS)
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(
                    MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
                guard let song = query.items?.first, !song.hasProtectedAsset else { return nil }
                return song.assetURL
            #else
                _ = id
                return nil
            #endif
        }
    }
}

/// Plays the chosen music while a memory film plays: fades in, follows the film's time when it is scrubbed, pauses with
/// it, loops, and stops when the film closes. On iPhone, iPad and Vision Pro a file plays in the `ambient` audio
/// category: it mixes with other audio and is silenced by the Ring/Silent switch, as in Photos.
@MainActor final class SlideshowMusicPlayer {
    private var audio: AVAudioPlayer?
    private var loaded: SlideshowMusic?
    #if os(iOS)
        private var usesLibrary = false
    #endif
    #if !os(macOS)
        private var previousCategory: AVAudioSession.Category?
    #endif

    /// Plays (fading in), from `position` seconds into the music when given (a film's music follows the film's time;
    /// past the music's end it starts over, as it loops).
    func play(_ music: SlideshowMusic, at position: Double? = nil) {
        if loaded != music {
            stop()
            load(music)
        }
        switch music.source {
        case .file:
            guard let audio else { return }
            if let position, audio.duration > 0 { audio.currentTime = position.truncatingRemainder(dividingBy: audio.duration) }
            if !audio.isPlaying {
                audio.volume = 0
                audio.play()
                audio.setVolume(1, fadeDuration: 1.5)
            }
        case .library:
            #if os(iOS)
                let player = MPMusicPlayerController.applicationQueuePlayer
                if let position {
                    let length = player.nowPlayingItem?.playbackDuration ?? 0
                    player.currentPlaybackTime = length > 0 ? position.truncatingRemainder(dividingBy: length) : position
                }
                player.play()
            #endif
        }
    }

    func pause() {
        audio?.pause()
        #if os(iOS)
            if usesLibrary { MPMusicPlayerController.applicationQueuePlayer.pause() }
        #endif
    }

    func stop() {
        audio?.stop()
        audio = nil
        #if os(iOS)
            if usesLibrary { MPMusicPlayerController.applicationQueuePlayer.stop() }
            usesLibrary = false
        #endif
        #if !os(macOS)
            if let previousCategory {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try? AVAudioSession.sharedInstance().setCategory(previousCategory)
                self.previousCategory = nil
            }
        #endif
        loaded = nil
    }

    private func load(_ music: SlideshowMusic) {
        loaded = music
        switch music.source {
        case .file(let name):
            #if !os(macOS)
                let session = AVAudioSession.sharedInstance()
                previousCategory = session.category
                try? session.setCategory(.ambient)
                try? session.setActive(true)
            #endif
            let player = try? AVAudioPlayer(contentsOf: SlideshowMusicStore.fileURL(name))
            player?.numberOfLoops = -1
            player?.prepareToPlay()
            audio = player
        case .library(let id):
            #if os(iOS)
                let query = MPMediaQuery.songs()
                query.addFilterPredicate(
                    MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
                let player = MPMusicPlayerController.applicationQueuePlayer
                player.setQueue(with: query)
                player.repeatMode = .one
                usesLibrary = true
            #else
                _ = id
            #endif
        }
    }
}

#if os(iOS)
    /// The Music library's song picker (iPhone, iPad). Only one song; the app keeps its persistent id, not the song.
    struct MusicLibraryPicker: UIViewControllerRepresentable {
        let onPick: (SlideshowMusic?) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

        func makeUIViewController(context: Context) -> MPMediaPickerController {
            let picker = MPMediaPickerController(mediaTypes: .music)
            picker.allowsPickingMultipleItems = false
            picker.prompt = String(
                localized: "Music for memory slideshows", bundle: .module, comment: "Prompt of the Music library picker.")
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

        final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
            let onPick: (SlideshowMusic?) -> Void

            init(onPick: @escaping (SlideshowMusic?) -> Void) {
                self.onPick = onPick
            }

            func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
                guard let song = collection.items.first else { return onPick(nil) }
                let title = song.title ?? String(localized: "Song", bundle: .module, comment: "A song without a title.")
                onPick(SlideshowMusic(source: .library(song.persistentID), title: title))
            }

            func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
                onPick(nil)
            }
        }
    }
#endif
