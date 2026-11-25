// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

enum LockScreenWording {
    static var title: String {
        String(
            localized: "Lock Screen Album", bundle: .module,
            comment: "Settings: the Nextcloud album copied to the device for the Lock Screen's Photo Shuffle.")
    }

    static func copies(_ count: Int) -> String {
        String(
            localized: "\(count) photos on this device", bundle: .module,
            comment: "Lock Screen album: how many copies are on the device. Plural variations in the catalog.")
    }

    static func waiting(_ count: Int) -> String {
        String(
            localized: "\(count) removed photos are still on this device", bundle: .module,
            comment: "Lock Screen album: copies whose deletion was not confirmed yet. Plural variations in the catalog.")
    }
}

/// Settings › Lock Screen Album (iPhone and iPad): copy one Nextcloud album into the device's Photos library, so the Lock
/// Screen's Photo Shuffle can use it.
struct LockScreenAlbumSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @State private var picking = false
    @State private var confirmOff = false

    var body: some View {
        if LockScreenAlbumModel.isSupported, let model = session.lockScreenAlbum {
            Section {
                Button {
                    picking = true
                } label: {
                    LabeledContent {
                        Text(model.settings.isOn ? model.settings.albumTitle : String(localized: "Off", bundle: .module))
                    } label: {
                        Label(LockScreenWording.title, systemImage: "lock.rectangle.on.rectangle")
                    }
                }
                .foregroundStyle(.primary)
                // On the row, not the section: a section hands its modifiers to each of its rows.
                .sheet(isPresented: $picking) { LockScreenAlbumPicker() }
                .confirmationDialog(
                    String(
                        localized: "Remove the copies from this device?", bundle: .module,
                        comment: "Lock Screen album: confirmation of turning it off."),
                    isPresented: $confirmOff, titleVisibility: .visible
                ) {
                    Button(String(localized: "Turn Off", bundle: .module, comment: "Confirms turning a feature off."), role: .destructive) {
                        Task { await model.turnOff() }
                    }
                } message: {
                    Text(
                        "The photos stay in Nextcloud.", bundle: .module,
                        comment: "Lock Screen album: turning it off keeps the Nextcloud album.")
                }
                .task { await model.sync() }
                if model.settings.isOn {
                    LabeledContent(LockScreenWording.copies(model.status.copies)) {
                        if model.status.running { ProgressView() }
                    }
                    .font(.callout)
                }
                if !model.settings.pendingDeletion.isEmpty {
                    Button(LockScreenWording.waiting(model.settings.pendingDeletion.count)) { Task { await model.deletePending() } }
                }
                if model.settings.isOn {
                    Button(
                        String(
                            localized: "Turn Off and Remove Copies", bundle: .module,
                            comment: "Stops the Lock Screen album and deletes its copies from the device."), role: .destructive
                    ) {
                        confirmOff = true
                    }
                }
                if model.status.accessDenied {
                    Text(
                        "Nextcloud Photos may not use the photo library. Allow it in Settings › Privacy & Security › Photos.",
                        bundle: .module,
                        comment: "Lock Screen album: photo library access was denied."
                    )
                    .font(.footnote).foregroundStyle(.red)
                }
                if let error = model.status.error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text(
                    "Copies of the album's photos are stored in an album \"Nextcloud: …\" in your iPhone's Photos library, so the Lock Screen's Photo Shuffle can use them. They follow the album in Nextcloud; videos, archived photos and photos of people you hid are left out. Turning it off deletes the copies.",
                    bundle: .module, comment: "Settings: footer of the Lock Screen album.")
            }
        }
    }
}

/// Picks the album to show on the Lock Screen.
struct LockScreenAlbumPicker: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(albums) { (album: Album) in
                        Button {
                            dismiss()
                            Task { await session.lockScreenAlbum?.choose(album) }
                        } label: {
                            HStack {
                                Group {
                                    if let cover = album.displayCoverFileId {
                                        PreviewImage(fileId: cover, etag: "", bucket: 64)
                                    } else {
                                        Color.secondary.opacity(0.15)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(album.title.isEmpty ? album.name : album.title)
                                    Text(AccessibilityText.items(album.itemCount)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.lockScreenAlbum?.settings.albumId == album.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(
                        "Up to \(DeviceMirror.maximumPhotos) photos are copied, sized for the screen.", bundle: .module,
                        comment: "Lock Screen album picker: footer; the argument is the maximum number of photos.")
                }
            }
            .navigationTitle(LockScreenWording.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
            }
            .task {
                try? await session.refreshAlbums()
                let own = (try? session.services?.collections.albums(.own)) ?? []
                let shared = (try? session.services?.collections.albums(.shared)) ?? []
                albums = (own + shared).sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
            }
        }
    }
}
