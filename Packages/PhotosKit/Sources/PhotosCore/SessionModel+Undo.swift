// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// A change to photos that can be taken back (Edit › Undo, ⌘Z, shake): what was changed, with the items as they were
/// before, so that the inverse can be worked out.
public enum UndoableChange: Sendable, Equatable {
    case favorite([MediaItem], value: Bool)
    case archive([MediaItem])
    case unarchive([MediaItem])
    case removeFromAlbum([AlbumMember], album: Album)
    /// Moved to the server's trash bin; undone by restoring from there.
    case delete([MediaItem])

    /// A photo in an album, as much of it as removing it and adding it again needs.
    public struct AlbumMember: Sendable, Equatable {
        public var fileId: FileID
        /// Name of the photo inside the album collection.
        public var childName: String
        /// Path in the user's files; `nil` for a photo somebody else added (it cannot be added again by this user).
        public var ownPath: String?

        public init(fileId: FileID, childName: String, ownPath: String?) {
            self.fileId = fileId
            self.childName = childName
            self.ownPath = ownPath
        }
    }

    public enum Kind: String, Sendable {
        case favorite, unfavorite, archive, unarchive, removeFromAlbum, delete
    }

    public var kind: Kind {
        switch self {
        case .favorite(_, let value): value ? .favorite : .unfavorite
        case .archive: .archive
        case .unarchive: .unarchive
        case .removeFromAlbum: .removeFromAlbum
        case .delete: .delete
        }
    }

    /// Name of the change in Edit › Undo ("Undo Archive").
    public var actionName: String {
        switch kind {
        case .favorite: String(localized: "Add to Favorites", bundle: .module)
        case .unfavorite: String(localized: "Remove from Favorites", bundle: .module)
        case .archive: String(localized: "Archive", bundle: .module)
        case .unarchive: String(localized: "Unarchive", bundle: .module)
        case .removeFromAlbum: String(localized: "Remove from Album", bundle: .module)
        case .delete: String(localized: "Delete", bundle: .module)
        }
    }

    /// The folder archived files are moved to (as `Outbox` does).
    static let archiveFolder = "/.archive"

    /// The writes that make the change.
    public var operations: [PendingOperation] {
        switch self {
        case .favorite(let items, let value):
            items.map { .favorite(fileId: $0.fileId, path: $0.path, value: value) }
        case .archive(let items):
            items.filter(Self.canArchive).map { .archive(fileId: $0.fileId, path: $0.path) }
        case .unarchive(let items):
            items.filter(\.isArchived).map { .unarchive(fileId: $0.fileId, path: $0.path) }
        case .removeFromAlbum(let members, let album):
            members.map {
                .removeFromAlbum(
                    albumId: album.id, albumName: album.name, albumKind: album.kind, fileId: $0.fileId, childName: $0.childName)
            }
        case .delete(let items):
            items.filter(\.permissions.canDelete).map { .delete(fileId: $0.fileId, path: $0.path) }
        }
    }

    /// The writes that take the change back, for everything but a delete (which is restored from the trash bin). Only
    /// what the change really altered is touched: a photo that already was a favourite stays one.
    public var inverseOperations: [PendingOperation] {
        switch self {
        case .favorite(let items, let value):
            items.filter { $0.isFavorite != value }.map { .favorite(fileId: $0.fileId, path: $0.path, value: !value) }
        case .archive(let items):
            // The archive moved the file: it is taken back from where it is now.
            items.filter(Self.canArchive).map { .unarchive(fileId: $0.fileId, path: Self.archiveFolder + $0.path) }
        case .unarchive(let items):
            items.filter(\.isArchived).map { .archive(fileId: $0.fileId, path: Self.unarchivedPath($0.path)) }
        case .removeFromAlbum(let members, let album):
            members.compactMap { member in
                member.ownPath.map {
                    .addToAlbum(albumId: album.id, albumName: album.name, albumKind: album.kind, fileId: member.fileId, path: $0)
                }
            }
        case .delete:
            []
        }
    }

    /// Number of items the change alters.
    public var count: Int { operations.count }

    /// Whether the change can be taken back on a server with these features.
    public func isUndoable(trashbin: Bool) -> Bool {
        switch self {
        case .delete: trashbin && count > 0
        default: !inverseOperations.isEmpty
        }
    }

    static func canArchive(_ item: MediaItem) -> Bool {
        item.isOwnStorage && item.permissions.canDelete && !item.isArchived
    }

    static func unarchivedPath(_ path: String) -> String {
        path.hasPrefix(archiveFolder + "/") ? String(path.dropFirst(archiveFolder.count)) : path
    }
}

/// What the confirmation banner says about the last change ("Archived 3 items · Undo").
public struct ChangeNotice: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var change: UndoableChange
    /// The change has been taken back ("Restored 3 items").
    public var isReverted = false
    public var canUndo: Bool
    /// Items an undo could not bring back.
    public var failures = 0

    public init(change: UndoableChange, isReverted: Bool = false, canUndo: Bool, failures: Int = 0) {
        self.change = change
        self.isReverted = isReverted
        self.canUndo = canUndo
        self.failures = failures
    }
}

/// Undoable changes (SPEC §7.3): every one goes through the outbox, registers its inverse with the window's undo manager
/// and leaves a notice for the confirmation banner.
extension SessionModel {
    private static let undoLogger = Logger(subsystem: "com.nextcloud.photos", category: "session")

    /// Makes a change, registers its undo and announces it.
    public func perform(_ change: UndoableChange) async {
        guard change.count > 0 else { return }
        let undoable = change.isUndoable(trashbin: features.has(.trashbin))
        if undoable { registerUndo(of: change, reverting: true) }
        lastChange = ChangeNotice(change: change, canUndo: undoable)
        await apply(change)
    }

    /// Takes back the change of a notice (the banner's Undo button): through the undo manager when the change is on top
    /// of its stack, so that Edit › Redo offers it again.
    public func undo(_ notice: ChangeNotice) async {
        guard notice.canUndo, !notice.isReverted, lastChange?.id == notice.id else { return }
        if let undoManager, undoManager.canUndo, undoManager.undoActionName == notice.change.actionName {
            undoManager.undo()
        } else {
            await revert(notice.change)
        }
    }

    public func dismissNotice(_ id: UUID) {
        if lastChange?.id == id { lastChange = nil }
    }

    /// Registers the action that reverts (or, after an undo, repeats) a change. The opposite action is registered from
    /// inside the handler, while the undo manager is undoing or redoing: that is what puts it on the other stack.
    func registerUndo(of change: UndoableChange, reverting: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.registerUndo(of: change, reverting: !reverting)
                Task { @MainActor in
                    if reverting { await session.revert(change) } else { await session.redo(change) }
                }
            }
        }
        undoManager.setActionName(change.actionName)
    }

    func apply(_ change: UndoableChange) async {
        Self.undoLogger.info("change: \(change.kind.rawValue, privacy: .public) × \(change.count)")
        await enqueue(change.operations)
    }

    func redo(_ change: UndoableChange) async {
        lastChange = ChangeNotice(change: change, canUndo: true)
        await apply(change)
    }

    /// Takes a change back.
    func revert(_ change: UndoableChange) async {
        Self.undoLogger.info("undo: \(change.kind.rawValue, privacy: .public) × \(change.count)")
        var notice = ChangeNotice(change: change, isReverted: true, canUndo: false)
        if case .delete(let items) = change {
            notice.failures = await restoreFromTrash(items.filter(\.permissions.canDelete))
        } else {
            await enqueue(change.inverseOperations)
        }
        lastChange = notice
    }

    /// Restores deleted items from the server's trash bin. Returns how many could not be restored.
    func restoreFromTrash(_ items: [MediaItem]) async -> Int {
        guard let services, !items.isEmpty else { return items.count }
        // The deletes may still be on their way to the server.
        for _ in 0..<40 {
            guard let pending = try? await services.outbox.pendingCount(), pending > 0, !isStopped else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        var failures = items.count
        do {
            let wanted = Set(items.map(\.fileId))
            let trashed = try await services.api.trash(mimeTypes: features.allMimeTypes).filter { wanted.contains($0.fileId) }
            for item in trashed {
                do {
                    try await services.api.restore(item)
                    failures -= 1
                } catch {
                    Self.undoLogger.error("undo: restore failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.undoLogger.error("undo: could not read the trash bin: \(error.localizedDescription, privacy: .public)")
        }
        // Restored files come back through the index, like files restored from "Recently deleted".
        if failures < items.count { await syncNow(forceReconcile: true) }
        return failures
    }
}
