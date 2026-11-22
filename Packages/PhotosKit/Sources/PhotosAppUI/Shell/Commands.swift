// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Actions of the focused window, used by the menu bar.
public struct MainActions {
    var go: (AppDestination) -> Void
    var newAlbum: () -> Void
    var upload: () -> Void
    var openPublicLink: () -> Void
    var syncNow: () -> Void
}

/// Actions of the focused photo grid or viewer, used by the menu bar.
public struct GridActions {
    var selectionCount: Int
    var allFavorite: Bool
    var toggleFavorite: () -> Void
    var delete: () -> Void
    var toggleInfo: () -> Void
    var addToAlbum: () -> Void
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
}

extension FocusedValues {
    @Entry public var mainActions: MainActions?
    @Entry public var gridActions: GridActions?
}

/// Menu bar commands (File, Image, View, Go), as Mac users expect from a photo app.
public struct PhotosCommands: Commands {
    @FocusedValue(\.mainActions) private var main
    @FocusedValue(\.gridActions) private var grid

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New Album", bundle: .module)) { main?.newAlbum() }
                .keyboardShortcut("n")
                .disabled(main == nil)
            Button(String(localized: "Upload Photos…", bundle: .module)) { main?.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(main == nil)
            Button(String(localized: "Open Public Album Link…", bundle: .module)) { main?.openPublicLink() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(main == nil)
        }

        CommandMenu(String(localized: "Image", bundle: .module)) {
            Button(
                grid?.allFavorite == true
                    ? String(localized: "Remove from Favorites", bundle: .module) : String(localized: "Add to Favorites", bundle: .module)
            ) { grid?.toggleFavorite() }
            .keyboardShortcut(".")
            .disabled((grid?.selectionCount ?? 0) == 0)
            Button(String(localized: "Add to Album…", bundle: .module)) { grid?.addToAlbum() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled((grid?.selectionCount ?? 0) == 0)
            Button(String(localized: "Show Info", bundle: .module)) { grid?.toggleInfo() }
                .keyboardShortcut("i")
                .disabled(grid == nil)
            Divider()
            Button(String(localized: "Delete…", bundle: .module)) { grid?.delete() }
                .keyboardShortcut(.delete)
                .disabled((grid?.selectionCount ?? 0) == 0)
        }

        CommandGroup(after: .toolbar) {
            Button(String(localized: "Zoom In", bundle: .module)) { grid?.zoomIn?() }
                .keyboardShortcut("+")
                .disabled(grid?.zoomIn == nil)
            Button(String(localized: "Zoom Out", bundle: .module)) { grid?.zoomOut?() }
                .keyboardShortcut("-")
                .disabled(grid?.zoomOut == nil)
            Divider()
            Button(String(localized: "Sync Now", bundle: .module)) { main?.syncNow() }
                .keyboardShortcut("r")
                .disabled(main == nil)
            Divider()
        }

        CommandMenu(String(localized: "Go", bundle: .module)) {
            ForEach(Array(Self.goItems.enumerated()), id: \.offset) { index, destination in
                Button(String(localized: destination.title)) { main?.go(destination) }
                    .keyboardShortcut(index < 9 ? KeyEquivalent(Character(String(index + 1))) : nil)
                    .disabled(main == nil)
            }
            Divider()
            Button(String(localized: "Search", bundle: .module)) { main?.go(.search) }
                .keyboardShortcut("f")
                .disabled(main == nil)
        }
    }

    static let goItems: [AppDestination] = [
        .library, .favorites, .memories, .map, .albums, .sharedAlbums, .people, .places, .onThisDay, .folders,
    ]
}

extension View {
    /// `keyboardShortcut` that accepts nil.
    @ViewBuilder func keyboardShortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key) } else { self }
    }
}
