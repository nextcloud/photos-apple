// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Actions of the focused window, used by the menu bar (macOS) and keyboard shortcuts (iPadOS).
public struct MainActions {
    /// Destinations this account's server offers; the others are left out of the Go menu.
    var available: [AppDestination]
    var go: (AppDestination) -> Void
    var focusSearch: () -> Void
    var newAlbum: () -> Void
    var upload: () -> Void
    var openPublicLink: () -> Void
    var syncNow: () -> Void
    /// Import from Google Takeout (Mac only).
    var importTakeout: (() -> Void)? = nil
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
    /// Back to the whole photo (viewer only).
    var zoomToFit: (() -> Void)? = nil
    /// Opens the selected item in the viewer (grid only).
    var open: (() -> Void)? = nil
    /// Opens the photo editor for the selected photo.
    var edit: (() -> Void)? = nil
    var editDateAndLocation: (() -> Void)? = nil
    /// Saves the originals of the selection (to a folder on the Mac, to the photo library elsewhere).
    var export: (() -> Void)? = nil
    /// Originals of the selection for the system share sheet.
    var shareItems: [ShareableMedia] = []
    var shareTitle: String = ""
}

extension FocusedValues {
    @Entry public var mainActions: MainActions?
    @Entry public var gridActions: GridActions?
}

/// Wording that differs between the Mac (title case in menus, "Export…") and the other platforms.
enum PlatformWording {
    /// A menu or button title: title case on the Mac, sentence case elsewhere.
    static func title(mac: LocalizedStringResource, other: LocalizedStringResource) -> String {
        #if os(macOS)
            String(localized: mac)
        #else
            String(localized: other)
        #endif
    }
}

/// Menu bar commands (File, View, Image, Go) on the Mac; the same commands give iPadOS its keyboard shortcuts.
public struct PhotosCommands: Commands {
    @FocusedValue(\.mainActions) private var main
    @FocusedValue(\.gridActions) private var grid
    /// View ▸ Square Tiles: the same setting as Settings › On this device › Square tiles (`TileStyle`).
    @AppStorage(TileStyle.squareTilesKey) private var squareTiles = true

    public init() {}

    private var selectionCount: Int { grid?.selectionCount ?? 0 }

    public var body: some Commands {
        // After "New Window", which stays.
        CommandGroup(after: .newItem) {
            Button(String(localized: "New Album…", bundle: .module)) { main?.newAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(main == nil)
            Button(String(localized: "Open Public Album Link…", bundle: .module)) { main?.openPublicLink() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(main == nil)
        }

        CommandGroup(replacing: .importExport) {
            Button(String(localized: "Upload Photos…", bundle: .module)) { main?.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(main == nil)
            #if os(macOS)
                Button(String(localized: "Import from Google Takeout…", bundle: .module)) { main?.importTakeout?() }
                    .disabled(main?.importTakeout == nil)
            #endif
            Button(Self.exportTitle) { grid?.export?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(grid?.export == nil || selectionCount == 0)
            if let grid, !grid.shareItems.isEmpty {
                ShareLink(items: grid.shareItems) { _ in
                    SharePreview(grid.shareTitle)
                } label: {
                    Text("Share…", bundle: .module)
                }
            } else {
                Button(String(localized: "Share…", bundle: .module)) {}.disabled(true)
            }
        }

        CommandGroup(before: .sidebar) {
            Button(String(localized: "Zoom In", bundle: .module)) { grid?.zoomIn?() }
                .keyboardShortcut("+")
                .disabled(grid?.zoomIn == nil)
            Button(String(localized: "Zoom Out", bundle: .module)) { grid?.zoomOut?() }
                .keyboardShortcut("-")
                .disabled(grid?.zoomOut == nil)
            Button(String(localized: "Zoom to Fit", bundle: .module)) { grid?.zoomToFit?() }
                .keyboardShortcut("0")
                .disabled(grid?.zoomToFit == nil)
            Toggle(String(localized: "Square Tiles", bundle: .module), isOn: $squareTiles)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button(String(localized: "Sync Now", bundle: .module)) { main?.syncNow() }
                .keyboardShortcut("r")
                .disabled(main == nil)
            Divider()
        }

        CommandMenu(String(localized: "Image", bundle: .module)) {
            // No key equivalents for Open and Edit: Return and Space open the selection in the grid itself.
            Button(String(localized: "Open", bundle: .module)) { grid?.open?() }
                .disabled(grid?.open == nil || selectionCount != 1)
            Button(String(localized: "Get Info", bundle: .module)) { grid?.toggleInfo() }
                .keyboardShortcut("i")
                .disabled(grid == nil)
            Divider()
            Button(String(localized: "Edit…", bundle: .module)) { grid?.edit?() }
                .disabled(grid?.edit == nil)
            Button(String(localized: "Edit Date and Location…", bundle: .module)) { grid?.editDateAndLocation?() }
                .disabled(grid?.editDateAndLocation == nil)
            Divider()
            Button(
                grid?.allFavorite == true
                    ? String(localized: "Remove from Favorites", bundle: .module) : String(localized: "Add to Favorites", bundle: .module)
            ) { grid?.toggleFavorite() }
            .keyboardShortcut(".")
            .disabled(selectionCount == 0)
            Button(String(localized: "Add to Album…", bundle: .module)) { grid?.addToAlbum() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(selectionCount == 0)
            Divider()
            Button(String(localized: "Delete…", bundle: .module)) { grid?.delete() }
                .keyboardShortcut(.delete)
                .disabled(selectionCount == 0)
        }

        CommandMenu(String(localized: "Go", bundle: .module)) {
            let destinations: [AppDestination] = Self.goItems.filter { main?.available.contains($0) ?? true }
            ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                Button(String(localized: destination.title)) { main?.go(destination) }
                    .keyboardShortcut(index < 9 ? KeyEquivalent(Character(String(index + 1))) : nil)
                    .disabled(main == nil)
            }
            Divider()
            Button(String(localized: "Search", bundle: .module)) { main?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(main == nil)
        }
    }

    static var exportTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Export…", bundle: .module), other: LocalizedStringResource("Save to Photos", bundle: .module))
    }

    /// In the order of the sidebar; destinations the server does not offer are filtered out.
    static let goItems: [AppDestination] = SidebarLayout.primary + SidebarLayout.collections + SidebarLayout.utilities
}

extension View {
    /// `keyboardShortcut` that accepts nil.
    @ViewBuilder func keyboardShortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key) } else { self }
    }
}
