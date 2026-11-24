// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Why a rating or flag could not be given.
public enum CullingError: LocalizedError, Equatable {
    /// The server has no system tags (the app is off).
    case unavailable
    /// The tags do not exist yet and the server cannot be reached to create them.
    case needsConnection
    /// The server lets only administrators create tags.
    case cannotCreateTags(names: [String])

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "Ratings and flags need the Collaborative tags app on your server.", bundle: .module,
                comment: "Culling error: the server has no system tags.")
        case .needsConnection:
            String(
                localized: "Connect to your server once to start rating: the app creates the tags for ratings and flags there.",
                bundle: .module, comment: "Culling error: the rating tags must be created on the server, which cannot be reached.")
        case .cannotCreateTags(let names):
            String(
                localized:
                    "Your server only lets administrators create tags. Ask your administrator to create these collaborative tags: \(names.joined(separator: ", ")).",
                bundle: .module, comment: "Culling error. The placeholder is a list of tag names such as ★★★, Pick, Rejected.")
        }
    }
}

/// Ratings and flags (SPEC §15.2): collaborative system tags named "★"…"★★★★★", "Pick" and "Rejected", given through
/// the outbox like any tag (optimistic, offline, synced to every device and the web).
extension SessionModel {
    /// The marks the index has for these files.
    public func cullingMarks(of fileIds: [FileID]) -> [FileID: CullingMark] {
        guard let services else { return [:] }
        let names = (try? CullingStore(database: services.database).cullingTagNames(of: fileIds)) ?? [:]
        return names.mapValues { CullingTags.mark(fromTagNames: $0) }
    }

    /// Applies a key or menu command to the items. Returns the marks they had before (for Undo).
    @discardableResult
    public func applyCulling(_ command: CullingCommand, to items: [MediaItem]) async throws -> [FileID: CullingMark] {
        let before = cullingMarks(of: items.map(\.fileId))
        var targets: [FileID: CullingMark] = [:]
        for item in items { targets[item.fileId] = command.applied(to: before[item.fileId] ?? .none) }
        try await setCullingMarks(targets, on: items)
        return before
    }

    /// Gives each item the mark in `marks` (missing: none). Only the tags that differ are changed.
    public func setCullingMarks(_ marks: [FileID: CullingMark], on items: [MediaItem]) async throws {
        guard let services else { return }
        guard features.has(.systemtags) else { throw CullingError.unavailable }
        let store = CullingStore(database: services.database)
        let current = (try? store.cullingTagNames(of: items.map(\.fileId))) ?? [:]
        let plans = items.map { item in
            (item, CullingTags.changes(from: current[item.fileId] ?? [], to: marks[item.fileId] ?? .none))
        }
        let needed = Set(plans.flatMap { $0.1.add })
        let tags = try await cullingTags(needed, store: store)
        let known = (try? store.knownTags()) ?? [:]
        let byName = Dictionary(known.values.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var operations: [PendingOperation] = []
        for (item, change) in plans {
            for name in change.remove {
                guard let tag = byName[name] else { continue }
                operations.append(.tag(TagChange(fileId: item.fileId, tagId: tag.id, tagName: tag.name, assign: false)))
            }
            for meaning in change.add {
                guard let tag = tags[meaning] else { continue }
                operations.append(.tag(TagChange(fileId: item.fileId, tagId: tag.id, tagName: tag.name, assign: true)))
            }
        }
        await enqueue(operations)
    }

    /// The server's tags for these meanings: from the index, else looked up on the server, else created there
    /// (collaborative: visible and assignable for everyone, as the web's tag picker makes them).
    func cullingTags(_ meanings: Set<CullingTags.Meaning>, store: CullingStore) async throws -> [CullingTags.Meaning: SystemTag] {
        var result = (try? store.knownTags()) ?? [:]
        let missing = meanings.filter { result[$0] == nil }
        guard !missing.isEmpty, let services else { return result }
        let server: [SystemTag]
        do {
            server = try await services.api.allTags()
        } catch {
            throw CullingError.needsConnection
        }
        for tag in server.sorted(by: { $0.id < $1.id }) {
            guard let meaning = CullingTags.meaning(of: tag.name), missing.contains(meaning), result[meaning] == nil else { continue }
            result[meaning] = tag
            try? store.remember(tag)
        }
        var refused: [String] = []
        for meaning in missing where result[meaning] == nil {
            guard let name = CullingTags.name(of: meaning) else { continue }
            do {
                let tag = try await services.api.createTag(name)
                result[meaning] = tag
                try? store.remember(tag)
            } catch let error as NetworkError {
                switch error {
                case .forbidden, .http(status: 400, _): refused.append(name)
                case .offline, .timedOut: throw CullingError.needsConnection
                default: throw error
                }
            }
        }
        if !refused.isEmpty { throw CullingError.cannotCreateTags(names: refused) }
        return result
    }

    /// The rejected photos and videos of the library (archived ones and `.nomedia` folders left out), for "Delete
    /// Rejected…".
    public func rejectedItems() -> [MediaItem] {
        guard let services else { return [] }
        return (try? CullingStore(database: services.database).items(matching: .rejected, excludedFolders: excludedFolders)) ?? []
    }
}
