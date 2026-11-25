// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import GRDB
import OSLog
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

extension Notification.Name {
    /// Edits of photos changed (here, by an undo, or synced from another device); `userInfo["fileIds"]` is a
    /// `Set<FileID>`. Grids reload the tiles of those photos.
    public static let photosEditsChanged = Notification.Name("com.nextcloud.photos.editsChanged")
}

/// One photo's edit before and after a change (SPEC §16.3): enough to make the change and to take it back.
public struct EditChange: Sendable, Equatable {
    public var fileId: FileID
    public var name: String
    public var before: EditRecipe?
    public var after: EditRecipe?

    public init(fileId: FileID, name: String, before: EditRecipe?, after: EditRecipe?) {
        self.fileId = fileId
        self.name = name
        self.before = before
        self.after = after
    }
}

/// Non-destructive editing (SPEC §16.3): every change of an edit is undoable and in the undo history.
extension SessionModel {
    /// Saves the editor's result for `item`: shown everywhere at once, synced to the server in the background.
    public func saveEdit(_ recipe: EditRecipe, for item: MediaItem, undoManager: UndoManager?) async {
        guard let services else { return }
        let before = services.edits.recipe(for: item.fileId)
        var after = recipe
        after.updatedAt = Date()
        if after.original == nil {
            after.original = EditRecipe.Original(name: item.name, etag: item.etag, width: item.width, height: item.height)
        }
        let change = EditChange(fileId: item.fileId, name: item.name, before: before, after: after.isIdentity ? nil : after)
        guard !Self.sameEdit(change.before, change.after) else { return }
        await perform(.edit([change], action: after.isIdentity ? .revert : .edit), undoManager: undoManager)
    }

    /// The edit of several photos at once (a RAW and the JPEG beside it): one change, one entry in the history.
    public func saveEdits(_ recipes: [(item: MediaItem, recipe: EditRecipe)], undoManager: UndoManager?) async {
        guard let services, !recipes.isEmpty else { return }
        let now = Date()
        let changes: [EditChange] = recipes.map { item, recipe in
            var after = recipe
            after.updatedAt = now
            if after.original == nil {
                after.original = EditRecipe.Original(name: item.name, etag: item.etag, width: item.width, height: item.height)
            }
            return EditChange(
                fileId: item.fileId, name: item.name, before: services.edits.recipe(for: item.fileId),
                after: after.isIdentity ? nil : after)
        }
        // Photos whose edit stays as it was (a RAW opened for development and left as the camera made it) are no change.
        let real = changes.filter { !Self.sameEdit($0.before, $0.after) }
        guard !real.isEmpty else { return }
        let reverts = real.allSatisfy { $0.after == nil }
        await perform(.edit(real, action: reverts ? .revert : .edit), undoManager: undoManager)
    }

    /// Back to the original: the edits of `items` are removed (the originals never changed).
    public func revertToOriginal(_ items: [MediaItem], undoManager: UndoManager?) async {
        guard let services else { return }
        let changes: [EditChange] = items.compactMap { item in
            guard let before = services.edits.recipe(for: item.fileId) else { return nil }
            return EditChange(fileId: item.fileId, name: item.name, before: before, after: nil)
        }
        await perform(.edit(changes, action: .revert), undoManager: undoManager)
    }

    /// Image ▸ Rotate: turns the photos a quarter, as an edit (the original stays as it is).
    public func rotate(_ items: [MediaItem], clockwise: Bool, undoManager: UndoManager?) async {
        guard let services else { return }
        let now = Date()
        let changes: [EditChange] = items.filter { $0.kind == .image }.map { item in
            let before = services.edits.recipe(for: item.fileId)
            var after =
                before
                ?? EditRecipe(original: EditRecipe.Original(name: item.name, etag: item.etag, width: item.width, height: item.height))
            after.edits.rotate(clockwise: clockwise)
            after.updatedAt = now
            return EditChange(fileId: item.fileId, name: item.name, before: before, after: after.isIdentity ? nil : after)
        }
        await perform(.edit(changes, action: .rotate), undoManager: undoManager)
    }

    /// Whether a photo shows an edit.
    public func isEdited(_ fileId: FileID) -> Bool {
        _ = editRevision
        return services?.edits.recipe(for: fileId) != nil
    }

    /// The edit of a photo, observed: views reading it are drawn again when edits change.
    public func edit(of fileId: FileID) -> EditRecipe? {
        _ = editRevision
        return services?.edits.recipe(for: fileId)
    }

    /// Writes the edits of a change (or, reverting, puts back the ones before it).
    func applyEdits(_ changes: [EditChange], reverting: Bool) async {
        guard let services else { return }
        var recipes: [FileID: EditRecipe?] = [:]
        for change in changes { recipes[change.fileId] = reverting ? change.before : change.after }
        await services.edits.restore(recipes)
    }

    /// Called by the edit library: the tiles and the viewer of those photos are drawn again.
    func editsChanged(_ ids: Set<FileID>) {
        editRevision &+= 1
        NotificationCenter.default.post(name: .photosEditsChanged, object: self, userInfo: ["fileIds": ids])
    }

    /// Starts following the edit library (once per session).
    func observeEdits() {
        guard let services else { return }
        Task { [weak self] in
            await services.edits.observe { [weak self] ids in
                Task { @MainActor [weak self] in self?.editsChanged(ids) }
            }
        }
    }

    /// The RAW file beside a JPEG or HEIC (or the JPEG beside a RAW): the copy of the same shot in the same folder, as
    /// the stacking rule finds it (SPEC §16.3.2).
    public func rawPartner(of item: MediaItem) -> MediaItem? {
        guard let services, item.kind == .image else { return nil }
        let base = (item.name as NSString).deletingPathExtension
        let pattern = Self.likeEscaped(item.directory == "/" ? "/\(base)." : "\(item.directory)/\(base).") + "%"
        let candidates =
            (try? services.database.writer.read { db in
                try MediaItem.fetchAll(db, sql: "SELECT * FROM media WHERE path LIKE ? ESCAPE '\\' LIMIT 8", arguments: [pattern])
            }) ?? []
        let isRAW = EditRendering.isRAW(name: item.name)
        return candidates.first { other in
            other.fileId != item.fileId && other.kind == .image
                && (other.name as NSString).deletingPathExtension == base && EditRendering.isRAW(name: other.name) != isRAW
        }
    }

    nonisolated static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(
            of: "_", with: "\\_")
    }
}

/// The still of a Live Photo whose effect replaces it (SPEC §16.3.3): a long exposure of its motion, or another frame
/// of it as the key photo. Rendered from the motion part, which is downloaded into the originals cache.
enum LiveStills {
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "edits")

    static func still(
        fileId: FileID, recipe: EditRecipe, maxPixelSize: Int, library: LibraryStore, originals: OriginalStore,
        connection: ServerConnection
    ) async -> CGImage? {
        guard let live = recipe.live, live.changesStill, let item = try? library.item(fileId), let peer = item.livePhotoPeer,
            let motion = try? library.item(peer)
        else { return nil }
        do {
            let file = try await originals.original(
                fileId: peer, etag: motion.etag, url: connection.originalURL(path: motion.path))
            if live.effect == .longExposure {
                return try await LivePhotoEffects.longExposure(of: file, maxPixelSize: maxPixelSize)
            }
            if let time = live.keyFrameTime {
                return try await LivePhotoEffects.frame(of: file, at: time, maxPixelSize: maxPixelSize)
            }
        } catch {
            logger.error("live still of \(fileId) failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }
}
