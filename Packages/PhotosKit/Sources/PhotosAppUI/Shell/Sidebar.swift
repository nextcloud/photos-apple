// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore

/// The rows of the sidebar and where the places without a row of their own open (SPEC §19.1).
///
/// The sidebar is slim: Photos and Videos are filters of the Library, the map is part of Places, smart albums are inside
/// Albums, "Shared with you" inside Shared, duplicates and free space inside Clean up. Every one of them stays a
/// destination — for the Go menu, links, widgets, Shortcuts and the command palette — and opens its row with the right
/// filter, mode or screen (`entry(for:visible:)`).
enum SidebarLayout {
    /// The first group by default. "On this day" is the first section of Memories and has no row of its own; it stays a
    /// destination for notifications, widgets and links.
    static let pinnedByDefault: [AppDestination] = [.library, .favorites, .memories, .people, .places]
    /// The albums group: Albums (on the Mac with the top albums under it) and Shared.
    static let albums: [AppDestination] = [.albums, .sharedAlbums]
    /// Collapsed by default.
    static let utilities: [AppDestination] = [.folders, .tags, .archive, .recentlyDeleted, .cleanUp, .insights, .stickers]
    /// Rows that can be pinned to the first group or moved to Utilities.
    static let movable: [AppDestination] = pinnedByDefault + utilities
    /// Every row of the sidebar.
    static let rows: [AppDestination] = pinnedByDefault + albums + utilities

    /// Where a destination opens: the row's destination, the screens pushed on it, and the Library's filter or the mode of
    /// Places it asks for.
    struct Entry: Equatable {
        var destination: AppDestination
        var routes: [AppRoute] = []
        /// The media kind the Library starts with (Photos, Videos); nil for every other destination.
        var libraryKind: MediaFilter? = nil
        /// Places opens on its map ("Map"); nil: the mode the user chose last.
        var placesMode: PlacesMode? = nil
        /// Clean up opens at the section of this destination (Duplicates, Free up server space; SPEC §19.3).
        var cleanUpSource: AppDestination? = nil
    }

    /// Where `destination` opens. `visible` says what this account's server offers.
    static func entry(for destination: AppDestination, visible: (AppDestination) -> Bool) -> Entry {
        switch destination {
        case .library: Entry(destination: .library, libraryKind: .all)
        case .photos: Entry(destination: .library, libraryKind: .photos)
        case .videos: Entry(destination: .library, libraryKind: .videos)
        case .map: Entry(destination: .places, placesMode: .map)
        case .smartAlbums:
            visible(.albums) ? Entry(destination: .albums, routes: [.destination(destination.rawValue)]) : Entry(destination: destination)
        case .sharedWithYou:
            // Without shared albums (servers without the Photos DAV API) the Shared row is "Shared with you" itself.
            visible(.sharedAlbums)
                ? Entry(destination: .sharedAlbums, routes: [.destination(destination.rawValue)]) : Entry(destination: destination)
        // On top of their row's screen, so Back leads to it and the row is highlighted on every platform.
        case .onThisDay: Entry(destination: .memories, routes: [.destination(destination.rawValue)])
        case .duplicates, .freeSpace: Entry(destination: .cleanUp, cleanUpSource: destination)
        default: Entry(destination: destination)
        }
    }

    /// The row that is highlighted while `destination` is shown; nil for screens without a row (search, settings…).
    static func row(for destination: AppDestination, visible: (AppDestination) -> Bool = { _ in true }) -> AppDestination? {
        switch destination {
        case .onThisDay: .memories
        case .photos, .videos: .library
        case .map: .places
        case .smartAlbums: visible(.albums) ? .albums : nil
        case .sharedWithYou: visible(.sharedAlbums) ? .sharedAlbums : .sharedWithYou
        case .duplicates, .freeSpace: .cleanUp
        case .search, .settings, .collections: nil
        #if os(macOS)
            // On the Mac, backup is a tab of the Settings window.
            case .backup: nil
        #endif
        default: destination
        }
    }

    /// The albums group's rows: Shared stands for "Shared with you" alone where the server has no shared albums.
    static func albumRows(visible: (AppDestination) -> Bool) -> [AppDestination] {
        var rows: [AppDestination] = []
        if visible(.albums) { rows.append(.albums) }
        if visible(.sharedAlbums) {
            rows.append(.sharedAlbums)
        } else if visible(.sharedWithYou) {
            rows.append(.sharedWithYou)
        }
        return rows
    }
}

extension AppDestination {
    /// The title of the destination's row: shorter than the destination's own title where the row stands for more than
    /// one place ("Shared" holds shared albums and "Shared with you").
    var rowTitle: LocalizedStringResource {
        switch self {
        case .sharedAlbums:
            LocalizedStringResource(
                "Shared", bundle: .module, comment: "Sidebar row and screen title: albums shared with the user and files shared with them.")
        default: title
        }
    }
}

/// How Places opens: the map of all geotagged photos, or the list of places the server knows.
enum PlacesMode: String, CaseIterable, Sendable {
    case map, list

    /// `@AppStorage` key of the mode chosen last.
    static let storageKey = "placesMode"
}

/// The user's sidebar on this device (Mac; the iPad uses `TabViewCustomization`): the rows of the first group in their
/// order, and the rows that are hidden (SPEC §19.1). Every other movable row is in Utilities. Library is always the
/// first group's and cannot be hidden.
struct SidebarCustomization: Equatable, Sendable {
    private(set) var pinned: [AppDestination]
    private(set) var hidden: Set<AppDestination>

    /// The slim sidebar the app starts with, and "Restore Defaults".
    static let standard = SidebarCustomization(pinned: SidebarLayout.pinnedByDefault, hidden: [])

    /// `@AppStorage` key.
    static let storageKey = "sidebarLayout"

    init(pinned: [AppDestination], hidden: Set<AppDestination>) {
        var rows: [AppDestination] = []
        for row in pinned where SidebarLayout.movable.contains(row) && !rows.contains(row) {
            rows.append(row)
        }
        if !rows.contains(.library) { rows.insert(.library, at: 0) }
        self.pinned = rows
        self.hidden = hidden.filter { SidebarLayout.rows.contains($0) && $0 != .library }
    }

    /// What `stored` wrote; the standard sidebar for nothing or something unreadable. Rows of another version that this
    /// one does not know are dropped.
    init(stored: String) {
        guard let data = stored.data(using: .utf8), let value = try? JSONDecoder().decode(Stored.self, from: data) else {
            self = .standard
            return
        }
        self.init(
            pinned: value.pinned.compactMap(AppDestination.init(rawValue:)),
            hidden: Set(value.hidden.compactMap(AppDestination.init(rawValue:))))
    }

    var stored: String {
        let value = Stored(pinned: pinned.map(\.rawValue), hidden: SidebarLayout.rows.filter(hidden.contains).map(\.rawValue))
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Stored: Codable {
        var pinned: [String]
        var hidden: [String]
    }

    var isStandard: Bool { self == .standard }

    /// Movable rows that are not pinned, in the order of `SidebarLayout.movable`.
    var utilities: [AppDestination] {
        SidebarLayout.movable.filter { !pinned.contains($0) }
    }

    func isPinned(_ row: AppDestination) -> Bool { pinned.contains(row) }
    func isHidden(_ row: AppDestination) -> Bool { hidden.contains(row) }
    func canPin(_ row: AppDestination) -> Bool { SidebarLayout.movable.contains(row) && !pinned.contains(row) }
    func canUnpin(_ row: AppDestination) -> Bool { pinned.contains(row) && row != .library }
    func canHide(_ row: AppDestination) -> Bool { SidebarLayout.rows.contains(row) && row != .library }

    /// Moves a row of Utilities to the end of the first group (and shows it).
    mutating func pin(_ row: AppDestination) {
        guard canPin(row) else { return }
        pinned.append(row)
        hidden.remove(row)
    }

    /// Moves a row of the first group back to Utilities.
    mutating func unpin(_ row: AppDestination) {
        guard canUnpin(row) else { return }
        pinned.removeAll { $0 == row }
    }

    mutating func setHidden(_ row: AppDestination, _ isHidden: Bool) {
        if isHidden {
            guard canHide(row) else { return }
            hidden.insert(row)
        } else {
            hidden.remove(row)
        }
    }

    /// Reorders the first group (drag in the sidebar or in Edit Sidebar).
    mutating func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
    }

    /// The first group's visible rows, `visible` saying what the server offers.
    func shownPinned(visible: (AppDestination) -> Bool) -> [AppDestination] {
        pinned.filter { !hidden.contains($0) && visible($0) }
    }

    func shownUtilities(visible: (AppDestination) -> Bool) -> [AppDestination] {
        utilities.filter { !hidden.contains($0) && visible($0) }
    }

    func shownAlbumRows(visible: (AppDestination) -> Bool) -> [AppDestination] {
        SidebarLayout.albumRows(visible: visible).filter { row in
            // "Shared with you" standing in for Shared is hidden with it.
            !hidden.contains(row == .sharedWithYou ? .sharedAlbums : row)
        }
    }
}

/// The albums listed under Albums in the Mac sidebar: the ones the user pinned there, then the ones used last in this app,
/// then the most recently changed — kept short, like Apple Photos' sidebar.
enum SidebarAlbums {
    static let limit = 8

    static func pick(_ albums: [Album], pinned: [String], used: [String], limit: Int = limit) -> [Album] {
        let byId = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let first: [Album] = pinned.compactMap { byId[$0] }
        let pinnedIds = Set(first.map(\.id))
        let rest = albums.filter { !pinnedIds.contains($0.id) }
        return first + RecentAlbums.pick(rest, used: used, limit: max(0, limit - first.count))
    }

    /// The pinned album ids after pinning or unpinning `albumId`.
    static func toggling(_ albumId: String, in pinned: [String]) -> [String] {
        pinned.contains(albumId) ? pinned.filter { $0 != albumId } : pinned + [albumId]
    }

    /// `@AppStorage` key of an account's pinned albums (per device).
    static func storageKey(account: String) -> String { "sidebarPinnedAlbums." + account }

    static func decode(_ stored: String) -> [String] {
        guard let data = stored.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the Library and Places were last asked to show by a destination without a row (Photos, Videos, Map). A new request
/// gives the screen a new identity, so it starts with the filter or mode asked for even when it is already shown.
struct DestinationRequest: Equatable, Sendable {
    var libraryKind: MediaFilter = .all
    var librarySerial = 0
    var placesMode: PlacesMode? = nil
    var placesSerial = 0
    /// Duplicates or Free up server space: the section Clean up opens at.
    var cleanUpSource: AppDestination? = nil
    var cleanUpSerial = 0

    mutating func apply(_ entry: SidebarLayout.Entry) {
        // The Library row itself only resets a filter that was asked for: a filter the user chose there stays.
        if let kind = entry.libraryKind, kind != .all || libraryKind != .all {
            libraryKind = kind
            librarySerial += 1
        }
        if entry.destination == .places {
            placesMode = entry.placesMode
            if entry.placesMode != nil { placesSerial += 1 }
        }
        if entry.destination == .cleanUp, entry.cleanUpSource != nil || cleanUpSource != nil {
            cleanUpSource = entry.cleanUpSource
            cleanUpSerial += 1
        }
    }
}
