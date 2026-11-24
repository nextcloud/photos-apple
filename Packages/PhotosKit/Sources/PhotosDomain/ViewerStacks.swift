// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Stacked copies of a photo in the viewer (SPEC VW-6): a stack is one page, and a strip of its copies chooses the copy
/// the page shows. Copies that are deleted or archived while the viewer is open leave the strip; the page goes only
/// with its last copy.
public enum ViewerStacks {
    /// The copies of the page `page` that are still there, in the strip's order (the tile's own first). A photo that is
    /// in no stack is a stack of one.
    /// - Parameter stacks: the copies of each stack by the id of its tile, the tile's own id first.
    public static func copies<ID: Hashable>(of page: ID, stacks: [ID: [ID]], removed: Set<ID> = []) -> [ID] {
        let copies: [ID] = stacks[page] ?? [page]
        return removed.isEmpty ? copies : copies.filter { !removed.contains($0) }
    }

    /// The copy the page `page` shows: the one chosen in the strip while it is there, else the first copy left.
    public static func shown<ID: Hashable>(page: ID, stacks: [ID: [ID]], chosen: [ID: ID], removed: Set<ID> = []) -> ID? {
        let left: [ID] = copies(of: page, stacks: stacks, removed: removed)
        if let pick = chosen[page], left.contains(pick) { return pick }
        return left.first
    }

    /// The pages left of `ids`: a stack stays while one of its copies does.
    public static func pages<ID: Hashable>(_ ids: [ID], stacks: [ID: [ID]], removed: Set<ID>) -> [ID] {
        guard !removed.isEmpty else { return ids }
        return ids.filter { !copies(of: $0, stacks: stacks, removed: removed).isEmpty }
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
