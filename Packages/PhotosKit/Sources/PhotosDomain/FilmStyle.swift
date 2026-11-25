// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How a memory film is told (SPEC §16.6): the pacing, the transitions, the camera, the picture's look and the mood of
/// its music. Chosen in the film's player, remembered per memory, applied to the video export too. With the user's own
/// music only the pacing changes (the music is theirs); otherwise each style has a score of its own (`FilmScore`).
public enum FilmStyle: String, CaseIterable, Codable, Hashable, Sendable {
    /// Round 5's film: calm Ken Burns moves, cuts on the beat within a day, dissolves between days.
    case cinematic
    /// Quick cuts on every beat, a livelier camera, punchier colours.
    case upbeat
    /// Monochrome with deep contrast, slow dissolves, a little grain.
    case blackAndWhite
    /// A home movie: warm faded colours, grain, a gate that jitters and light that flickers.
    case superEight
    /// Long dissolves, slow drifting camera, soft colours.
    case calm

    public static let standard = FilmStyle.cinematic

    /// About how long a picture stays on screen (seconds); the beat decides the exact length.
    public var shotSeconds: Double {
        switch self {
        case .cinematic: 3.4
        case .upbeat: 1.8
        case .blackAndWhite: 3.8
        case .superEight: 2.6
        case .calm: 5.2
        }
    }

    /// A favourite stays this many times as long (never longer than `longestFavourite`).
    public var favouriteFactor: Int {
        switch self {
        case .calm: 1
        default: 2
        }
    }

    /// Favourites are never held longer than this.
    public var longestFavourite: Double {
        switch self {
        case .upbeat: 4
        case .calm: 6
        default: 7
        }
    }

    /// The cross-fade of the steady rhythm (no music, or no clear beat), seconds.
    public var steadyCrossfade: Double {
        switch self {
        case .cinematic: 0.8
        case .upbeat: 0.3
        case .blackAndWhite: 1.1
        case .superEight: 0.45
        case .calm: 1.8
        }
    }

    /// With music: within a day or stop the pictures cut on the beat; false: every picture dissolves in.
    public var cutsWithinChapter: Bool { self != .calm }

    /// With music: how many beats the dissolve into a new day (or every picture, see `cutsWithinChapter`) lasts.
    public var musicalDissolveBeats: Double {
        switch self {
        case .cinematic, .blackAndWhite: 1
        case .upbeat, .superEight: 0.5
        case .calm: 2
        }
    }

    /// How far the camera moves in (1: not at all).
    public var zoom: Double {
        switch self {
        case .cinematic: 1.15
        case .upbeat: 1.22
        case .blackAndWhite: 1.12
        case .superEight: 1.1
        case .calm: 1.08
        }
    }

    /// The steady rhythm of this style: four beats a picture.
    public var steadyRhythm: FilmRhythm {
        self == .cinematic ? .steady : FilmRhythm(beat: shotSeconds / 4, phase: 0, isMusical: false)
    }

    /// The picture's look.
    public var look: FilmLook {
        switch self {
        case .cinematic: .none
        case .upbeat: FilmLook(saturation: 1.18, contrast: 1.07, brightness: 0.01, warmth: 0.03)
        case .blackAndWhite:
            FilmLook(saturation: 0, contrast: 1.2, brightness: -0.01, fade: 0.035, vignette: 0.35, grain: 0.14)
        case .superEight:
            FilmLook(
                saturation: 0.82, contrast: 1.06, brightness: 0.02, warmth: 0.14, fade: 0.09, vignette: 0.6, grain: 0.38,
                jitter: 0.0035, flicker: 0.05)
        case .calm: FilmLook(saturation: 0.9, contrast: 0.95, brightness: 0.015, warmth: 0.05, fade: 0.04, vignette: 0.18)
        }
    }

    /// The mood of the style's own score.
    public var score: FilmScore.Mood {
        switch self {
        case .cinematic: .cinematic
        case .upbeat: .upbeat
        case .blackAndWhite: .nostalgic
        case .superEight: .homeMovie
        case .calm: .ambient
        }
    }
}

/// A picture look of a film style (SPEC §16.6), applied in the same way by the player and the video export: colour
/// (saturation, contrast, brightness, warmth, faded blacks), a vignette, and for the home-movie look grain, a jittering
/// gate and flickering light that change with every film frame (18 a second, as Super 8 ran).
public struct FilmLook: Hashable, Sendable {
    /// 1 unchanged, 0 monochrome.
    public var saturation: Double
    /// 1 unchanged.
    public var contrast: Double
    /// Added to every channel (−1…1); 0 unchanged.
    public var brightness: Double
    /// Shifts the colours towards amber (positive) or blue (negative).
    public var warmth: Double
    /// Lifts the blacks: 0 none, 0.1 a faded print.
    public var fade: Double
    /// How dark the corners get (0…1).
    public var vignette: Double
    /// How strong the grain is (0…1).
    public var grain: Double
    /// How far the frame jumps, as a share of the frame's height.
    public var jitter: Double
    /// How much the light varies from frame to frame (0…1).
    public var flicker: Double

    public init(
        saturation: Double = 1, contrast: Double = 1, brightness: Double = 0, warmth: Double = 0, fade: Double = 0,
        vignette: Double = 0, grain: Double = 0, jitter: Double = 0, flicker: Double = 0
    ) {
        self.saturation = saturation
        self.contrast = contrast
        self.brightness = brightness
        self.warmth = warmth
        self.fade = fade
        self.vignette = vignette
        self.grain = grain
        self.jitter = jitter
        self.flicker = flicker
    }

    public static let none = FilmLook()

    /// The pictures' colours are changed.
    public var gradesColour: Bool {
        saturation != 1 || contrast != 1 || brightness != 0 || warmth != 0 || fade != 0
    }

    /// Changes from frame to frame (grain, jitter, flicker).
    public var isAnimated: Bool { grain > 0 || jitter > 0 || flicker > 0 }

    /// The home movie's frame rate: grain, gate and light change this often.
    public static let filmFrameRate = 18.0

    /// The film frame at `time`.
    public static func frame(at time: Double) -> Int { Int((max(0, time) * filmFrameRate).rounded(.down)) }

    /// How far the gate is off at `time`, as a share of the frame's height (x, y); mostly small, now and then a jump.
    public func jitterOffset(at time: Double) -> (x: Double, y: Double) {
        guard jitter > 0 else { return (0, 0) }
        let frame = UInt64(Self.frame(at: time))
        let a = Self.noise(frame &* 2 &+ 1)
        let b = Self.noise(frame &* 2 &+ 2)
        // Every few frames the film jumps a little further, as a worn gate does.
        let jump = Self.noise(frame &* 7 &+ 3) > 0.9 ? 2.5 : 1
        return ((a - 0.5) * jitter * 0.6, (b - 0.5) * jitter * 2 * jump)
    }

    /// How bright the frame is at `time` (1: unchanged).
    public func light(at time: Double) -> Double {
        guard flicker > 0 else { return 1 }
        return 1 - flicker * Self.noise(UInt64(Self.frame(at: time)) &* 3 &+ 11)
    }

    /// Where the grain pattern is placed at `time` (0…1 across and down): it changes with each film frame.
    public func grainOffset(at time: Double) -> (x: Double, y: Double) {
        let frame = UInt64(Self.frame(at: time))
        return (Self.noise(frame &* 5 &+ 17), Self.noise(frame &* 5 &+ 19))
    }

    /// The frame is drawn this much larger, so the jittering gate never shows an edge.
    public var overscan: Double { 1 + jitter * 6 }

    /// A deterministic value in 0..<1 for `seed` (SplitMix64): the same film looks the same in the player and the video.
    static func noise(_ seed: UInt64) -> Double {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }

    /// The colour change as a matrix on linear-ish RGB (rows r, g, b; columns r, g, b, bias), so Core Image and anything
    /// else apply exactly the same numbers: saturation around the luma, contrast around mid grey, brightness, warmth,
    /// then faded blacks.
    public var colourMatrix: [[Double]] {
        // Saturation (Rec. 709 luma).
        let lr = 0.2126
        let lg = 0.7152
        let lb = 0.0722
        let s = saturation
        var m: [[Double]] = [
            [lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0],
            [lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0],
            [lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0],
        ]
        // Contrast around 0.5 and brightness.
        for row in 0..<3 {
            for column in 0..<3 { m[row][column] *= contrast }
            m[row][3] = m[row][3] * contrast + 0.5 * (1 - contrast) + brightness
        }
        // Warmth: more red, a little more green, less blue.
        let gains = [1 + warmth * 0.55, 1 + warmth * 0.12, 1 - warmth * 0.6]
        for row in 0..<3 {
            for column in 0..<4 { m[row][column] *= gains[row] }
        }
        // Faded blacks: out = fade + in × (1 − fade).
        for row in 0..<3 {
            for column in 0..<4 { m[row][column] *= 1 - fade }
            m[row][3] += fade
        }
        return m
    }

    /// Applies `colourMatrix` to one colour (0…1), clamped; for tests and anything drawn without Core Image.
    public func graded(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let m = colourMatrix
        func channel(_ row: Int) -> Double {
            min(1, max(0, m[row][0] * rgb.0 + m[row][1] * rgb.1 + m[row][2] * rgb.2 + m[row][3]))
        }
        return (channel(0), channel(1), channel(2))
    }
}
