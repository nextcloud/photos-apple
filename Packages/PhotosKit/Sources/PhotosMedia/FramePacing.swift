// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Frame pacing of an animation measured frame by frame with a display link (SPEC §10 "no hitches", §20.6).
///
/// A frame that comes more than half a refresh interval late is a hitch; its hitch time is how much later than one
/// interval it came. The hitch time ratio (milliseconds of hitches per second) is what Instruments and XCTest's scroll
/// metrics report; Apple calls under 5 ms/s good and over 10 ms/s critical, SPEC §10 asks for under 1 ms/s. Measured on
/// the main thread, this sees the app's own late commits, not frames the render server drops on its own.
public struct FramePacing: Sendable, Codable, Equatable {
    public private(set) var frames = 0
    public private(set) var seconds: Double = 0
    public private(set) var hitches = 0
    public private(set) var hitchMilliseconds: Double = 0
    public private(set) var longestFrameMilliseconds: Double = 0
    /// The refresh interval the display link asked for, in milliseconds (8.3 at 120 Hz, 16.7 at 60 Hz).
    public private(set) var nominalMilliseconds: Double = 0

    public init() {}

    /// One frame came `interval` seconds after the one before; the display asked for one every `nominal` seconds.
    public mutating func frame(interval: Double, nominal: Double) {
        guard interval > 0, nominal > 0 else { return }
        frames += 1
        seconds += interval
        nominalMilliseconds = nominal * 1000
        longestFrameMilliseconds = max(longestFrameMilliseconds, interval * 1000)
        if interval > nominal * 1.5 {
            hitches += 1
            hitchMilliseconds += (interval - nominal) * 1000
        }
    }

    /// Milliseconds of hitches per second of animation.
    public var hitchTimeRatio: Double {
        seconds > 0 ? hitchMilliseconds / seconds : 0
    }

    /// Frames per second actually shown.
    public var framesPerSecond: Double {
        seconds > 0 ? Double(frames) / seconds : 0
    }
}
