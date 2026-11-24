// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The slideshow of any grid or of the viewer's photos (SPEC VW-5): its settings and the order it plays in, kept free of
/// UI types so they can be tested. Stepping and the cross-fade are those of the memories' slideshow (`Slideshow`).
public enum SlideshowPlan {
    /// The intervals offered in the slideshow's options, in seconds.
    public static let intervals: [Int] = [2, 3, 5, 10, 20]
    /// Apple Photos shows a photo about this long.
    public static let defaultInterval = 3

    /// A stored interval as one of `intervals`: the nearest one (a stored value can come from an older version).
    public static func interval(seconds: Int) -> Int {
        intervals.min { abs($0 - seconds) < abs($1 - seconds) } ?? defaultInterval
    }

    /// The photos in the order they are shown: the context's order, from `start` on. Without `start` (or when it is not
    /// part of the context) from the first. The ones before `start` follow at the end, so a repeating slideshow shows
    /// the whole context.
    public static func order<ID: Hashable>(_ ids: [ID], from start: ID?) -> [ID] {
        guard let start, let index = ids.firstIndex(of: start), index > 0 else { return ids }
        return Array(ids[index...] + ids[..<index])
    }

    /// The photo after `index`; after the last one, the first again when the slideshow repeats, else nil (it stops).
    public static func next(after index: Int, count: Int, repeats: Bool) -> Int? {
        guard count > 0 else { return nil }
        if index + 1 < count { return index + 1 }
        return repeats ? 0 : nil
    }

    /// How long the slow zoom of a photo lasts: a little longer than it is shown, so it never stops before the cross-fade.
    public static func driftDuration(interval: Int) -> Double {
        Double(interval) + 1.5
    }
}
