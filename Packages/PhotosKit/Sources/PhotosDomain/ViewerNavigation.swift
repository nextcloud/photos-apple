// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Keyboard and paging rules of the media viewer (SPEC §7.2), kept free of UI types so they can be tested.
public enum ViewerNavigation {
    public enum Key: Sendable, Hashable {
        case leftArrow, rightArrow, escape, space
    }

    public enum Command: Sendable, Hashable {
        case previous, next, close, togglePlayback
    }

    /// What a key does in the viewer.
    ///
    /// Arrows follow the layout direction (the pager is mirrored in right-to-left languages). Space closes the
    /// viewer like Quick Look, except on a video, where it plays or pauses.
    public static func command(for key: Key, isVideo: Bool, rightToLeft: Bool = false) -> Command {
        switch key {
        case .leftArrow: rightToLeft ? .next : .previous
        case .rightArrow: rightToLeft ? .previous : .next
        case .escape: .close
        case .space: isVideo ? .togglePlayback : .close
        }
    }

    /// The item `delta` pages away from `current`, or `nil` at either end (no wrap-around).
    public static func target<ID: Hashable>(in ids: [ID], from current: ID?, delta: Int) -> ID? {
        guard let current, let index = ids.firstIndex(of: current) else { return nil }
        let next = index + delta
        return ids.indices.contains(next) ? ids[next] : nil
    }

    public static func canStep<ID: Hashable>(in ids: [ID], from current: ID?, delta: Int) -> Bool {
        target(in: ids, from: current, delta: delta) != nil
    }

    /// The item to show after `id` was deleted: the following one, else the preceding one.
    public static func neighbour<ID: Hashable>(in ids: [ID], of id: ID) -> ID? {
        target(in: ids, from: id, delta: 1) ?? target(in: ids, from: id, delta: -1)
    }
}
