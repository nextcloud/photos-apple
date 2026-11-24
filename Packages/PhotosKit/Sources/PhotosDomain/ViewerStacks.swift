// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Stacked copies of a photo in the viewer (SPEC VW-6): the tile's copy is a page, the other copies become pages
/// right after it once the stack is opened.
public enum ViewerStacks {
    /// The pages for `ids`: each opened stack's other copies follow its tile.
    /// - Parameter stacks: the copies of each stack by the id of its tile, the tile's own id first.
    public static func pages<ID: Hashable>(_ ids: [ID], stacks: [ID: [ID]], expanded: Set<ID>) -> [ID] {
        guard !expanded.isEmpty else { return ids }
        var result: [ID] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            result.append(id)
            if expanded.contains(id), let copies = stacks[id] { result.append(contentsOf: copies.filter { $0 != id }) }
        }
        return result
    }

    /// The tile of the stack `id` belongs to (`id` itself for the tile), nil when it is in no stack.
    public static func tile<ID: Hashable>(of id: ID, in stacks: [ID: [ID]]) -> ID? {
        if stacks[id] != nil { return id }
        return stacks.first { $0.value.contains(id) }?.key
    }
}

/// The app's folder browser opened at a folder (SPEC VW-3 "Show in folder").
public enum FolderTrail {
    /// The folders from the top down to `path`, one screen each, so Back walks up the tree:
    /// `/Photos/2026/Trip` → `/Photos`, `/Photos/2026`, `/Photos/2026/Trip`. The root has none (it is the browser itself).
    public static func folders(to path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            result.append(current)
        }
        return result
    }
}
