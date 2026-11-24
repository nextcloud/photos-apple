// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The timing of a "Then and now" time-lapse (SPEC §15.6): each year's photo is held, then cross-fades into the next
/// one, with a slow zoom. The player on screen and the exported video both ask it what to show at a time, so they look
/// the same.
public struct TimeLapsePlan: Hashable, Sendable {
    /// What is on screen at one moment: photo `from`, with `to` faded in over it by `mix` (0…1), each zoomed by its scale.
    public struct Moment: Hashable, Sendable {
        public var from: Int
        public var to: Int
        public var mix: Double
        public var fromScale: Double
        public var toScale: Double
        /// The photo whose caption (year) is shown: the one that is more visible.
        public var captioned: Int { mix < 0.5 ? from : to }
    }

    public var count: Int
    /// Seconds a photo is shown alone.
    public var hold: Double
    /// Seconds of the cross-fade into the next one.
    public var fade: Double
    /// How much a photo grows while it is shown (1: no zoom, with Reduce Motion).
    public var zoom: Double
    /// Whether the last photo fades back into the first (the player loops; the video does not).
    public var loops: Bool

    public init(count: Int, hold: Double = 1.6, fade: Double = 0.9, zoom: Double = 1.06, loops: Bool = false) {
        self.count = max(0, count)
        self.hold = max(0, hold)
        self.fade = max(0, fade)
        self.zoom = max(1, zoom)
        self.loops = loops
    }

    /// The plan of the player on screen: a gentle zoom unless Reduce Motion is on, and a dissolve.
    public static func player(count: Int, reduceMotion: Bool) -> TimeLapsePlan {
        TimeLapsePlan(count: count, hold: 1.8, fade: reduceMotion ? 0.5 : 1.0, zoom: reduceMotion ? 1 : 1.06, loops: true)
    }

    /// Seconds of one photo: shown alone, then fading out.
    public var segment: Double { hold + fade }

    /// Length of one pass. Without looping the last photo is held and does not fade out.
    public var duration: Double {
        guard count > 0 else { return 0 }
        return loops ? Double(count) * segment : Double(count - 1) * segment + hold
    }

    /// What is shown `time` seconds after the start (looping plans wrap around; others stop on the last photo).
    public func moment(at time: Double) -> Moment {
        guard count > 0 else { return Moment(from: 0, to: 0, mix: 0, fromScale: 1, toScale: 1) }
        let total = duration
        var time = max(0, time)
        if loops, total > 0 { time = time.truncatingRemainder(dividingBy: total) } else { time = min(time, total) }
        let segment = max(self.segment, 1e-9)
        var index = Int(time / segment)
        if index >= count { index = count - 1 }
        let within = time - Double(index) * segment
        let isLast = index == count - 1
        let next = isLast ? (loops ? 0 : index) : index + 1
        let mix = (isLast && !loops) || fade == 0 ? 0 : min(1, max(0, (within - hold) / fade))
        // Each photo grows over its own time on screen: from when it starts fading in (`fade` before its segment) until
        // it has faded out, so the zoom goes on smoothly through both cross-fades.
        let span = hold + 2 * fade
        let fromProgress = min(1, (within + fade) / max(span, 1e-9))
        let toProgress = min(1, max(0, within - hold) / max(span, 1e-9))
        return Moment(
            from: index, to: next, mix: mix, fromScale: 1 + (zoom - 1) * fromProgress, toScale: 1 + (zoom - 1) * toProgress)
    }

    /// The frame times of a video of the plan at `framesPerSecond`.
    public func frameTimes(framesPerSecond: Int) -> [Double] {
        guard framesPerSecond > 0, duration > 0 else { return count > 0 ? [0] : [] }
        let frames = max(1, Int((duration * Double(framesPerSecond)).rounded(.up)))
        return (0..<frames).map { Double($0) / Double(framesPerSecond) }
    }
}
