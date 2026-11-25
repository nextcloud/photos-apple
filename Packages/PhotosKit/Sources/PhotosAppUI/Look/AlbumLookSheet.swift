// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// "Customize Cover…": the cover photo and its effect for one album (SPEC §16.8.2). The choice is kept in the user's
/// Nextcloud (`.nextcloud-photos/album-covers.json`), so all the user's devices show it; an own album on a server that
/// can store a cover also gets the photo as its cover there, so the web shows it too.
struct AlbumLookSheet: View {
    let album: Album
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// nil: the album's own cover.
    @State private var cover: FileID?
    @State private var effect: AlbumCoverEffect = .automatic
    @State private var items: [GridMedia] = []
    @State private var placement: DepthCoverLayout.Placement?
    @State private var loaded = false

    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Customize Cover…", bundle: .module, comment: "Album menu item on the Mac: choose the cover photo and its effect."),
            other: LocalizedStringResource(
                "Customize cover…", bundle: .module, comment: "Album menu item: choose the cover photo and its effect."))
    }

    var shownCover: FileID? { cover ?? album.displayCoverFileId }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker(
                        String(localized: "Effect", bundle: .module, comment: "Customize Cover: how the cover is drawn."),
                        selection: $effect
                    ) {
                        ForEach(AlbumCoverEffect.allCases, id: \.self) { effect in
                            Text(Self.title(of: effect)).tag(effect)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(effectNote)
                }
                Section {
                    photoChoices
                } header: {
                    Text("Cover Photo", bundle: .module, comment: "Customize Cover: heading of the photos to choose from.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Cover", bundle: .module, comment: "Title of the Customize Cover sheet."))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) { save() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 600)
        #endif
        .task {
            guard let services = session.services, !loaded else { return }
            loaded = true
            let looks = AlbumLookStore.store(for: services)
            cover = looks.look(for: album)?.coverFileId
            effect = looks.effect(for: album)
            // The album's photos may not have been read from the server yet (an album not opened before).
            let album = album
            Task { try? await session.refreshAlbumContent(album) }
            do {
                for try await value in services.collections.observeAlbumGrid(albumId: album.id) {
                    items = value.filter { $0.kind == .image || $0.kind == .video }
                }
            } catch {}
        }
    }

    var preview: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            AlbumCoverArt(album: album, cover: shownCover, effect: effect, playKey: nil) { placement = $0 }
                // A new photo or effect starts again (a Live Photo plays again, a depth cover finds its subject).
                .id("\(shownCover ?? 0)-\(effect.rawValue)")
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 260)
        .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Cover preview", bundle: .module, comment: "Accessibility: the preview of an album cover."))
    }

    var effectNote: String {
        switch effect {
        case .automatic:
            String(
                localized: "A Live Photo cover plays once, without sound, when it appears.", bundle: .module,
                comment: "Customize Cover: what the Automatic effect does.")
        case .still:
            String(localized: "The cover never moves.", bundle: .module, comment: "Customize Cover: what the Still effect does.")
        case .depth:
            placement == .inFront
                ? String(
                    localized: "No subject was found that can stand in front of the title, so the title is shown on top.", bundle: .module,
                    comment: "Customize Cover: the depth effect could not find a subject in this photo.")
                : String(
                    localized: "The subject of the photo stands in front of the album’s title. It is found on this device.",
                    bundle: .module,
                    comment: "Customize Cover: what the Depth effect does.")
        }
    }

    static func title(of effect: AlbumCoverEffect) -> String {
        switch effect {
        case .automatic: String(localized: "Automatic", bundle: .module, comment: "Cover effect: Live Photos move once, others are still.")
        case .still: String(localized: "Still", bundle: .module, comment: "Cover effect: never moves.")
        case .depth: String(localized: "Depth", bundle: .module, comment: "Cover effect: the subject stands in front of the title.")
        }
    }

    @ViewBuilder var photoChoices: some View {
        Button {
            cover = nil
        } label: {
            HStack {
                Text("Album’s Own Cover", bundle: .module, comment: "Customize Cover: use the cover the album has anyway.")
                Spacer()
                if cover == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(cover == nil ? .isSelected : [])
        if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 4)], spacing: 4) {
                ForEach(items) { item in
                    Button {
                        cover = item.fileId
                    } label: {
                        PreviewImage(
                            fileId: item.fileId, etag: item.etag, bucket: 256, blurhash: item.blurhash, hasPreview: item.hasPreview,
                            mimeType: item.mimeType
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if cover == item.fileId {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(.tint, lineWidth: 3)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if item.isLivePhoto {
                                Image(systemName: "livephoto").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(3)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AccessibilityText.media(
                            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
                            place: nil, people: [], isFavorite: item.isFavorite, caption: nil)
                    )
                    .accessibilityAddTraits(cover == item.fileId ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    func save() {
        guard let services = session.services else { return dismiss() }
        let looks = AlbumLookStore.store(for: services)
        let album = album
        let cover = cover
        let effect = effect
        let previous = looks.look(for: album)?.coverFileId
        Task {
            await looks.set(cover: cover, effect: effect, for: album)
            // The web shows the same cover where the server can keep one.
            if let cover, cover != previous, album.kind == .own, session.features.has(.albumCover) {
                try? await session.updateAlbum(album, cover: cover)
            }
        }
        dismiss()
    }
}
