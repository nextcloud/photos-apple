// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosCore
    import PhotosModel
    import SwiftUI

    // The Mac's desktop pictures (SPEC §15.4): "Use as Desktop Picture" for one photo, and a rotation through an album, the
    // favourites, the memories or the library — in Settings › Desktop and from an album's menu.

    /// "Use as Desktop Picture" in the grid's context menu, the viewer's More menu and Image in the menu bar.
    enum DesktopPictureAction {
        static var title: String {
            String(localized: "Use as Desktop Picture", bundle: .module, comment: "Mac menu item: the photo becomes the desktop picture.")
        }

        static let systemImage = "menubar.dock.rectangle"

        /// Still photos only: a video or the motion of a Live Photo cannot be a desktop picture.
        static func isOffered(_ item: MediaItem) -> Bool {
            item.kind == .image && !item.isLivePhotoVideo
        }

        @MainActor static func use(_ item: MediaItem, session: SessionModel) {
            guard let services = session.services else { return }
            Task {
                do {
                    try await DesktopPictures.shared.use(item, services: services)
                } catch {
                    NSApplication.shared.presentError(error)
                }
            }
        }

        /// The album menu's item that opens the rotation settings for the album.
        static var rotateTitle: String {
            String(
                localized: "Use as Desktop Pictures…", bundle: .module,
                comment: "Album menu (Mac): opens the settings to rotate the album's photos as desktop pictures.")
        }
    }

    struct DesktopPictureSheet: View {
        let source: AmbientSource
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            DesktopPictureForm(initialSource: source, onStart: { dismiss() })
                .frame(width: 480, height: 330)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                    }
                }
        }
    }

    /// Settings › Desktop.
    struct DesktopPictureSettingsPane: View {
        @State private var pictures = DesktopPictures.shared

        var body: some View {
            // As tall as its content: the Settings window takes the height of the tab shown.
            DesktopPictureForm(initialSource: nil, onStart: nil)
                .frame(width: MacSettingsLayout.width, height: pictures.settings == nil ? 340 : 450)
        }
    }

    /// What a rotation shows, how often it changes and where; the current rotation with Next Picture and Stop.
    struct DesktopPictureForm: View {
        let initialSource: AmbientSource?
        let onStart: (() -> Void)?
        @Environment(SessionModel.self) private var session
        @State private var pictures = DesktopPictures.shared
        @State private var source: AmbientSource = .favorites
        @State private var interval: DesktopPictureSettings.Interval = .hour
        @State private var displays: DesktopPictureSettings.Displays = .all
        @State private var shuffle = true
        @State private var albums: [Album] = []
        @State private var screens: [DesktopScreen] = []

        var body: some View {
            Form {
                if let running = pictures.settings {
                    Section {
                        LabeledContent {
                            HStack {
                                Button(String(localized: "Next Picture", bundle: .module)) { Task { await pictures.next() } }
                                    .disabled(pictures.isWorking)
                                Button(String(localized: "Stop", bundle: .module)) { pictures.stop() }
                            }
                        } label: {
                            Text(summary(running))
                            if let problem = pictures.problem {
                                Text(problem).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Now", bundle: .module, comment: "Settings › Desktop: the rotation that runs.")
                    }
                }
                Section {
                    Picker(String(localized: "Photos", bundle: .module), selection: $source) {
                        Text(sourceName(.favorites)).tag(AmbientSource.favorites)
                        Text(sourceName(.memories)).tag(AmbientSource.memories)
                        Text(sourceName(.library)).tag(AmbientSource.library)
                        if !albums.isEmpty {
                            Divider()
                            ForEach(albums) { album in
                                Text(album.title).tag(AmbientSource.album(id: album.id, title: album.title))
                            }
                        }
                        if case .album(let id, let title) = source, !albums.contains(where: { $0.id == id }) {
                            Text(title).tag(source)
                        }
                    }
                    Picker(String(localized: "Change picture", bundle: .module), selection: $interval) {
                        ForEach(DesktopPictureSettings.Interval.allCases, id: \.self) { interval in
                            Text(Self.name(interval)).tag(interval)
                        }
                    }
                    Picker(
                        String(localized: "Show on", bundle: .module, comment: "Settings › Desktop: on which displays."),
                        selection: $displays
                    ) {
                        Text("All Displays", bundle: .module).tag(DesktopPictureSettings.Displays.all)
                        ForEach(screens) { screen in
                            Text(screen.name).tag(DesktopPictureSettings.Displays.display(id: screen.id, name: screen.name))
                        }
                    }
                    Toggle(String(localized: "Shuffle", bundle: .module), isOn: $shuffle)
                } header: {
                    Text("Rotate Desktop Pictures", bundle: .module)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Each display gets a photo of its own that suits its shape. The pictures change while Nextcloud Photos is open, also without a window; the current Space of each display changes.",
                            bundle: .module)
                        // In the album's sheet the button sits next to Cancel.
                        if onStart == nil {
                            HStack {
                                Spacer()
                                startButton
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .toolbar {
                if onStart != nil {
                    ToolbarItem(placement: .confirmationAction) { startButton }
                }
            }
            .task { load() }
        }

        var startButton: some View {
            Button(pictures.settings == nil ? Self.startTitle : Self.applyTitle) { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(pictures.isWorking)
        }

        static var startTitle: String {
            String(localized: "Start", bundle: .module, comment: "Settings › Desktop: starts rotating desktop pictures.")
        }

        static var applyTitle: String {
            String(localized: "Apply", bundle: .module, comment: "Settings › Desktop: changes the running rotation.")
        }

        func load() {
            screens = DesktopPictures.systemScreens()
            if let services = session.services {
                let own = (try? services.collections.albums(.own)) ?? []
                let shared = (try? services.collections.albums(.shared)) ?? []
                albums = (own + shared).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            if let running = pictures.settings, running.accountId == session.account.id,
                initialSource == nil || initialSource == running.source
            {
                source = running.source
                interval = running.interval
                displays = running.displays
                shuffle = running.shuffle
            }
            if let initialSource { source = initialSource }
        }

        func start() {
            let settings = DesktopPictureSettings(
                accountId: session.account.id, source: source, interval: interval, displays: displays, shuffle: shuffle)
            pictures.start(settings)
            onStart?()
        }

        /// "Holidays · All Displays · Every hour".
        func summary(_ settings: DesktopPictureSettings) -> String {
            let displays: String
            switch settings.displays {
            case .all: displays = String(localized: "All Displays", bundle: .module)
            case .display(_, let name): displays = name
            }
            return [sourceName(settings.source), displays, Self.name(settings.interval)].joined(separator: " · ")
        }

        func sourceName(_ source: AmbientSource) -> String {
            switch source {
            case .favorites: String(localized: "Favorites", bundle: .module)
            case .memories: String(localized: "Memories", bundle: .module)
            case .library: String(localized: "Library", bundle: .module)
            case .album(_, let title): title
            }
        }

        static func name(_ interval: DesktopPictureSettings.Interval) -> String {
            switch interval {
            case .fiveMinutes: String(localized: "Every 5 minutes", bundle: .module)
            case .fifteenMinutes: String(localized: "Every 15 minutes", bundle: .module)
            case .thirtyMinutes: String(localized: "Every 30 minutes", bundle: .module)
            case .hour: String(localized: "Every hour", bundle: .module)
            case .day: String(localized: "Every day", bundle: .module)
            }
        }
    }
#endif
