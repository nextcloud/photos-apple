// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How photos take turns in a photo frame or on the desktop (SPEC §15.4).
///
/// The order is fixed for a source: in order, or shuffled with a seed that comes from the source. Every photo comes once
/// before any comes again, and the widget's timeline, computed afresh each time, continues where the last one ended.
public enum AmbientRotation {
    /// A seed from a text (FNV-1a): the same for the same text in every process (`Hasher` is not).
    public static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    /// The indices `0..<count` in an order that only depends on `seed` (Fisher–Yates with SplitMix64).
    public static func shuffledOrder(count: Int, seed: UInt64) -> [Int] {
        var order = Array(0..<max(count, 0))
        guard count > 1 else { return order }
        var generator = SplitMix64(state: seed)
        for index in stride(from: count - 1, to: 0, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            order.swapAt(index, other)
        }
        return order
    }

    /// The number of the time slot `date` is in: slots are `interval` long and counted from 1970.
    public static func slot(at date: Date, interval: TimeInterval) -> Int {
        guard interval > 0 else { return 0 }
        return Int((date.timeIntervalSince1970 / interval).rounded(.down))
    }

    /// When a slot starts.
    public static func start(ofSlot slot: Int, interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: Double(slot) * interval)
    }

    /// The photo (an index into the source's list) for a slot.
    public static func index(slot: Int, count: Int, shuffledWith seed: UInt64?) -> Int? {
        guard count > 0 else { return nil }
        let position = ((slot % count) + count) % count
        guard let seed else { return position }
        return shuffledOrder(count: count, seed: seed)[position]
    }

    /// The entries of a widget's timeline: the slot `now` is in and the ones after it, `count` in all, each with the photo
    /// it shows. The first entry starts now (not at the start of its slot) so the widget shows it at once.
    public static func timeline(
        now: Date, interval: TimeInterval, count: Int, itemCount: Int, seed: UInt64?
    ) -> [(date: Date, index: Int)] {
        guard itemCount > 0, count > 0, interval > 0 else { return [] }
        let first = slot(at: now, interval: interval)
        let order = seed.map { shuffledOrder(count: itemCount, seed: $0) }
        return (0..<count).map { offset in
            let slotNumber = first + offset
            let position = ((slotNumber % itemCount) + itemCount) % itemCount
            let date = offset == 0 ? now : start(ofSlot: slotNumber, interval: interval)
            return (date, order?[position] ?? position)
        }
    }

    /// The orientation of a photo or a screen.
    public enum Orientation: Sendable, Equatable {
        case landscape, portrait, square

        public init(width: Int?, height: Int?) {
            guard let width, let height, width > 0, height > 0 else {
                self = .square
                return
            }
            let ratio = Double(width) / Double(height)
            self = ratio > 1.1 ? .landscape : ratio < 0.9 ? .portrait : .square
        }

        /// A photo of this orientation fills a screen of `screen` without losing most of it.
        public func fits(_ screen: Orientation) -> Bool {
            self == .square || screen == .square || self == screen
        }
    }

    /// The position (into `order`) of the next photo from `position` on that suits a screen: the first one of the
    /// screen's orientation, or the one at `position` when none in the whole order does. Nil for an empty order.
    public static func next(
        from position: Int, order: [Int], orientations: [Orientation], screen: Orientation
    ) -> Int? {
        guard !order.isEmpty else { return nil }
        let start = ((position % order.count) + order.count) % order.count
        for step in 0..<order.count {
            let candidate = (start + step) % order.count
            let index = order[candidate]
            if index < orientations.count, orientations[index].fits(screen) { return candidate }
        }
        return start
    }
}

/// A small, fast generator whose sequence only depends on its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}
