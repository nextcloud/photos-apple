// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import Synchronization

/// Decoded previews in memory: least recently used out first, within a byte budget (SPEC §18.2).
///
/// Replaces `NSCache`, which empties itself whenever the system asks for memory and cannot be told what to keep. Under
/// memory pressure this cache gives back what `MemoryPressurePolicy` says: large decodes first, never the tiles on screen
/// or the viewer's photo.
///
/// Thread-safe; every operation is O(1) except `relieve`, which walks the entries once.
final class MemoryImageCache: Sendable {
    /// One decoded preview, in a doubly linked list from the most to the least recently used.
    private final class Node {
        let key: String
        let box: ImageBox
        let fileId: FileID
        let cost: Int
        var newer: Node?
        var older: Node?

        init(key: String, box: ImageBox, fileId: FileID, cost: Int) {
            self.key = key
            self.box = box
            self.fileId = fileId
            self.cost = cost
        }
    }

    private struct State {
        var nodes: [String: Node] = [:]
        var newest: Node?
        var oldest: Node?
        var cost = 0
        var limit: Int
        /// Photos whose tile-size decodes survive memory pressure: covers, key photos, memory covers.
        var protected: Set<FileID> = []
        var focus = MemoryPressurePolicy.Focus()

        mutating func unlink(_ node: Node) {
            if let newer = node.newer { newer.older = node.older } else { newest = node.older }
            if let older = node.older { older.newer = node.newer } else { oldest = node.newer }
            node.newer = nil
            node.older = nil
        }

        mutating func pushNewest(_ node: Node) {
            node.older = newest
            newest?.newer = node
            newest = node
            if oldest == nil { oldest = node }
        }

        mutating func remove(_ node: Node) {
            unlink(node)
            nodes[node.key] = nil
            cost -= node.cost
        }

        /// Least recently used out until the cost is within the limit.
        mutating func evictToLimit() {
            while cost > limit, let oldest { remove(oldest) }
        }
    }

    // The nodes are only reached with the lock held; the boxes they hand out are Sendable.
    private let state: Mutex<State>

    init(limit: Int) {
        state = Mutex(State(limit: max(0, limit)))
    }

    var limit: Int {
        get { state.withLock { $0.limit } }
        set {
            state.withLock {
                $0.limit = max(0, newValue)
                $0.evictToLimit()
            }
        }
    }

    var totalCost: Int { state.withLock { $0.cost } }
    var count: Int { state.withLock { $0.nodes.count } }

    /// The entry, now the most recently used.
    func object(forKey key: String) -> ImageBox? {
        state.withLock { state in
            guard let node = state.nodes[key] else { return nil }
            if state.newest !== node {
                state.unlink(node)
                state.pushNewest(node)
            }
            return node.box
        }
    }

    /// The entry, without changing the order.
    func peek(_ key: String) -> ImageBox? { state.withLock { $0.nodes[key]?.box } }

    func setObject(_ box: ImageBox, forKey key: String, cost: Int) {
        let fileId = Self.fileId(ofKey: key)
        state.withLock { state in
            if let existing = state.nodes[key] { state.remove(existing) }
            let node = Node(key: key, box: box, fileId: fileId, cost: max(0, cost))
            state.nodes[key] = node
            state.pushNewest(node)
            state.cost += node.cost
            state.evictToLimit()
        }
    }

    func removeAll() {
        state.withLock { state in
            // Unlinked one by one: a long chain of nodes released at once would recurse deeply in `deinit`.
            while let oldest = state.oldest { state.remove(oldest) }
        }
    }

    func setProtected(_ fileIds: Set<FileID>) { state.withLock { $0.protected = fileIds } }

    func setFocus(_ focus: MemoryPressurePolicy.Focus) { state.withLock { $0.focus = focus } }

    var focus: MemoryPressurePolicy.Focus { state.withLock { $0.focus } }

    /// Gives memory back as `MemoryPressurePolicy` says. Returns the bytes freed.
    @discardableResult
    func relieve(_ level: MemoryPressurePolicy.Level) -> Int {
        state.withLock { state in
            var nodes: [Node] = []
            nodes.reserveCapacity(state.nodes.count)
            var node = state.newest
            while let current = node {
                nodes.append(current)
                node = current.older
            }
            let entries = nodes.map {
                MemoryPressurePolicy.Entry(fileId: $0.fileId, decodedSize: $0.box.maxPixelSize, cost: $0.cost)
            }
            let keep = MemoryPressurePolicy.survivors(
                entries, level: level, limit: state.limit, protected: state.protected, focus: state.focus)
            let before = state.cost
            for (node, kept) in zip(nodes, keep) where !kept { state.remove(node) }
            return before - state.cost
        }
    }

    /// The file id at the start of a cache key (`<fileId>-<etag>-<bucket>`).
    static func fileId(ofKey key: String) -> FileID {
        FileID(key.prefix(while: { $0 != "-" })) ?? 0
    }
}
