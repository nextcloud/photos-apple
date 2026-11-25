// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

// MARK: - Living gradients (SPEC §17.6.1) [welcome]
//
// A slowly moving mesh gradient in the Nextcloud blue family behind empty states, the login screen, the backup offer
// and the Year in Review cards. The system draws the mesh on the GPU; the view only moves nine points, at most 30 times
// a second, and not at all with Reduce Motion, while off screen or while the app is not active.

/// Where the nine points of a 3 × 3 mesh are at a moment: the corners stay put, the points on the edges slide along
/// their edge and the centre wanders, so the gradient always fills its rectangle. Every wave is a whole multiple of
/// one cycle, so the drift loops without a seam.
enum LivingMesh {
    static let width = 3
    static let height = 3
    /// One full drift, in seconds: slow enough to feel alive without drawing the eye.
    static let period: Double = 24
    /// How far a point moves from its place, as a fraction of the size.
    static let amplitude: Float = 0.12

    static func points(at time: Double, amplitude: Float = amplitude) -> [SIMD2<Float>] {
        let phase = time / period * 2 * Double.pi
        func wave(_ cycles: Double, _ offset: Double) -> Float {
            Float(sin(phase * cycles + offset)) * amplitude
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(1, 0), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(1, 1.3)), SIMD2(0.5 + wave(2, 0.7), 0.5 + wave(1, 2.1)), SIMD2(1, 0.5 + wave(1, 4.2)),
            SIMD2(0, 1), SIMD2(0.5 + wave(1, 3.1), 1), SIMD2(1, 1),
        ]
    }
}

/// The time a living view has been moving: it stops where it is when paused and goes on from there, so a gradient that
/// pauses (Reduce Motion, off screen, the app in the background) never jumps.
struct LivingClock: Equatable {
    /// Seconds of movement so far while paused.
    private(set) var frozen: Double = 0
    /// While running: the moment movement would have started had it never paused.
    private(set) var anchor: Date?

    var isRunning: Bool { anchor != nil }

    func elapsed(at date: Date) -> Double {
        guard let anchor else { return frozen }
        return max(0, date.timeIntervalSince(anchor))
    }

    mutating func run(at now: Date) {
        guard anchor == nil else { return }
        anchor = now.addingTimeInterval(-frozen)
    }

    mutating func pause(at now: Date) {
        guard anchor != nil else { return }
        frozen = elapsed(at: now)
        anchor = nil
    }
}

/// A colour as plain numbers (sRGB, 0…1), so palettes can be checked for legibility in tests.
struct LivingRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Relative luminance (WCAG 2).
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Contrast ratio with another colour (WCAG 2): 1…21.
    func contrast(with other: LivingRGB) -> Double {
        let (lighter, darker) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static let white = LivingRGB(1, 1, 1)
    static let black = LivingRGB(0, 0, 0)
}

/// The colours of a living gradient: nine, one per mesh point, row by row.
enum LivingPalette: Equatable {
    /// Behind empty states and onboarding: a faint blue wash under the system's own text colours.
    case wash
    /// Behind the login screen and the welcome into the Library: deep Nextcloud blues under white text.
    case hero
    /// Year in Review cards: between a card's two colours, never lighter than the lighter one.
    case blend(Color, Color)

    /// The nine colours for wash and hero, as numbers (also used by the tests).
    static func rgb(_ palette: LivingPalette, dark: Bool, increasedContrast: Bool) -> [LivingRGB] {
        switch palette {
        case .wash:
            if increasedContrast {
                // Nearly the plain background: a hint of the colour, full contrast for the text.
                return dark
                    ? [LivingRGB(0.02, 0.03, 0.05), LivingRGB(0.02, 0.04, 0.07), LivingRGB(0.02, 0.03, 0.05)]
                        + [LivingRGB(0.02, 0.04, 0.07), LivingRGB(0.03, 0.05, 0.09), LivingRGB(0.02, 0.04, 0.07)]
                        + [LivingRGB(0.02, 0.03, 0.05), LivingRGB(0.02, 0.04, 0.07), LivingRGB(0.02, 0.03, 0.05)]
                    : [LivingRGB(0.99, 0.99, 1), LivingRGB(0.97, 0.98, 1), LivingRGB(0.99, 0.99, 1)]
                        + [LivingRGB(0.97, 0.98, 1), LivingRGB(0.96, 0.98, 1), LivingRGB(0.97, 0.98, 1)]
                        + [LivingRGB(0.99, 0.99, 1), LivingRGB(0.97, 0.98, 1), LivingRGB(0.99, 0.99, 1)]
            }
            return dark
                ? [LivingRGB(0.03, 0.07, 0.12), LivingRGB(0.02, 0.10, 0.18), LivingRGB(0.04, 0.06, 0.11)]
                    + [LivingRGB(0.01, 0.12, 0.22), LivingRGB(0.00, 0.16, 0.28), LivingRGB(0.03, 0.09, 0.17)]
                    + [LivingRGB(0.03, 0.06, 0.10), LivingRGB(0.02, 0.11, 0.20), LivingRGB(0.04, 0.07, 0.12)]
                : [LivingRGB(0.95, 0.97, 0.99), LivingRGB(0.90, 0.95, 0.99), LivingRGB(0.97, 0.98, 1)]
                    + [LivingRGB(0.92, 0.96, 0.99), LivingRGB(0.86, 0.93, 0.98), LivingRGB(0.94, 0.97, 1)]
                    + [LivingRGB(0.97, 0.98, 1), LivingRGB(0.91, 0.95, 0.99), LivingRGB(0.95, 0.97, 0.99)]
        case .hero:
            // The same in light and dark mode (the login screen is always dark); darker still with Increase Contrast.
            let colors = [
                LivingRGB(0.00, 0.16, 0.31), LivingRGB(0.00, 0.27, 0.48), LivingRGB(0.02, 0.20, 0.42),
                LivingRGB(0.00, 0.33, 0.58), LivingRGB(0.00, 0.40, 0.66), LivingRGB(0.05, 0.24, 0.50),
                LivingRGB(0.01, 0.19, 0.38), LivingRGB(0.00, 0.30, 0.55), LivingRGB(0.00, 0.14, 0.28),
            ]
            guard increasedContrast else { return colors }
            return colors.map { LivingRGB($0.red * 0.6, $0.green * 0.6, $0.blue * 0.6) }
        case .blend:
            return []
        }
    }

    /// How far each mesh point is from the first colour to the second in `blend`: diagonal like the flat gradient it
    /// replaces, with the middle row turned a little so the drift shows.
    static let blendFractions: [Double] = [0, 0.3, 0.55, 0.35, 0.5, 0.8, 0.5, 0.7, 1]

    func colors(dark: Bool, increasedContrast: Bool) -> [Color] {
        switch self {
        case .wash, .hero:
            return Self.rgb(self, dark: dark, increasedContrast: increasedContrast).map(\.color)
        case .blend(let first, let second):
            // Mixed in a perceptual space: every colour lies between the two, so text keeps its contrast.
            return Self.blendFractions.map { first.mix(with: second, by: $0, in: .perceptual) }
        }
    }
}

/// A slowly moving mesh gradient (SPEC §17.6.1). Still with Reduce Motion, while `isActive` is false (a Year in Review
/// card that is not the current one, a card rendered as a picture), while off screen and while the app is inactive.
/// Decorative: hidden from VoiceOver and taps go through.
struct LivingGradient: View {
    var palette: LivingPalette = .wash
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var clock = LivingClock()

    var moves: Bool {
        LivingMotion.moves(isActive: isActive, isOnScreen: isOnScreen, reduceMotion: reduceMotion, scenePhase: scenePhase)
    }

    var body: some View {
        let colors = palette.colors(dark: colorScheme == .dark, increasedContrast: contrast == .increased)
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: LivingMotion.frameInterval, paused: !moves)) {
                    (context: TimelineViewDefaultContext) in
                    mesh(colors, at: clock.elapsed(at: context.date))
                }
            } else {
                // No timeline at all: also what a picture of the view (ImageRenderer) gets.
                mesh(colors, at: clock.elapsed(at: .now))
            }
        }
        .livingClock($clock, moves: moves, isOnScreen: $isOnScreen)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

extension LivingGradient {
    func mesh(_ colors: [Color], at time: Double) -> some View {
        Rectangle().fill(
            MeshGradient(width: LivingMesh.width, height: LivingMesh.height, points: LivingMesh.points(at: time), colors: colors))
    }
}

/// When living views move, and how often they are redrawn.
enum LivingMotion {
    /// 30 frames a second: the movement is a fraction of a point per frame, so more would only cost energy.
    static let frameInterval: Double = 1.0 / 30

    static func moves(isActive: Bool, isOnScreen: Bool, reduceMotion: Bool, scenePhase: ScenePhase) -> Bool {
        isActive && isOnScreen && !reduceMotion && scenePhase == .active
    }
}

extension View {
    /// Runs and pauses a living view's clock with `moves`, and tracks whether the view is on screen.
    func livingClock(_ clock: Binding<LivingClock>, moves: Bool, isOnScreen: Binding<Bool>) -> some View {
        onAppear { isOnScreen.wrappedValue = true }
            .onDisappear { isOnScreen.wrappedValue = false }
            .onChange(of: moves, initial: true) { _, moving in
                if moving { clock.wrappedValue.run(at: .now) } else { clock.wrappedValue.pause(at: .now) }
            }
    }

    /// An empty state on a living wash (SPEC §17.6.1): the state fills the space and the wash goes under the bars.
    func livingEmptyBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LivingGradient(palette: .wash).ignoresSafeArea() }
    }
}
