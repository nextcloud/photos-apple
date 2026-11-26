// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// What a memory's "More" menu started and what it shows next (SPEC ME-4): the menu lives in the toolbar, the alerts,
/// sheets and pickers are attached to the screen (`memoryActions`).
@MainActor @Observable final class MemoryActionsModel {
    var working = false
    /// "Saved as the album …", or an error.
    var message: Message?
    var link: URL?
    var choosingFile = false
    var choosingSong = false
    /// The memory whose film is being exported as a video.
    var exporting: SlideshowStart?
    /// A card of the memory (SPEC §15.8.3).
    var collage: CollageRequest?

    struct Message: Identifiable {
        let id = UUID()
        var title: String
        var detail: String?
    }

    func saveAsAlbum(_ memory: Memory, session: SessionModel) async {
        working = true
        defer { working = false }
        do {
            let result = try await session.saveAsAlbum(memory)
            let skipped: String? =
                result.skipped == 0
                ? nil
                : String(
                    localized: "\(result.skipped) photos were left out: only your own photos can be added to an album.", bundle: .module,
                    comment: "After saving a memory as an album: some photos belong to shared folders. Plural variations in the catalog.")
            message = Message(
                title: String(
                    localized: "Saved as the album “\(result.album.title)”", bundle: .module,
                    comment: "After saving a memory as an album. The argument is the album's name."),
                detail: skipped)
        } catch {
            message = Message(
                title: String(localized: "The album could not be created", bundle: .module, comment: "Save a memory as an album failed."),
                detail: error.localizedDescription)
        }
    }

    func shareLink(_ memory: Memory, session: SessionModel) async {
        working = true
        defer { working = false }
        do {
            link = try await session.shareLink(for: memory)
        } catch {
            message = Message(
                title: String(
                    localized: "The link could not be created", bundle: .module, comment: "Sharing a memory as a public link failed."),
                detail: error.localizedDescription)
        }
    }

    func importMusic(_ result: Result<URL, any Error>) {
        do {
            SlideshowMusicStore.save(try SlideshowMusicStore.importFile(try result.get()))
        } catch {
            message = Message(
                title: String(
                    localized: "The music could not be used", bundle: .module,
                    comment: "Choosing a music file for memory slideshows failed."),
                detail: error.localizedDescription)
        }
    }
}

/// The "More" menu of a memory: save as album, share as link, music for its slideshow.
struct MemoryActionsMenu: View {
    let memory: Memory
    let model: MemoryActionsModel
    /// "Show to a Guest…" (SPEC §16.8.3).
    var showToGuest: (() -> Void)?
    @Environment(SessionModel.self) private var session
    @AppStorage(SlideshowMusicStore.key) private var storedMusic = ""

    var body: some View {
        Menu {
            Button {
                Task { await model.saveAsAlbum(memory, session: session) }
            } label: {
                Label(Self.saveTitle, systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                Task { await model.shareLink(memory, session: session) }
            } label: {
                Label(Self.linkTitle, systemImage: "link")
            }
            Button {
                model.exporting = SlideshowStart(memory: memory)
            } label: {
                Label(MemoryFilmExportSheet.menuTitle, systemImage: "film")
            }
            AdvancedFeatureGate(.collages) {
                Button {
                    Task { model.collage = await CollageRequest.memory(memory, session: session) }
                } label: {
                    Label(CollageRequest.cardTitle, systemImage: "rectangle.3.group")
                }
            }
            if let showToGuest {
                Button(action: showToGuest) {
                    Label(GuestWording.menuTitle, systemImage: GuestWording.systemImage)
                }
            }
            Divider()
            musicMenu
        } label: {
            if model.working {
                ProgressView().controlSize(.small)
            } else {
                Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
            }
        }
        .disabled(model.working)
        .help(String(localized: "More", bundle: .module))
    }

    var musicMenu: some View {
        let music = SlideshowMusic(stored: storedMusic)
        return Menu {
            Toggle(
                String(localized: "No Music", bundle: .module, comment: "Memory slideshow music: none (the default)."),
                isOn: Binding(get: { music == nil }, set: { if $0 { SlideshowMusicStore.save(nil) } }))
            if let music {
                Toggle(music.title, isOn: .constant(true))
            }
            Divider()
            #if os(iOS)
                Button(Self.songTitle) { model.choosingSong = true }
            #endif
            Button(Self.fileTitle) { model.choosingFile = true }
        } label: {
            Label(Self.musicTitle, systemImage: "music.note")
        }
    }

    static var saveTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Save as Album", bundle: .module,
                comment: "Memory menu: makes a Nextcloud album of the memory's photos."),
            other: LocalizedStringResource(
                "Save as album", bundle: .module,
                comment: "Memory menu: makes a Nextcloud album of the memory's photos."))
    }

    static var linkTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Share as Link…", bundle: .module,
                comment: "Memory menu: makes a public link (an album with a link) to the memory's photos."),
            other: LocalizedStringResource(
                "Share as link…", bundle: .module,
                comment: "Memory menu: makes a public link (an album with a link) to the memory's photos."))
    }

    static var musicTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Slideshow Music", bundle: .module,
                comment: "Memory menu: submenu to pick music for memory slideshows."),
            other: LocalizedStringResource(
                "Slideshow music", bundle: .module,
                comment: "Memory menu: submenu to pick music for memory slideshows."))
    }

    static var songTitle: String {
        String(
            localized: "Choose from Music Library…", bundle: .module,
            comment: "Memory slideshow music: pick a song from the Music app's library (iPhone and iPad).")
    }

    static var fileTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Choose Audio File…", bundle: .module,
                comment: "Memory slideshow music: pick an audio file."),
            other: LocalizedStringResource(
                "Choose audio file…", bundle: .module,
                comment: "Memory slideshow music: pick an audio file."))
    }
}

extension View {
    /// The alerts, the link sheet and the music pickers of a memory's menu.
    func memoryActions(_ model: MemoryActionsModel) -> some View {
        modifier(MemoryActionsPresenter(model: model))
    }
}

private struct MemoryActionsPresenter: ViewModifier {
    @Bindable var model: MemoryActionsModel

    func body(content: Content) -> some View {
        content
            .alert(
                model.message?.title ?? "",
                isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
                presenting: model.message
            ) { _ in
                // The system's OK.
            } message: { message in
                if let detail = message.detail { Text(detail) }
            }
            .sheet(item: Binding(get: { model.link.map(SharedURL.init) }, set: { model.link = $0?.url })) { shared in
                LinkShareSheet(url: shared.url)
            }
            .sheet(item: $model.exporting) { (start: SlideshowStart) in
                MemoryFilmExportSheet(start: start)
            }
            .collageEditor($model.collage)
            .fileImporter(isPresented: $model.choosingFile, allowedContentTypes: [.audio]) { result in
                model.importMusic(result)
            }
            #if os(iOS)
                .sheet(isPresented: $model.choosingSong) {
                    MusicLibraryPicker { song in
                        model.choosingSong = false
                        if let song { SlideshowMusicStore.save(song) }
                    }
                    .ignoresSafeArea()
                }
            #endif
    }

    struct SharedURL: Identifiable {
        var id: URL { url }
        var url: URL
    }
}
