// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// The main window's scene id: the menu bar extra opens it again when it was closed.
public enum MainWindow {
    public static let sceneId = "main"
}

/// The menu bar extra (Mac, SPEC §16.5.4): optional, on in Settings; it stays while the windows are closed.
public enum MenuBarExtraSettings {
    /// `UserDefaults` key of Settings › General › Show in Menu Bar (default off).
    public static let isShownKey = "menuBarExtra"
    /// Where dropped files go: "" for the upload folder, else an album id (`Album.id`).
    static let destinationKey = "menuBarExtra.destination"

    static var title: String {
        String(
            localized: "Show in Menu Bar", bundle: .module,
            comment: "Mac Settings: a menu bar item with a drop zone for uploads, backup status and today's memory.")
    }

    static var footnote: String {
        String(
            localized:
                "Drop photos on the menu bar item to upload them, see backup and uploads, and open today's memory, also while no window is open.",
            bundle: .module, comment: "Mac Settings: what the menu bar item offers.")
    }
}

#if os(macOS)
    import AppKit

    /// The menu bar extra's icon: the upload state at a glance.
    public struct PhotosMenuBarLabel: View {
        @Environment(AppModel.self) private var app

        public init() {}

        public var body: some View {
            let uploading = (app.session?.transfers.activeCount ?? 0) > 0 || MenuBarActions.isRunning(app.backup)
            Image(systemName: uploading ? "icloud.and.arrow.up" : "photo.on.rectangle")
                .accessibilityLabel(Text("Nextcloud Photos", bundle: .module, comment: "The app's name for the menu bar item."))
        }
    }

    /// The panel of the menu bar extra.
    public struct PhotosMenuBarPanel: View {
        @Environment(AppModel.self) private var app

        public init() {}

        public var body: some View {
            Group {
                if let session = app.session, !session.isSignedOut {
                    MenuBarSessionPanel().environment(session)
                } else {
                    VStack(spacing: 12) {
                        Text(
                            "Sign in to Nextcloud Photos to upload from here.", bundle: .module,
                            comment: "Menu bar panel without an account."
                        )
                        .multilineTextAlignment(.center)
                        MenuBarOpenButton(route: nil)
                    }
                    .padding()
                }
            }
            .frame(width: 320)
        }
    }

    /// Opens the main window (again, if it was closed), optionally at a place of the app.
    private struct MenuBarOpenButton: View {
        let route: String?
        var title: String? = nil
        var systemImage = "macwindow"
        @Environment(AppModel.self) private var app
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button {
                MenuBarActions.open(route: route, app: app, openWindow: openWindow)
            } label: {
                Label(title ?? MenuBarActions.openTitle, systemImage: systemImage)
            }
        }
    }

    @MainActor enum MenuBarActions {
        static var openTitle: String {
            String(localized: "Open Nextcloud Photos", bundle: .module, comment: "Menu bar panel: brings up the main window.")
        }

        /// The main window in front (a new one when all are closed), at `route` (`nextcloudphotos://<route>`).
        static func open(route: String?, app: AppModel, openWindow: OpenWindowAction) {
            if let route, let url = URL(string: "\(DeepLink.scheme)://\(route)") { app.open(url) }
            let hasMainWindow = NSApp.windows.contains { window in
                window.isVisible && window.identifier?.rawValue.hasPrefix(MainWindow.sceneId) == true
            }
            if !hasMainWindow { openWindow(id: MainWindow.sceneId) }
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.sceneId) == true }?.makeKeyAndOrderFront(nil)
        }
    }

    private struct MenuBarSessionPanel: View {
        @Environment(AppModel.self) private var app
        @Environment(SessionModel.self) private var session
        @Environment(\.openWindow) private var openWindow
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @AppStorage(MenuBarExtraSettings.destinationKey) private var destination = ""
        @State private var albums: [Album] = []
        @State private var memory: Memory?
        @State private var memoryCover: MediaItem?
        @State private var targeted = false
        @State private var dropped = 0

        var chosenAlbum: Album? { albums.first { $0.id == destination } }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let memory, let memoryCover { memoryCard(memory, cover: memoryCover) }
                dropZone
                status
                Divider()
                HStack {
                    MenuBarOpenButton(
                        route: "library", title: String(localized: "Library", bundle: .module), systemImage: "photo.on.rectangle")
                    MenuBarOpenButton(route: "albums", title: String(localized: "Albums", bundle: .module), systemImage: "rectangle.stack")
                    Spacer()
                    SettingsLink {
                        Label(String(localized: "Settings", bundle: .module), systemImage: "gearshape")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
            }
            .padding(14)
            .task(id: session.account.id) { await load() }
        }

        var header: some View {
            HStack(spacing: 8) {
                NextcloudLogo().frame(width: 30, height: 15)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.account.displayName).font(.headline)
                    Text(session.account.hostDisplayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                MenuBarOpenButton(route: nil)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(MenuBarActions.openTitle)
            }
        }

        func memoryCard(_ memory: Memory, cover: MediaItem) -> some View {
            Button {
                MenuBarActions.open(route: "onThisDay", app: app, openWindow: openWindow)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    PreviewImage(item: cover, bucket: 1024)
                        .frame(height: 150)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today's Memory", bundle: .module, comment: "Menu bar panel: the On this day memory.")
                            .font(.caption.weight(.semibold))
                        Text(memory.title).font(.headline)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Even behind the caption: 4.5:1 on any photo, as on the memory cards (SPEC §20.3).
                    .background { CaptionScrim(increased: contrast == .increased || reduceTransparency, fade: 30) }
                }
                .frame(height: 150)
                .clipShape(.rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                AccessibilityText.memory(title: memory.title, dateLine: nil, itemCount: memory.items.count))
        }

        var dropZone: some View {
            VStack(spacing: 8) {
                Image(systemName: targeted ? "arrow.down.circle.fill" : "icloud.and.arrow.up")
                    .font(.system(size: 26))
                    .foregroundStyle(targeted ? Design.accent : .secondary)
                Text("Drop photos and videos here", bundle: .module, comment: "Menu bar panel: the drop zone for uploads.")
                    .font(.callout.weight(.medium))
                Menu {
                    Picker(selection: $destination) {
                        Text(uploadFolderTitle).tag("")
                        if !albums.isEmpty {
                            Divider()
                            ForEach(albums) { album in
                                Text(verbatim: album.title).tag(album.id)
                            }
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(
                        "Upload to \(chosenAlbum?.title ?? uploadFolderTitle)", bundle: .module,
                        comment: "Menu bar panel: where dropped files go; the placeholder is an album or the upload folder.")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(targeted ? Design.accent : Color.secondary.opacity(0.5))
                    .background(targeted ? Design.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 12))
            }
            .dropDestination(for: URL.self) { urls, _ in
                upload(urls)
                return !urls.isEmpty
            } isTargeted: {
                targeted = $0
            }
            .accessibilityElement(children: .combine)
        }

        var uploadFolderTitle: String {
            let folder = session.features.userConfig.photosLocation
            let name = (folder as NSString).lastPathComponent
            return name.isEmpty ? folder : name
        }

        @ViewBuilder var status: some View {
            let transfers = session.transfers
            VStack(alignment: .leading, spacing: 6) {
                if transfers.activeCount > 0 {
                    ProgressView(value: transfers.overallProgress) {
                        Text("Uploading \(transfers.activeCount) items", bundle: .module).font(.caption)
                    }
                } else if !transfers.transfers.isEmpty {
                    let failed = transfers.transfers.filter { if case .failed = $0.state { true } else { false } }.count
                    Label(
                        failed > 0
                            ? String(localized: "Some uploads failed", bundle: .module)
                            : String(localized: "Uploads finished", bundle: .module),
                        systemImage: failed > 0 ? "exclamationmark.icloud" : "checkmark.icloud"
                    )
                    .font(.caption)
                }
                if app.backup.settings.isEnabled {
                    Label(MenuBarActions.backupLine(app.backup), systemImage: "arrow.triangle.2.circlepath.icloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }

        func upload(_ urls: [URL]) {
            let sources = UploadSources.copies(of: urls)
            guard !sources.isEmpty else { return }
            session.transfers.upload(sources, album: chosenAlbum)
        }

        func load() async {
            guard let services = session.services else { return }
            let own = (try? services.collections.albums(.own)) ?? []
            albums = own.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if let snapshot = try? await services.library.memories(onlyOnThisDay: true), let first = snapshot.onThisDay.first {
                memory = first
                memoryCover = try? await services.library.fetchItems([first.cover])[first.cover]
            } else {
                memory = nil
                memoryCover = nil
            }
        }
    }

    /// Settings › General: the menu bar extra on or off.
    struct MenuBarExtraSection: View {
        @AppStorage(MenuBarExtraSettings.isShownKey) private var isShown = false

        var body: some View {
            Section {
                Toggle(MenuBarExtraSettings.title, isOn: $isShown)
            } footer: {
                Text(MenuBarExtraSettings.footnote)
            }
        }
    }

    extension MenuBarActions {
        /// One line about the backup: running, or how the last pass ended.
        static func backupLine(_ backup: BackupModel) -> String {
            if isRunning(backup) {
                return String(localized: "Backing up…", bundle: .module, comment: "Menu bar panel: a backup pass is running.")
            }
            return BackupOutcome(status: backup.status).message
        }

        /// A backup pass is looking at the library or uploading.
        static func isRunning(_ backup: BackupModel) -> Bool {
            switch backup.status.phase {
            case .scanning, .reconciling, .uploading: true
            default: false
            }
        }
    }
#endif
