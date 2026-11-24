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
    /// Moved to the server's trash bin. Undone by taking back the deletes still queued (their `rows` are put back) and
    /// restoring the others from the trash bin. `perform` fills in `rows`.
    case delete([MediaItem], rows: DeletedRows = DeletedRows())

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
        case .delete(let items, _):
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

    /// The photos the change alters, in the order of `operations`.
    public var fileIds: [FileID] {
        switch self {
        case .favorite(let items, _): items.map(\.fileId)
        case .archive(let items): items.filter(Self.canArchive).map(\.fileId)
        case .unarchive(let items): items.filter(\.isArchived).map(\.fileId)
        case .removeFromAlbum(let members, _): members.map(\.fileId)
        case .delete(let items, _): items.filter(\.permissions.canDelete).map(\.fileId)
        }
    }

    /// Whether the change can be taken back on a server with these features. A delete needs the trash bin, and a photo
    /// in the user's own files: a deleted share does not land in the user's trash bin.
    public func isUndoable(trashbin: Bool) -> Bool {
        switch self {
        case .delete(let items, _): trashbin && items.contains { $0.permissions.canDelete && Self.goesToOwnTrash($0) }
        default: !inverseOperations.isEmpty
        }
    }

    /// Whether a deleted file lands in the user's own trash bin: not one shared with the user (deleting it only removes
    /// the share, or puts it into the owner's trash bin).
    static func goesToOwnTrash(_ item: MediaItem) -> Bool {
        !item.mountType.hasPrefix("shared") && !item.permissions.isShared
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
    /// The change is being taken back: Undo is not offered again meanwhile.
    public var isReverting = false
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

/// Where the session's undoable changes went. One session serves every window; each window has its own undo manager.
@MainActor
struct UndoState {
    /// The undo manager the last change (`SessionModel.lastChange`) was registered with, and the id of that registration
    /// (its user info in the undo manager).
    weak var manager: UndoManager?
    var registration: String?
    /// Every undo manager a change of this session was registered with: cleared when the session stops.
    let managers = NSHashTable<UndoManager>.weakObjects()
    /// Registrations whose change was taken back without their undo manager: undoing them later does nothing.
    var consumed: Set<String> = []
    /// The undo that runs (`SessionModel.undo(_:)` waits for it).
    var reverting: Task<Void, Never>?
}

/// Undoable changes (SPEC §7.3): every one goes through the outbox, registers its inverse with the undo manager of the
/// window it was made in and leaves a notice for the confirmation banner.
extension SessionModel {
    private static let undoLogger = Logger(subsystem: "com.nextcloud.photos", category: "session")
    /// Marks the session's registrations in an undo manager, so that the banner only ever undoes its own change.
    static let undoRegistrationKey = UndoManager.UserInfoKey("com.nextcloud.photos.change")

    /// Makes a change, registers its undo with `undoManager` (the one of the window the change was made in) and
    /// announces it.
    public func perform(_ change: UndoableChange, undoManager: UndoManager?) async {
        guard change.count > 0, !isStopped else { return }
        let change = await captured(change)
        // Queued before Undo is offered: an undo always finds the operations it takes back.
        await apply(change)
        guard !isStopped else { return }
        let undoable = change.isUndoable(trashbin: features.has(.trashbin))
        let registration = undoable ? undoManager.map { registerUndo(of: change, reverting: true, on: $0) } : nil
        announce(ChangeNotice(change: change, canUndo: undoable), manager: undoManager, registration: registration)
    }

    /// Takes back the change of a notice (the banner's Undo button): through the undo manager when the notice's own
    /// registration is on top of its stack, so that Edit › Redo offers it again; directly otherwise.
    public func undo(_ notice: ChangeNotice) async {
        guard notice.canUndo, !notice.isReverted, !notice.isReverting, let current = lastChange, current.id == notice.id,
            !current.isReverting
        else { return }
        // At once, before anything is awaited: a second tap finds the notice reverting and does nothing.
        lastChange?.isReverting = true
        if let manager = undoState.manager, let registration = undoState.registration, manager.canUndo,
            manager.undoActionUserInfoValue(forKey: Self.undoRegistrationKey) as? String == registration
        {
            manager.undo()
        } else {
            // The registration stays in its undo manager (under other actions, or in a window that is gone): it must
            // not take the change back a second time.
            if let registration = undoState.registration { undoState.consumed.insert(registration) }
            startRevert(notice.change)
        }
        await undoState.reverting?.value
    }

    public func dismissNotice(_ id: UUID) {
        if lastChange?.id == id { lastChange = nil }
    }

    /// Forgets everything that could be undone (the session stops: account switch or removal).
    func clearUndo() {
        for manager in undoState.managers.allObjects { manager.removeAllActions(withTarget: self) }
        undoState = UndoState()
        lastChange = nil
    }

    /// Registers the action that reverts (or, after an undo, repeats) a change. Returns the registration's id.
    @discardableResult
    func registerUndo(of change: UndoableChange, reverting: Bool, on manager: UndoManager) -> String {
        let registration = UUID().uuidString
        undoState.managers.add(manager)
        manager.registerUndo(withTarget: self) { session in
            session.runRegistered(change, reverting: reverting, registration: registration, on: manager)
        }
        manager.setActionName(change.actionName)
        manager.setActionUserInfoValue(registration, forKey: Self.undoRegistrationKey)
        return registration
    }

    /// Runs a registered undo or redo. The opposite action is registered from inside the handler, while the undo manager
    /// is undoing or redoing: that is what puts it on the other stack.
    private func runRegistered(_ change: UndoableChange, reverting: Bool, registration: String, on manager: UndoManager) {
        // The session stopped, or the change was taken back already: nothing to do, and nothing to redo.
        guard !isStopped, undoState.consumed.remove(registration) == nil else { return }
        let opposite = registerUndo(of: change, reverting: !reverting, on: manager)
        if reverting {
            if undoState.registration == registration { lastChange?.isReverting = true }
            startRevert(change)
        } else {
            Task { await self.redo(change, registration: opposite, on: manager) }
        }
    }

    private func startRevert(_ change: UndoableChange) {
        undoState.reverting = Task { await self.revert(change) }
    }

    private func announce(_ notice: ChangeNotice, manager: UndoManager?, registration: String?) {
        lastChange = notice
        undoState.manager = registration == nil ? nil : manager
        undoState.registration = registration
    }

    /// A delete with what it takes out of the index (rows, album places), for an undo before it ran.
    func captured(_ change: UndoableChange) async -> UndoableChange {
        guard case .delete(let items, let rows) = change, rows.isEmpty, let services else { return change }
        let ids = change.fileIds
        let indexed = (try? await services.library.fetchItems(ids)) ?? [:]
        let members = (try? services.collections.memberships(of: ids)) ?? []
        return .delete(items, rows: DeletedRows(items: ids.compactMap { indexed[$0] }, albumItems: members))
    }

    func apply(_ change: UndoableChange) async {
        Self.undoLogger.info("change: \(change.kind.rawValue, privacy: .public) × \(change.count)")
        await enqueue(change.operations)
    }

    func redo(_ change: UndoableChange, registration: String, on manager: UndoManager) async {
        guard !isStopped else { return }
        await apply(change)
        guard !isStopped else { return }
        announce(ChangeNotice(change: change, canUndo: true), manager: manager, registration: registration)
    }

    /// Takes a change back.
    func revert(_ change: UndoableChange) async {
        Self.undoLogger.info("undo: \(change.kind.rawValue, privacy: .public) × \(change.count)")
        var notice = ChangeNotice(change: change, isReverted: true, canUndo: false)
        if case .delete(let items, let rows) = change {
            notice.failures = await undoDelete(items.filter(\.permissions.canDelete), rows: rows)
        } else {
            await enqueue(change.inverseOperations)
        }
        guard !isStopped else { return }
        announce(notice, manager: nil, registration: nil)
    }

    /// Takes a delete back. Deletes still queued are taken out of the queue, and their rows come back at once (offline
    /// too); a delete that failed for good never deleted anything. Only what reached the server is restored from the
    /// trash bin. Returns how many items could not be brought back.
    func undoDelete(_ items: [MediaItem], rows: DeletedRows) async -> Int {
        guard let services, !items.isEmpty else { return items.count }
        let outcome = await services.outbox.withdrawDeletes(of: Set(items.map(\.fileId)), restoring: rows)
        if !outcome.refused.isEmpty { await refreshFailedOperations() }
        let deleted = items.filter { outcome.deleted.contains($0.fileId) }
        guard !deleted.isEmpty else { return 0 }
        return await restoreFromTrash(deleted, rows: rows)
    }

    /// Restores deleted items from the server's trash bin, with their places in albums. Returns how many could not be
    /// restored.
    func restoreFromTrash(_ items: [MediaItem], rows: DeletedRows) async -> Int {
        guard let services, !items.isEmpty else { return items.count }
        // A file shared with the user is not in the user's trash bin.
        let wanted = Set(items.filter(UndoableChange.goesToOwnTrash).map(\.fileId))
        var restored: Set<FileID> = []
        do {
            // By file id, whatever the type (the timeline also shows TIFF and RAW files).
            for item in try await services.api.trash(mimeTypes: nil) where wanted.contains(item.fileId) && !restored.contains(item.fileId) {
                do {
                    try await services.api.restore(item)
                    restored.insert(item.fileId)
                } catch {
                    Self.undoLogger.error("undo: restore failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.undoLogger.error("undo: could not read the trash bin: \(error.localizedDescription, privacy: .public)")
        }
        guard !restored.isEmpty else { return items.count }
        // The restored files come back into the index (or with the next sync, if that fails) …
        do {
            try await services.sync.restore(fileIds: restored)
        } catch {
            Self.undoLogger.error("undo: could not read the restored files: \(error.localizedDescription, privacy: .public)")
        }
        // … and into their albums: the server takes a deleted file out of every album.
        await enqueue(
            Self.albumAdditions(restoring: items.filter { restored.contains($0.fileId) }, rows: rows, albums: services.collections))
        return items.count - restored.count
    }

    /// The album additions that put restored photos back where they were. Photos an album's filters chose come back by
    /// themselves; public link albums are not changed by hand.
    nonisolated static func albumAdditions(restoring items: [MediaItem], rows: DeletedRows, albums: CollectionStore) -> [PendingOperation] {
        let paths = Dictionary(items.map { ($0.fileId, $0.path) }, uniquingKeysWith: { a, _ in a })
        return rows.albumItems.compactMap { member in
            guard let path = paths[member.fileId], member.origin != "filters",
                let album = try? albums.album(id: member.albumId), album.kind != .publicLink
            else { return nil }
            return .addToAlbum(albumId: album.id, albumName: album.name, albumKind: album.kind, fileId: member.fileId, path: path)
        }
    }
}
