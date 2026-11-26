// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaGridScreen {
    struct SelectionKey: Equatable {
        var ids: Set<FileID>
        var revision: Int
    }

    /// Selections up to this size are loaded as items (sharing, the screen's own actions); larger ones are only counted.
    static var eagerSelectionLimit: Int { 2000 }

    /// Loads what the toolbar and menus need for `ids`, off the main thread.
    func loadSelectionInfo(_ ids: Set<FileID>) async {
        guard !ids.isEmpty, let services = session.services else {
            selectionInfo = GridSelectionInfo()
            return
        }
        let list = Array(ids)
        if ids.count <= Self.eagerSelectionLimit {
            guard let map = try? await services.library.fetchItems(list), !Task.isCancelled else { return }
            let items = list.compactMap { map[$0] }
            selectionInfo = GridSelectionInfo(
                ids: ids, items: items, summary: SelectionSummary(items),
                shareItems: items.map { ShareableMedia(item: $0, services: services) })
        } else {
            guard let summary = try? await services.library.selectionSummary(list), !Task.isCancelled else { return }
            selectionInfo = GridSelectionInfo(ids: ids, items: nil, summary: summary)
        }
    }

    /// Runs `body` with the items of `ids`: at once when they are loaded already or few, else once they are read off the
    /// main thread (a selection of a whole library).
    func withItems(_ ids: [FileID], _ body: @escaping @MainActor ([MediaItem]) -> Void) {
        guard let library = session.services?.library, !ids.isEmpty else { return }
        if let items = selectionInfo.items, selectionInfo.ids.count == ids.count, selectionInfo.ids == Set(ids) {
            body(items)
        } else if ids.count <= 200, let map = try? library.items(ids) {
            body(ids.compactMap { map[$0] })
        } else {
            Task {
                guard let map = try? await library.fetchItems(ids) else { return }
                body(ids.compactMap { map[$0] })
            }
        }
    }

    /// Menu bar actions for this grid (SPEC §6.2, macOS menus).
    var gridActions: GridActions {
        let info = selectionInfo
        let summary = info.summary
        // Turned into a list only when an action runs: building it on every update costs as much as the selection is large.
        let selected = selection
        let single: MediaItem? = summary.count == 1 ? info.items?.first : nil
        let allFavorite = summary.allFavorite
        return GridActions(
            selectionCount: summary.count,
            allFavorite: allFavorite,
            toggleFavorite: { withItems(withStacks(Array(selected))) { setFavorite($0, !allFavorite) } },
            delete: { requestDelete(Array(selected)) },
            toggleInfo: {
                infoItem = info.items?.first
                showingInfo.toggle()
            },
            addToAlbum: { withItems(withStacks(Array(selected))) { albumPicker = PickedItems(items: $0) } },
            zoomIn: { zoomStep(zoomIn: true) },
            zoomOut: { zoomStep(zoomIn: false) },
            open: single.map { item in { openViewer(at: item.fileId) } },
            edit: single.flatMap { item in item.kind == .image ? { editedItem = item } : nil },
            editDateAndLocation: canEditMetadata(summary)
                ? { withItems(withStacks(Array(selected))) { metadataItems = PickedItems(items: $0.filter(\.permissions.canWrite)) } }
                : nil,
            export: summary.count == 0 ? nil : { withItems(Array(selected)) { export($0) } },
            shareItems: info.shareItems,
            shareTitle: single?.name ?? String(localized: "\(summary.count) items", bundle: .module),
            slideshow: feed.items.isEmpty ? nil : { playSlideshow(Array(selected)) },
            rotate: info.items.map(PhotoRotation.canRotate) == true ? { clockwise in rotate(Array(selected), clockwise: clockwise) } : nil,
            recentAlbums: summary.count == 0 ? [] : recentAlbums,
            addToRecentAlbum: { album in add(withStacks(Array(selected)), to: album) },
            addToNewAlbum: { withItems(withStacks(Array(selected))) { newAlbumItems = PickedItems(items: $0) } },
            useAsDesktopPicture: desktopPictureAction(single),
            cull: canCull && summary.count > 0 ? { (command: CullingCommand) in cull(command, Array(selected)) } : nil,
            compare: (2...CompareLayout.maxPhotos).contains(summary.count) ? { () -> Void in compare(Array(selected)) } : nil,
            loupe: feed.items.isEmpty ? nil : { () -> Void in openLoupe(selected) },
            deleteRejected: deleteRejected,
            editWith: editWithTarget(single)
        )
    }

    /// Image ▸ Use as Desktop Picture for one still photo (Mac, SPEC §15.4).
    func desktopPictureAction(_ item: MediaItem?) -> (() -> Void)? {
        #if os(macOS)
            guard let item, DesktopPictureAction.isOffered(item) else { return nil }
            return { DesktopPictureAction.use(item, session: session) }
        #else
            return nil
        #endif
    }

    /// Flag ▸, Rating ▸, Compare and Edit With ▸ of the context menu (SPEC §15.2).
    func cullingMenuActions(summary: SelectionSummary, single: MediaItem?) -> [GridMenuAction] {
        var actions: [GridMenuAction] = []
        // Flag, rate, Compare and Loupe are advanced features (SPEC §20.4); their keyboard shortcuts stay.
        if AdvancedFeatures.shows(.culling) {
            if canCull { actions.append(contentsOf: CullingMenu.actions { command, ids in cull(command, ids) }) }
            if (2...CompareLayout.maxPhotos).contains(summary.count) {
                actions.append(
                    GridMenuAction(id: "compare", title: CompareWording.menuTitle, systemImage: "rectangle.split.2x2") { ids in compare(ids)
                    })
            }
            actions.append(
                GridMenuAction(id: "loupe", title: LoupeWording.menuTitle, systemImage: "rectangle.and.text.magnifyingglass") { ids in
                    openLoupe(Set(ids))
                })
        }
        #if os(macOS)
            if let target = editWithTarget(single) {
                var apps: [GridMenuAction] = EditWithApps.apps(for: target.item).map { app in
                    GridMenuAction(id: "editwith.\(app.path)", title: EditWithApps.name(of: app), systemImage: "app") { _ in
                        target.open(app)
                    }
                }
                apps.append(
                    GridMenuAction(
                        id: "editwith.other", title: EditWithWording.otherTitle, systemImage: "ellipsis", startsGroup: !apps.isEmpty
                    ) {
                        _ in
                        if let app = EditWithApps.chooseApp() { target.open(app) }
                    })
                actions.append(
                    GridMenuAction(
                        id: "editwith", title: EditWithWording.menuTitle, systemImage: "square.and.pencil", handler: { _ in },
                        children: apps))
            }
        #endif
        return actions
    }

    /// Ratings and flags need system tags on the server (SPEC §15.2).
    var canCull: Bool { session.features.has(.systemtags) }

    /// The grid's rating keys; nil when the server has no tags.
    var cullCallback: (@MainActor (CullingCommand, [FileID]) -> Void)? {
        guard canCull else { return nil }
        return { (command: CullingCommand, ids: [FileID]) in cull(command, ids) }
    }

    /// Rates or flags the tiles `ids` and every copy stacked behind them; undoable.
    func cull(_ command: CullingCommand, _ ids: [FileID]) {
        let undoManager = undoManager
        withItems(withStacks(ids)) { items in culling.apply(command, to: items, session: session, undoManager: undoManager) }
    }

    /// The compare view with 2–4 photos, in the grid's order.
    func compare(_ ids: [FileID]) {
        let chosen = Set(ids)
        let ordered = feed.model.ids.filter { chosen.contains($0) }
        guard (2...CompareLayout.maxPhotos).contains(ordered.count) else { return }
        compareRequest = CompareRequest(ids: ordered)
    }

    /// The culling view (SPEC §16.5.2): several selected photos on their own, else the whole grid from the selected one.
    func openLoupe(_ selected: Set<FileID>) {
        loupeRequest = LoupeRequest.from(gridIds: feed.model.ids, selected: selected)
    }

    /// Image ▸ Edit With ▸ for one photo in the user's files (Mac).
    func editWithTarget(_ item: MediaItem?) -> EditWithTarget? {
        #if os(macOS)
            guard let item, item.kind == .image, !item.isCollectionChild else { return nil }
            return EditWithTarget(item: item) { app in ExternalEditCenter.shared.open(item, with: app, session: session) }
        #else
            return nil
        #endif
    }

    /// Out of the grid's densest step into the Library's days (SPEC §15.5); nil where there are no zoom levels.
    var zoomPastEnd: (@MainActor (FileID?, UnitPoint) -> Void)? {
        guard let libraryZoom else { return nil }
        let step: Int = columns
        return { (id: FileID?, point: UnitPoint) in libraryZoom.leaveGrid(from: id, at: point, currentStep: step) }
    }

    /// ⌘+ and ⌘−: the grid's next step, or the Library's zoom levels beyond its densest step.
    func zoomStep(zoomIn: Bool) {
        let next = GridColumns.step(columns, zoomIn: zoomIn)
        if let libraryZoom, libraryZoom.level != .all || (!zoomIn && next == columns) {
            libraryZoom.step(zoomIn: zoomIn, currentStep: columns)
        } else {
            columns = next
        }
    }

    /// The albums the "Add to Album" submenus list.
    var recentAlbums: [Album] { RecentAlbums.pick(albums, used: usedAlbums) }

    func observeAlbums() async {
        guard let services = session.services else { return }
        usedAlbums = RecentAlbumsStore.used(session.account.id)
        do {
            for try await value in services.collections.observeAlbums(.own) { albums = value }
        } catch {}
    }

    /// "Add to Album ▸ <album>": remembered as used, so it stays at the top of the submenu.
    func add(_ ids: [FileID], to album: Album) {
        RecentAlbumsStore.note(album, account: session.account.id)
        usedAlbums = RecentAlbums.noting(album.id, in: usedAlbums)
        let undoManager = undoManager
        withItems(ids) { items in Task { await session.addToAlbum(items, album: album, undoManager: undoManager) } }
    }

    /// Image ▸ Rotate Left/Right: a turn added to each photo's edit, undoable (SPEC §6.2, §16.3).
    func rotate(_ ids: [FileID], clockwise: Bool) {
        let undoManager = undoManager
        withItems(ids) { items in Task { await session.rotate(items, clockwise: clockwise, undoManager: undoManager) } }
    }

    /// Edit ▸ Copy: the originals on the pasteboard.
    func copy(_ items: [MediaItem]) {
        guard let services = session.services else { return }
        photoTasks.copy(items, services: services)
    }

    /// "Add to Album" as a submenu: the recent albums, "New Album…", and "All Albums…" for the full list.
    func albumMenuAction(title: String) -> GridMenuAction {
        var children: [GridMenuAction] = [
            GridMenuAction(
                id: "album.new",
                title: PlatformWording.title(
                    mac: LocalizedStringResource("New Album…", bundle: .module),
                    other: LocalizedStringResource("New album…", bundle: .module)),
                systemImage: "plus.rectangle.on.rectangle"
            ) { ids in
                withItems(withStacks(ids)) { newAlbumItems = PickedItems(items: $0) }
            }
        ]
        let recent: [Album] = recentAlbums
        for (index, album) in recent.enumerated() {
            children.append(
                GridMenuAction(id: "album.\(album.id)", title: album.title, systemImage: "rectangle.stack", startsGroup: index == 0) {
                    ids in
                    add(withStacks(ids), to: album)
                })
        }
        if albums.count > recent.count {
            children.append(
                GridMenuAction(
                    id: "album.all",
                    title: PlatformWording.title(
                        mac: LocalizedStringResource(
                            "All Albums…", bundle: .module, comment: "Add to Album submenu: choose from every album."),
                        other: LocalizedStringResource(
                            "All albums…", bundle: .module, comment: "Add to Album submenu: choose from every album.")),
                    systemImage: "rectangle.stack", startsGroup: true
                ) { ids in
                    withItems(ids) { albumPicker = PickedItems(items: $0) }
                })
        }
        return GridMenuAction(
            id: "album", title: title, systemImage: "rectangle.stack.badge.plus", startsGroup: true,
            handler: { ids in
                withItems(ids) { albumPicker = PickedItems(items: $0) }
            }, children: children)
    }

    /// Servers without metadata editing get the dates and places written into the files (SPEC §16.4).
    func canEditMetadata(_ summary: SelectionSummary) -> Bool {
        summary.writable > 0
    }

    func favoriteTitle(remove: Bool) -> String {
        remove
            ? PlatformWording.title(
                mac: LocalizedStringResource("Remove from Favorites", bundle: .module),
                other: LocalizedStringResource("Remove from favorites", bundle: .module))
            : PlatformWording.title(
                mac: LocalizedStringResource("Add to Favorites", bundle: .module),
                other: LocalizedStringResource("Add to favorites", bundle: .module))
    }

    /// Saves the originals: to a folder the user picks on the Mac, to the photo library on the other platforms.
    func export(_ items: [MediaItem]) {
        guard let services = session.services else { return }
        saver.save(items, services: services)
    }

    func endSelection() {
        // The action bar morphs back into the tab bar (SPEC §17.3).
        withAnimation(ChromeMotion.morph(reduceMotion: reduceMotion)) {
            isSelecting = false
            selection = []
        }
    }
}
