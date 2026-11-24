// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Timing and stepping of a memory's slideshow (SPEC ME-4, VW-5), kept free of UI types so it can be tested.
public enum Slideshow {
    /// How long a photo is shown.
    public static let interval: Duration = .seconds(4)
    /// The cross-fade between two photos; shorter with Reduce Motion (a dissolve, no movement).
    public static func crossfade(reduceMotion: Bool) -> Double { reduceMotion ? 0.4 : 1.2 }
    /// How much a photo slowly grows while it is shown (Ken Burns); none with Reduce Motion.
    public static func drift(reduceMotion: Bool) -> Double { reduceMotion ? 1 : 1.08 }

    /// The photo after `index`: the slideshow starts over after the last one.
    public static func next(after index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index + 1) % count
    }

    /// The photo before `index`: the last one before the first.
    public static func previous(before index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index - 1 + count) % count
    }

    /// Whether the slideshow plays by itself when it opens. Not with VoiceOver: photos that change on their own would
    /// pull the description away while it is read; the user steps through them instead.
    public static func startsPlaying(voiceOver: Bool) -> Bool { !voiceOver }
}
