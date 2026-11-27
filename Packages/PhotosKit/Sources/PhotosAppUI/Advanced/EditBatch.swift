// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// Copy Edits, Paste Edits and presets on a selection (SPEC §21.6.5).
enum EditBatch {
    /// Each photo's new edit: its own edit (or none) with the look of `look`; its crop and turns stay. Videos are left out.
    @MainActor
    static func recipes(_ look: EditRecipe, for items: [MediaItem], edits: (FileID) -> EditRecipe?) -> [(
        item: MediaItem, recipe: EditRecipe
    )] {
        items.filter { $0.kind == .image }.map { item in
            let own =
                edits(item.fileId)
                ?? EditRecipe(original: EditRecipe.Original(name: item.name, etag: item.etag, width: item.width, height: item.height))
            return (item, own.withLook(look, developsRAW: EditRendering.isRAW(name: item.name)))
        }
    }

    /// The photo whose look Copy Edits takes: one edited photo.
    @MainActor
    static func copySource(_ items: [MediaItem]?, edits: (FileID) -> EditRecipe?) -> EditRecipe? {
        guard let items, items.count == 1, let item = items.first, item.kind == .image, let recipe = edits(item.fileId),
            recipe.hasLook
        else { return nil }
        return recipe
    }
}

extension PhotoTaskModel {
    /// Applies a look to many photos at once (Paste Edits, a preset): the edits are saved as one undoable change, then
    /// the edited pictures are rendered in the background with progress, so the grid shows them at once. With "Apply
    /// Edits to the File" on, each photo that can be is written into its file instead (the original kept as a named
    /// version); the others get the edit.
    func applyLook(_ look: EditRecipe, to items: [MediaItem], session: SessionModel, undoManager: UndoManager?) {
        guard !isRunning, let services = session.services else { return }
        let pairs = EditBatch.recipes(look, for: items) { services.edits.recipe(for: $0) }
        guard !pairs.isEmpty else { return }
        let toFile = PhotoEditSaving.appliesToFile
        start(.edit, total: pairs.count) { progress in
            var asRecipe: [(item: MediaItem, recipe: EditRecipe)] = []
            var baked: [(item: MediaItem, recipe: EditRecipe)] = []
            for pair in pairs {
                if toFile && PhotoEditSaving.overwriteProblem(pair.item) == nil && !EditRendering.isRAW(name: pair.item.name) {
                    baked.append(pair)
                } else {
                    asRecipe.append(pair)
                }
            }
            if !asRecipe.isEmpty { await session.saveEdits(asRecipe, undoManager: undoManager) }
            let order: [(item: MediaItem, recipe: EditRecipe, bake: Bool)] =
                baked.map { ($0.item, $0.recipe, true) } + asRecipe.map { ($0.item, $0.recipe, false) }
            let run = await MediaSaveRunner.run(order.map { Job(item: $0.item, recipe: $0.recipe, bake: $0.bake) }, progress: progress) {
                job in
                if job.bake {
                    try await PhotoEditSaving.overwrite(job.item, with: job.recipe, services: services)
                } else {
                    // The tile's rendition, made now in the background.
                    let request = ImagePipeline.Request(
                        fileId: job.item.fileId, etag: job.item.etag, bucket: 256, hasPreview: job.item.hasPreview,
                        mimeType: job.item.mimeType, originalURL: services.originalURL(for: job.item))
                    _ = await services.images.preview(request)
                }
            }
            if !baked.isEmpty { await session.syncNow() }
            return run
        }
    }

    struct Job: Sendable {
        var item: MediaItem
        var recipe: EditRecipe
        var bake: Bool
    }
}

extension MediaGridScreen {
    /// Copy Edits, Paste Edits and Presets ▸ in the grid's context menu: for photos the user may edit (SPEC §21.6.5).
    func editLookActions(_ items: [MediaItem]?) -> [GridMenuAction] {
        guard let items, items.contains(where: { $0.kind == .image }), let services = session.services else { return [] }
        var actions: [GridMenuAction] = []
        let edits: (FileID) -> EditRecipe? = { services.edits.recipe(for: $0) }
        if let source = EditBatch.copySource(items, edits: edits) {
            actions.append(
                GridMenuAction(
                    id: "edits.copy",
                    title: String(
                        localized: "Copy Edits", bundle: .module, comment: "Editor: copies the look of this edit for other photos."),
                    systemImage: "doc.on.doc"
                ) { _ in
                    EditClipboard.look = source
                })
        }
        if let look = EditClipboard.look {
            actions.append(
                GridMenuAction(
                    id: "edits.paste",
                    title: String(localized: "Paste Edits", bundle: .module, comment: "Editor: applies copied edits to this photo."),
                    systemImage: "doc.on.clipboard"
                ) { ids in
                    applyLook(look, ids)
                })
        }
        let presets = PresetsPanel.all(user: services.edits.presets.userPresets())
        actions.append(
            GridMenuAction(
                id: "edits.presets",
                title: String(localized: "Apply Preset", bundle: .module, comment: "Context menu: submenu of edit presets."),
                systemImage: "square.stack", handler: { _ in },
                children: presets.map { preset in
                    GridMenuAction(id: "edits.preset.\(preset.id)", title: PresetsPanel.name(of: preset), systemImage: "camera.filters") {
                        ids in
                        applyLook(preset.recipe, ids)
                    }
                }))
        return actions
    }

    func applyLook(_ look: EditRecipe, _ ids: [FileID]) {
        let undoManager = undoManager
        withItems(withStacks(ids)) { items in photoTasks.applyLook(look, to: items, session: session, undoManager: undoManager) }
    }
}
