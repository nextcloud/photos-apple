// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaGridScreen {
    /// The context menu of the grid for `ids` (the selection, or the item that was clicked).
    func menuActions(for ids: [FileID]) -> [GridMenuAction] {
        // Device photos in the Library (SPEC §21.1) have actions of their own.
        if let device = DeviceGridActions.menu(
            for: ids, session: session, open: { openViewer(at: $0) }, serverActions: { menuActions(for: $0) })
        {
            return device
        }
        if selectionInfo.ids.count == ids.count, selectionInfo.ids == Set(ids) { return menuActions(selectionInfo) }
        guard let library = session.services?.library else { return [] }
        // Not loaded yet (the selection has just changed): read it now. A context menu is opened once, not on every update.
        if ids.count <= Self.eagerSelectionLimit {
            guard let map = try? library.items(ids) else { return [] }
            let items = ids.compactMap { map[$0] }
            return menuActions(GridSelectionInfo(ids: Set(ids), items: items, summary: SelectionSummary(items)))
        }
        let summary = (try? library.selectionSummaryNow(ids)) ?? SelectionSummary()
        return menuActions(GridSelectionInfo(ids: Set(ids), items: nil, summary: summary))
    }

    /// The actions for a selection; they read the selected items only when they run.
    func menuActions(_ info: GridSelectionInfo) -> [GridMenuAction] {
        let summary = info.summary
        guard summary.count > 0 else { return [] }
        let single: MediaItem? = summary.count == 1 ? info.items?.first : nil
        // Open, Get Info · Add to Album, Export · Favorite, Archive, Edit… · screen-specific actions · Delete.
        var actions: [GridMenuAction] = []
        if let item = single {
            actions.append(
                GridMenuAction(
                    id: "open", title: String(localized: "Open", bundle: .module), systemImage: "arrow.up.left.and.arrow.down.right"
                ) { _ in
                    openViewer(at: item.fileId)
                })
            let infoTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Get Info", bundle: .module), other: LocalizedStringResource("Info", bundle: .module))
            actions.append(
                GridMenuAction(id: "info", title: infoTitle, systemImage: "info.circle") { _ in
                    infoItem = item
                    showingInfo = true
                })
            if let showInFolder {
                actions.append(
                    GridMenuAction(id: "folder", title: ShowInFolderAction.title, systemImage: ShowInFolderAction.systemImage) { _ in
                        showInFolder(item)
                    })
            }
            if let showInTimeline, !isLibrary, ShowInTimelineAction.isOffered(for: item) {
                actions.append(
                    GridMenuAction(id: "timeline", title: ShowInTimelineAction.title, systemImage: ShowInTimelineAction.systemImage) { _ in
                        showInTimeline(item)
                    })
            }
            if SimilarPhotosAction.isOffered(for: item.kind) {
                actions.append(
                    GridMenuAction(id: "similar", title: SimilarPhotosAction.title, systemImage: SimilarPhotosAction.systemImage) { _ in
                        similarTo = item
                    })
            }
        }
        actions.append(
            GridMenuAction(id: "slideshow", title: SlideshowRequest.menuTitle, systemImage: SlideshowRequest.systemImage) { ids in
                playSlideshow(ids)
            })
        if summary.count <= CollageStyle.grid.maxPhotos, AdvancedFeatures.shows(.collages) {
            actions.append(
                GridMenuAction(id: "collage", title: CollageRequest.menuTitle, systemImage: "rectangle.3.group") { ids in
                    withItems(ids) { collage = CollageRequest.selection($0) }
                })
        }
        actions.append(albumMenuAction(title: addToAlbumTitle))
        if session.features.has(.systemtags) {
            actions.append(
                GridMenuAction(id: "tags", title: TagWording.menuTitle, systemImage: "tag") { ids in
                    withItems(withStacks(ids)) { tagEditor = PickedItems(items: $0) }
                })
        }
        actions.append(contentsOf: cullingMenuActions(summary: summary, single: single))
        let exportTitle: String = PlatformWording.title(
            mac: LocalizedStringResource("Export…", bundle: .module), other: LocalizedStringResource("Save to Photos", bundle: .module))
        actions.append(
            GridMenuAction(id: "save", title: exportTitle, systemImage: "square.and.arrow.down") { ids in withItems(ids) { export($0) } })
        // Edit ▸ Copy is only in the Mac's menu bar and on a hardware keyboard: here too, as in Photos.
        if let items = info.items, !items.isEmpty {
            actions.append(
                GridMenuAction(id: "copy", title: String(localized: "Copy", bundle: .module), systemImage: "doc.on.doc") { _ in
                    copy(items)
                })
        }
        // The system's Share menu with the originals (downloaded when a service asks for them); a loaded selection only.
        if let items = info.items, !items.isEmpty, let services = session.services {
            actions.append(
                GridMenuAction(
                    id: "share", title: String(localized: "Share…", bundle: .module), systemImage: "square.and.arrow.up",
                    handler: { _ in },
                    share: { MediaItemProviders.make(items, services: services) }))
        }
        if let item = single, item.permissions.canShare {
            actions.append(
                GridMenuAction(
                    id: "ncshare", title: String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus"
                ) { _ in
                    nextcloudShare = SharingTarget(item: item)
                })
        } else if single == nil, let items = info.items, items.contains(where: \.permissions.canShare) {
            // Several photos: one share per photo and recipient (`MultiFileSharingSheet`).
            actions.append(
                GridMenuAction(
                    id: "ncshare", title: String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus"
                ) { _ in
                    nextcloudShareMany = PickedItems(items: items.filter(\.permissions.canShare))
                })
        }
        let allFavorite = summary.allFavorite
        actions.append(
            GridMenuAction(
                id: "favorite", title: favoriteTitle(remove: allFavorite), systemImage: allFavorite ? "heart.slash" : "heart",
                startsGroup: true
            ) { ids in
                withItems(withStacks(ids)) { setFavorite($0, !allFavorite) }
            })
        if summary.archivable > 0 {
            actions.append(
                GridMenuAction(id: "archive", title: String(localized: "Archive", bundle: .module), systemImage: "archivebox") { ids in
                    let undoManager = undoManager
                    withItems(withStacks(ids)) { items in
                        motion.expectLeaving(items.map(\.fileId), style: .slide)
                        Task { await session.perform(.archive(items), undoManager: undoManager) }
                    }
                    endSelection()
                })
        }
        if summary.archived > 0 {
            actions.append(
                GridMenuAction(id: "unarchive", title: String(localized: "Unarchive", bundle: .module), systemImage: "tray.and.arrow.up") {
                    ids in
                    let undoManager = undoManager
                    withItems(withStacks(ids)) { items in
                        motion.expectLeaving(items.map(\.fileId), style: .slide)
                        Task { await session.perform(.unarchive(items), undoManager: undoManager) }
                    }
                    endSelection()
                })
        }
        if let item = single, item.kind == .image {
            actions.append(
                GridMenuAction(id: "edit", title: String(localized: "Edit…", bundle: .module), systemImage: "slider.horizontal.3") { _ in
                    editedItem = item
                })
        }
        #if os(macOS)
            if let use = desktopPictureAction(single) {
                actions.append(
                    GridMenuAction(id: "desktop", title: DesktopPictureAction.title, systemImage: DesktopPictureAction.systemImage) { _ in
                        use()
                    })
            }
        #endif
        // Image ▸ Rotate in the context menu as well (iPhone and iPad have no menu bar); only for photos that may be changed.
        if let items = info.items, PhotoRotation.canRotate(items) {
            actions.append(
                GridMenuAction(id: "rotate.left", title: String(localized: "Rotate Left", bundle: .module), systemImage: "rotate.left") {
                    ids in
                    rotate(ids, clockwise: false)
                })
            actions.append(
                GridMenuAction(id: "rotate.right", title: String(localized: "Rotate Right", bundle: .module), systemImage: "rotate.right") {
                    ids in
                    rotate(ids, clockwise: true)
                })
        }
        actions += editLookActions(info.items)
        if canEditMetadata(summary) {
            let metadataTitle: String = PlatformWording.title(
                mac: LocalizedStringResource("Adjust", bundle: .module, comment: "Submenu: adjust date, place, names of the selection."),
                other: LocalizedStringResource("Adjust", bundle: .module, comment: "Submenu: adjust date, place, names of the selection."))
            // Date and time, place, names, GPS track (SPEC §16.4).
            let children: [GridMenuAction] = BatchFixMode.allCases.map { mode in
                GridMenuAction(id: "metadata.\(mode.rawValue)", title: mode.menuTitle, systemImage: mode.systemImage) { ids in
                    withItems(withStacks(ids)) { batchFix = BatchFixRequest(items: $0.filter(\.permissions.canWrite), mode: mode) }
                }
            }
            actions.append(
                GridMenuAction(
                    id: "metadata", title: metadataTitle, systemImage: "calendar.badge.clock",
                    handler: { ids in
                        withItems(withStacks(ids)) { metadataItems = PickedItems(items: $0.filter(\.permissions.canWrite)) }
                    }, children: children))
        }
        // The screen's own actions (remove from album…) work on the items; a selection too large to load has none.
        var extras: [GridMenuAction] = (info.items.map(extraActions) ?? []).map(slidingAway)
        if !extras.isEmpty { extras[0].startsGroup = true }
        actions += extras
        if summary.deletable > 0 {
            actions.append(
                GridMenuAction(
                    id: "delete", title: String(localized: "Delete…", bundle: .module), systemImage: "trash", isDestructive: true,
                    startsGroup: true
                ) { ids in
                    requestDelete(ids)
                })
        }
        return actions
    }

    /// "Remove from Album" (the album's own action): its tiles slide away (SPEC §17.2).
    func slidingAway(_ action: GridMenuAction) -> GridMenuAction {
        guard action.id == "removeFromAlbum" else { return action }
        var sliding = action
        let motion = motion
        let handler = action.handler
        sliding.handler = { ids in
            motion.expectLeaving(withStacks(ids), style: .slide)
            handler(ids)
        }
        return sliding
    }
}
