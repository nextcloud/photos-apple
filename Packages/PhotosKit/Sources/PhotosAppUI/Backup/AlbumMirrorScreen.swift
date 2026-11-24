// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import SwiftUI

#if os(iOS)
    /// Backup › Albums: the row that leads to the album mirror (SPEC §7.18.9).
    struct AlbumMirrorSection: View {
        @Environment(SessionModel.self) private var session

        var body: some View {
            Section {
                NavigationLink {
                    AlbumMirrorScreen()
                } label: {
                    LabeledContent(String(localized: "Albums", bundle: .module)) {
                        Text(summary)
                    }
                }
            } footer: {
                Text("Backed-up photos can also be added to albums of the same name on your Nextcloud.", bundle: .module)
            }
        }

        var summary: String {
            guard let settings = session.backup.albumMirrorSettings(), settings.isEnabled else {
                return String(localized: "Off", bundle: .module)
            }
            return String(localized: "\(settings.albumIdentifiers.count) albums", bundle: .module)
        }
    }

    /// Picks the device albums whose backed-up photos go into Nextcloud albums of the same name. Opt-in, only the picked
    /// albums, and only adding: nothing is removed from a Nextcloud album.
    struct AlbumMirrorScreen: View {
        @Environment(SessionModel.self) private var session
        @State private var settings = AlbumMirrorSettings()
        /// What is stored; only a change by the user is written back.
        @State private var stored: AlbumMirrorSettings?
        @State private var albums: [DeviceAlbum]?

        var body: some View {
            Form {
                Section {
                    Toggle(String(localized: "Add to albums on Nextcloud", bundle: .module), isOn: $settings.isEnabled)
                } footer: {
                    Text(
                        "When a photo of a chosen album is backed up, it is added to the album of the same name on your Nextcloud, which is created if needed. Photos are only added: taking one out of an album on this device does not change the album on Nextcloud.",
                        bundle: .module)
                }
                if settings.isEnabled {
                    Section(String(localized: "Albums on this device", bundle: .module)) {
                        if let albums {
                            if albums.isEmpty {
                                Text("There are no albums on this device.", bundle: .module).foregroundStyle(.secondary)
                            }
                            ForEach(albums) { album in
                                Toggle(isOn: binding(for: album)) {
                                    LabeledContent(album.title, value: album.count.formatted())
                                }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Albums", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let current = session.backup.albumMirrorSettings() ?? AlbumMirrorSettings()
                stored = current
                settings = current
                albums = await Task.detached(priority: .userInitiated) { PhotoKitAlbums().userAlbums() }.value
            }
            .onChange(of: settings) { _, value in
                guard let stored, value != stored else { return }
                self.stored = value
                session.backup.setAlbumMirror(value)
            }
        }

        func binding(for album: DeviceAlbum) -> Binding<Bool> {
            Binding(
                get: { settings.albumIdentifiers.contains(album.id) },
                set: { on in
                    settings.albumIdentifiers.removeAll { $0 == album.id }
                    if on { settings.albumIdentifiers.append(album.id) }
                })
        }
    }
#endif
