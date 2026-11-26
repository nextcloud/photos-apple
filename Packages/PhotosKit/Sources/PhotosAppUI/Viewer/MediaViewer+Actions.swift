// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaViewer {
    /// Menu bar actions for the photo shown.
    var viewerActions: GridActions {
        let item: MediaItem? = currentItem
        let isImage: Bool = item?.kind == .image
        let zoomed: Bool = ViewerZoom.isZoomed(zoomScale)
        var actions = GridActions(
            selectionCount: item == nil ? 0 : 1,
            allFavorite: item?.isFavorite ?? false,
            toggleFavorite: { if let item { toggleFavorite(item) } },
            delete: { if item?.permissions.canDelete == true { confirmDelete = true } },
            toggleInfo: { toggleInfo() },
            addToAlbum: { addingToAlbum = item },
            zoomIn: isImage && zoomScale < ViewerZoom.maximumScale - ViewerZoom.epsilon ? { zoom(.zoomIn) } : nil,
            zoomOut: isImage && zoomed ? { zoom(.zoomOut) } : nil
        )
        actions.zoomToFit = isImage && zoomed ? { zoom(.fit) } : nil
        guard let item else { return actions }
        if isImage {
            actions.edit = { editing = item }
            // Image ▸ Rotate: an edit of the photo shown (SPEC §16.3), undoable.
            actions.rotate = { clockwise in
                let undoManager = undoManager
                Task { await session.rotate([item], clockwise: clockwise, undoManager: undoManager) }
            }
        }
        if canEditMetadata(item) { actions.editDateAndLocation = { editingMetadata = item } }
        actions.export = { save(item) }
        if let services = session.services { actions.shareItems = [ShareableMedia(item: item, services: services)] }
        actions.shareTitle = item.name
        actions.slideshow = { playSlideshow() }
        if session.features.has(.systemtags) {
            let ids = cullingIds
            actions.cull = { command in culling.apply(command, ids: ids, session: session, undoManager: undoManager) }
        }
        #if os(macOS)
            if isImage, !item.isCollectionChild {
                actions.editWith = EditWithTarget(item: item) { app in ExternalEditCenter.shared.open(item, with: app, session: session) }
            }
            if DesktopPictureAction.isOffered(item) { actions.useAsDesktopPicture = { DesktopPictureAction.use(item, session: session) } }
        #endif
        return actions
    }

    func zoom(_ kind: ViewerZoomCommand.Kind) {
        zoomCommand = ViewerZoomCommand(id: (zoomCommand?.id ?? 0) + 1, kind: kind)
    }

    func canEditMetadata(_ item: MediaItem) -> Bool {
        item.permissions.canWrite && !item.isCollectionChild
    }

    /// Saves the original: into a folder the user picks on the Mac (as "Export…" in the grid), to the photo library elsewhere.
    func save(_ item: MediaItem) {
        guard let services = session.services else { return }
        saver.save([item], services: services)
    }

    /// An archived photo leaves the place it was opened from, so the viewer moves on. Unarchiving stays: the photo
    /// is shown again everywhere, and "Archive" in the same menu takes it back.
    func toggleArchive(_ item: MediaItem) {
        let undoManager = undoManager
        if item.isArchived {
            Task { await session.perform(.unarchive([item]), undoManager: undoManager) }
        } else {
            Task { await session.perform(.archive([item]), undoManager: undoManager) }
            remove([item.fileId])
        }
    }

    /// Follows changes announced by the session: a photo archived or deleted elsewhere (or again, with Redo) leaves
    /// the viewer; one brought back with Undo gets its page back, where it was in the context.
    func apply(_ change: ViewerPageChange) {
        switch change {
        case .none:
            break
        case .remove(let ids):
            let gone: Set<FileID> = ids.filter { isInContext($0) }
            guard !gone.isEmpty else { return }
            remove(gone)
        case .restore(let ids):
            let library = session.services?.library
            // Only photos that are in the library again (a restore from the trash bin can fail).
            let back: Set<FileID> = removed.intersection(ids).filter { id in (try? library?.item(id)) != nil }
            guard !back.isEmpty else { return }
            removed.subtract(back)
            realignments += 1
        }
    }

    /// A photo of this viewer: a page, or a copy in a stack.
    func isInContext(_ id: FileID) -> Bool {
        ids.contains(id) || ViewerStacks.tile(of: id, in: stacks) != nil
    }

    /// The photos are gone from this context (deleted, archived). A stack's page stays while one of its copies does and
    /// shows that one; a page that is gone is taken out and the next one shown — the previous one after the last, and
    /// the viewer closes after the only one.
    func remove(_ gone: Set<FileID>) {
        let after: Set<FileID> = removed.union(gone)
        if let current, ViewerStacks.pages([current], stacks: stacks, removed: after).isEmpty {
            // The other pages first, so that the page shown next is one that stays.
            removed = after.subtracting(ViewerStacks.copies(of: current, stacks: stacks))
            guard let next = ViewerNavigation.neighbour(in: shownIds, of: current) else {
                dismiss()
                return
            }
            self.current = next
        }
        removed = after
        realignments += 1
    }
}

/// What a change announced by the session (`SessionModel.lastChange`) means for the viewer's pages.
enum ViewerPageChange: Equatable {
    case none
    /// The photos left the context (archived, deleted): their pages are taken out.
    case remove(Set<FileID>)
    /// The change was undone: the photos are back and so are their pages.
    case restore(Set<FileID>)

    init(_ notice: ChangeNotice) {
        let ids: Set<FileID>
        switch notice.change {
        case .archive, .delete:
            // Only the photos the change really altered (an archived photo is not archived again).
            ids = Set(notice.change.fileIds)
        default:
            self = .none
            return
        }
        guard !ids.isEmpty else {
            self = .none
            return
        }
        self = notice.isReverted ? .restore(ids) : .remove(ids)
    }
}
