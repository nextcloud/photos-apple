// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

// MARK: - First impressions (SPEC §17.6.2, §17.6.3) [welcome]

/// The photo wall behind the login: columns of abstract "photos" (generated gradients that suggest a sunset, the sea, a
/// forest… — no real pictures) drifting slowly up and down, as a calm picture of what the app is for.
enum WelcomeWall {
    /// One generated picture of the wall.
    struct Tile: Equatable {
        /// Index into `scenes`.
        var scene: Int
        /// Height ÷ width.
        var aspect: Double
        /// Shapes the horizon lines of its gradient, so no two tiles of a scene look the same.
        var seed: Double
    }

    /// Sky, middle and ground of each kind of generated picture.
    static let scenes: [[LivingRGB]] = [
        // Sunset
        [LivingRGB(0.99, 0.75, 0.45), LivingRGB(0.96, 0.45, 0.40), LivingRGB(0.35, 0.20, 0.40)],
        // Sea and beach
        [LivingRGB(0.62, 0.85, 0.98), LivingRGB(0.10, 0.55, 0.80), LivingRGB(0.95, 0.88, 0.70)],
        // Forest
        [LivingRGB(0.70, 0.88, 0.80), LivingRGB(0.20, 0.55, 0.35), LivingRGB(0.10, 0.30, 0.20)],
        // Snow
        [LivingRGB(0.75, 0.85, 0.95), LivingRGB(0.95, 0.97, 1.00), LivingRGB(0.80, 0.85, 0.92)],
        // City at night
        [LivingRGB(0.05, 0.08, 0.20), LivingRGB(0.25, 0.20, 0.45), LivingRGB(0.95, 0.70, 0.30)],
        // Meadow
        [LivingRGB(0.55, 0.80, 0.98), LivingRGB(0.95, 0.90, 0.45), LivingRGB(0.35, 0.65, 0.25)],
        // Desert
        [LivingRGB(0.98, 0.85, 0.65), LivingRGB(0.90, 0.55, 0.35), LivingRGB(0.60, 0.30, 0.20)],
        // Dusk
        [LivingRGB(0.45, 0.40, 0.75), LivingRGB(0.80, 0.55, 0.75), LivingRGB(0.30, 0.25, 0.50)],
    ]

    static let aspects: [Double] = [1.0, 1.33, 0.75, 1.25]
    /// Tiles of one column before it repeats.
    static let tilesPerColumn = 8
    static let spacing: Double = 8
    /// Points a second; every column a little different, every other column the other way.
    static let speeds: [Double] = [7, 9.5, 6, 8.5, 10, 7.5]

    /// The tiles of a column, top to bottom. Neighbours never show the same scene.
    static func tiles(column: Int) -> [Tile] {
        (0..<tilesPerColumn).map { (index: Int) in
            Tile(
                scene: (column * 3 + index * 5) % scenes.count, aspect: aspects[(column + index * 3) % aspects.count],
                seed: Double(column * 11 + index * 7))
        }
    }

    /// How many columns cover a wall this wide (the wall is drawn larger than the screen and turned a little).
    static func columns(width: Double) -> Int {
        max(4, Int((width / 130).rounded(.up)))
    }

    /// Height of one round of a column's tiles, after which it repeats.
    static func loopHeight(column: Int, columnWidth: Double) -> Double {
        tiles(column: column).reduce(0) { $0 + columnWidth * $1.aspect + spacing }
    }

    /// How many rounds of a column to draw so that it covers the wall at every shift.
    static func rounds(loop: Double, wallHeight: Double) -> Int {
        guard loop > 0 else { return 1 }
        return Int((wallHeight / loop).rounded(.up)) + 1
    }

    /// Vertical shift of a column after `elapsed` seconds: always within one loop (−loop…0), so the column, drawn
    /// `rounds` times one under the other, fills the wall at every moment and wraps without a jump.
    static func shift(column: Int, elapsed: Double, loop: Double) -> Double {
        guard loop > 0 else { return 0 }
        let travelled = (elapsed * speeds[column % speeds.count]).truncatingRemainder(dividingBy: loop)
        return column.isMultiple(of: 2) ? -travelled : travelled - loop
    }

    /// The nine mesh colours of a tile: its scene's three rows.
    static func colors(_ tile: Tile) -> [Color] {
        let rows = scenes[tile.scene % scenes.count]
        return rows.flatMap { (row: LivingRGB) in [row.color, row.color, row.color] }
    }
}

/// The drifting wall of generated pictures (SPEC §17.6.2). Still with Reduce Motion, off screen and while the app is
/// inactive; decorative.
struct WelcomePhotoWall: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var clock = LivingClock()

    var moves: Bool {
        LivingMotion.moves(isActive: true, isOnScreen: isOnScreen, reduceMotion: reduceMotion, scenePhase: scenePhase)
    }

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            // Larger than the screen and turned, so the turned corners stay covered.
            let width = Double(max(proxy.size.width, proxy.size.height)) * 1.5
            let count = WelcomeWall.columns(width: width)
            let columnWidth = (width - WelcomeWall.spacing * Double(count - 1)) / Double(count)
            TimelineView(.animation(minimumInterval: LivingMotion.frameInterval, paused: !moves)) {
                (context: TimelineViewDefaultContext) in
                let elapsed = clock.elapsed(at: context.date)
                HStack(alignment: .top, spacing: WelcomeWall.spacing) {
                    ForEach(0..<count, id: \.self) { (column: Int) in
                        let loop = WelcomeWall.loopHeight(column: column, columnWidth: columnWidth)
                        WelcomeWallColumn(column: column, width: columnWidth, rounds: WelcomeWall.rounds(loop: loop, wallHeight: width))
                            .offset(y: WelcomeWall.shift(column: column, elapsed: elapsed, loop: loop))
                    }
                }
                .frame(width: width, height: width, alignment: .top)
                .clipped()
            }
            .rotationEffect(.degrees(-10))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .clipped()
        .livingClock($clock, moves: moves, isOnScreen: $isOnScreen)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// One column of the wall, its tiles repeated `rounds` times. The tiles don't change while the wall drifts: only the
/// column's offset does.
struct WelcomeWallColumn: View {
    let column: Int
    let width: Double
    var rounds = 2

    var body: some View {
        let tiles = WelcomeWall.tiles(column: column)
        VStack(spacing: WelcomeWall.spacing) {
            ForEach(0..<(tiles.count * rounds), id: \.self) { (index: Int) in
                let tile = tiles[index % tiles.count]
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        MeshGradient(
                            width: LivingMesh.width, height: LivingMesh.height, points: LivingMesh.points(at: tile.seed, amplitude: 0.2),
                            colors: WelcomeWall.colors(tile))
                    )
                    .frame(width: width, height: width * tile.aspect)
            }
        }
    }
}

/// Behind the login (SPEC §17.6.2): the photo wall under the moving Nextcloud blue, which keeps it calm and the text
/// readable. Only the blue with Reduce Transparency or Increase Contrast.
struct WelcomeBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color.black
            if !reduceTransparency && contrast != .increased {
                WelcomePhotoWall()
            }
            LivingGradient(palette: .hero).opacity(reduceTransparency || contrast == .increased ? 1 : 0.78)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// The card that holds the login form over the backdrop: Liquid Glass on iPhone and iPad, the window's glass on
    /// Vision Pro, a material panel on the Mac; solid with Reduce Transparency and Increase Contrast.
    func welcomeCard() -> some View {
        modifier(WelcomeCard())
    }
}

struct WelcomeCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let cornerRadius: CGFloat = 28
    /// The solid surface when the background must not show through.
    static let solid = Color(red: 0.05, green: 0.09, blue: 0.16)

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(Self.solid, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.6 : 0.2), lineWidth: 1))
        } else {
            #if os(iOS)
                content.glassEffect(.regular.tint(Self.solid.opacity(0.45)), in: shape)
            #elseif os(visionOS)
                content.glassBackgroundEffect(in: shape)
            #else
                content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

// MARK: - The welcome into the Library and the launch (SPEC §17.6.3)

/// The short welcome after the first login: the app icon on the Nextcloud blue grows and fades as the Library comes up
/// behind it. With Reduce Motion it only fades. It never takes input: the Library can be used at once.
struct FirstLaunchWelcome: View {
    var name: String
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: WelcomeTiming.Phase = .shown
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 96.0

    var body: some View {
        let timing = WelcomeTiming(reduceMotion: reduceMotion)
        ZStack {
            LivingGradient(palette: .hero)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                PhotosAppIcon()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .scaleEffect(phase == .leaving ? timing.iconEndScale : 1)
                Text(Self.greeting(name: name))
                    .font(.title.bold())
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .opacity(phase == .leaving ? 0 : 1)
            }
            .padding(32)
        }
        .opacity(phase == .leaving ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            await WelcomeTiming.holdCalmly(WelcomeDebug.hold ?? timing.hold)
            withAnimation(timing.leave) {
                phase = .leaving
            } completion: {
                onFinished()
            }
        }
    }

    static func greeting(name: String) -> String {
        name.isEmpty
            ? String(localized: "Welcome", bundle: .module, comment: "Shown for a moment after the first login, before the Library.")
            : String(
                localized: "Welcome, \(name)", bundle: .module,
                comment: "Shown for a moment after the first login, before the Library. The placeholder is the user's name.")
    }
}

/// How long the welcome and the launch reveal take: short, so they never stand between the user and the Library.
struct WelcomeTiming: Equatable {
    enum Phase: Equatable {
        case shown
        case leaving
    }

    var reduceMotion: Bool

    /// The icon and greeting stay still for this long.
    var hold: Double { reduceMotion ? 0.5 : 0.45 }
    /// Then they leave in this long.
    var leaveDuration: Double { reduceMotion ? 0.35 : 0.6 }
    var leave: Animation { reduceMotion ? .easeInOut(duration: leaveDuration) : .smooth(duration: leaveDuration) }
    /// The icon grows towards the viewer as it leaves; with Reduce Motion it stays its size and only fades.
    var iconEndScale: CGFloat { reduceMotion ? 1 : 6 }
    /// Everything together, also for the UI tests.
    var total: Double { hold + leaveDuration }

    /// How long the welcome has been on screen undisturbed, after one more step of `step` seconds that took `took`: a
    /// step that took much longer means the app was busy (a launch, the first sync) and nothing moved on screen, so the
    /// hold starts again — the greeting is seen for its whole time, not swallowed by a busy moment.
    static func calmTime(after calm: Double, step: Double, took: Double) -> Double {
        took > step * 3 ? 0 : calm + took
    }

    /// Waits until the welcome has been shown undisturbed for `hold` seconds, at most `limit` seconds in all.
    static func holdCalmly(_ hold: Double, limit: Double = 3) async {
        let step = 0.05
        let clock = ContinuousClock()
        let start = clock.now
        var calm = 0.0
        while calm < hold, !Task.isCancelled {
            let before = clock.now
            try? await Task.sleep(for: .seconds(step))
            let elapsed = (clock.now - before).components
            let took = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            calm = calmTime(after: calm, step: step, took: took)
            if clock.now - start > .seconds(limit) { return }
        }
    }

    /// The Library's first appearance on a normal launch: a quick fade that starts with the first frame and delays
    /// nothing.
    var revealDuration: Double { reduceMotion ? 0.2 : 0.35 }
}

/// The gentle first appearance of the app on a normal launch (SPEC §17.6.3): once per process, not on an account switch.
///
/// The content is never animated: a cover in the window's background colour fades away above it, animated on its own.
/// Fading (or scaling) the split view in one animated transaction made the Mac sidebar's rows that were built in it
/// keep their symbols at the opacity of that moment — Library's half drawn, Favorites, Memories, Places and the albums
/// invisible (SPEC §20.1).
struct LaunchReveal: ViewModifier {
    /// Already shown in this process (or replaced by the welcome).
    @MainActor static var done = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = LaunchReveal.done

    func body(content: Content) -> some View {
        let timing = WelcomeTiming(reduceMotion: reduceMotion)
        content
            .overlay {
                Rectangle()
                    .fill(.background)
                    .opacity(revealed ? 0 : 1)
                    // Only the cover's opacity animates; the content's transaction stays without an animation.
                    .animation(.easeOut(duration: timing.revealDuration), value: revealed)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear {
                guard !revealed else { return }
                LaunchReveal.done = true
                revealed = true
            }
    }
}

/// Debug builds: `PHOTOS_DEBUG_WELCOME=login` shows the login screen although an account is logged in (screenshots);
/// `PHOTOS_DEBUG_WELCOME=transition` plays the welcome into the Library at launch, and lets the debug login
/// (`PHOTOS_DEBUG_LOGIN`) play it as a real first login does.
enum WelcomeDebug {
    static var value: String? {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOTOS_DEBUG_WELCOME"]
        #else
            nil
        #endif
    }

    static var showsLogin: Bool { value == "login" }
    /// `PHOTOS_DEBUG_WELCOME_HOLD=<seconds>`: the welcome stays that long before it leaves (UI tests wait for the app to
    /// be idle, which would otherwise be after the welcome).
    static var hold: Double? {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOTOS_DEBUG_WELCOME_HOLD"].flatMap(Double.init)
        #else
            nil
        #endif
    }
    static var playsTransition: Bool { value == "transition" }
}
