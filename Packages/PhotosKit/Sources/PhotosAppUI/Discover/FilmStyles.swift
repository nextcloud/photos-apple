// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosMedia
import SwiftUI

/// The music of a memory film (SPEC §16.6).
enum FilmSoundtrack: String, Codable, Hashable, Sendable {
    /// The style's own score, made on the device.
    case style
    /// The music the user chose for memories (Settings), when there is one: the style changes only the pacing.
    case mine
    /// Silence (the videos keep their own sound).
    case none
}

/// How a memory's film is told, remembered per memory on this device (SPEC §16.6).
struct FilmChoice: Codable, Hashable, Sendable {
    var style: FilmStyle = .standard
    var soundtrack: FilmSoundtrack

    /// Without a choice: the user's music when they chose one (as in round 5), else the style's score.
    static func standard(hasOwnMusic: Bool) -> FilmChoice {
        FilmChoice(style: .standard, soundtrack: hasOwnMusic ? .mine : .style)
    }
}

/// The choices of style and music per memory. A memory's id is stable (its kind and dates), so the choice comes back
/// when the memory is played again; the oldest choices are let go after a few hundred.
@MainActor enum FilmChoiceStore {
    static let key = "memoryFilmChoices"
    static let limit = 300

    private struct Entry: Codable {
        var choice: FilmChoice
        var used: Date
    }

    static func choice(for memory: String, defaults: UserDefaults = .standard) -> FilmChoice {
        let hasOwnMusic = SlideshowMusicStore.current(defaults: defaults) != nil
        guard let entry = entries(defaults)[memory] else { return .standard(hasOwnMusic: hasOwnMusic) }
        var choice = entry.choice
        // The user's music was removed in Settings since: the style's score instead.
        if choice.soundtrack == .mine && !hasOwnMusic { choice.soundtrack = .style }
        return choice
    }

    static func save(_ choice: FilmChoice, for memory: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        var all = entries(defaults)
        all[memory] = Entry(choice: choice, used: now)
        if all.count > limit {
            for (key, _) in all.sorted(by: { $0.value.used < $1.value.used }).prefix(all.count - limit) { all[key] = nil }
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    private static func entries(_ defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}

extension FilmStyle {
    var title: String {
        switch self {
        case .cinematic: String(localized: "Cinematic", bundle: .module, comment: "Memory film style: the default, calm camera moves.")
        case .upbeat: String(localized: "Upbeat", bundle: .module, comment: "Memory film style: quick cuts, lively music.")
        case .blackAndWhite:
            String(localized: "Black & White", bundle: .module, comment: "Memory film style: monochrome pictures, slow dissolves.")
        case .superEight:
            String(localized: "Super 8", bundle: .module, comment: "Memory film style: looks like an old home movie (grain, warm colours).")
        case .calm: String(localized: "Calm", bundle: .module, comment: "Memory film style: long dissolves, slow pace, soft music.")
        }
    }

    var systemImage: String {
        switch self {
        case .cinematic: "film"
        case .upbeat: "bolt.fill"
        case .blackAndWhite: "circle.lefthalf.filled"
        case .superEight: "film.stack"
        case .calm: "leaf"
        }
    }

    /// The style's score as music the player can play.
    var scoreMusic: SlideshowMusic {
        .score(
            score,
            title: String(
                localized: "\(title) music", bundle: .module,
                comment: "Memory film: the music made for a film style, e.g. 'Upbeat music'. The argument is the style's name."))
    }
}

/// The style and music menu of the film player (and its label).
struct FilmStyleMenu: View {
    let choice: FilmChoice
    /// The user's own music, when they chose some in Settings.
    let ownMusic: SlideshowMusic?
    /// Watching together: the user's own music is not shared, so it is not offered.
    var shared = false
    let change: (FilmChoice) -> Void

    static var title: String {
        String(localized: "Style", bundle: .module, comment: "Memory film: menu of film styles (Cinematic, Upbeat, …) and music.")
    }

    var body: some View {
        Menu {
            Picker(
                selection: Binding(
                    get: { choice.style }, set: { (style: FilmStyle) in change(FilmChoice(style: style, soundtrack: choice.soundtrack)) })
            ) {
                ForEach(FilmStyle.allCases, id: \.self) { (style: FilmStyle) in
                    Label(style.title, systemImage: style.systemImage).tag(style)
                }
            } label: {
                Text("Style", bundle: .module, comment: "Memory film: section of the film styles.")
            }
            .pickerStyle(.inline)
            Picker(
                selection: Binding(
                    get: { choice.soundtrack },
                    set: { (track: FilmSoundtrack) in change(FilmChoice(style: choice.style, soundtrack: track)) })
            ) {
                Text(choice.style.scoreMusic.title).tag(FilmSoundtrack.style)
                if let ownMusic, !shared {
                    Text(ownMusic.title).tag(FilmSoundtrack.mine)
                }
                Text("No Music", bundle: .module, comment: "Memory film: plays without music.").tag(FilmSoundtrack.none)
            } label: {
                Text("Music", bundle: .module, comment: "Memory film: section of the music choices.")
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.title, systemImage: "wand.and.stars")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(Self.title)
        .accessibilityValue(choice.style.title)
    }
}

/// The parts of a style's look that change from frame to frame, drawn over the film in the player: the vignette, the
/// grain and the flicker (`FilmLook`); the export draws the same with Core Image (`FilmLookFilter`).
struct FilmLookOverlay: View {
    let look: FilmLook
    let time: Double
    let size: CGSize
    let grain: CGImage?

    var body: some View {
        ZStack {
            if look.vignette > 0 {
                let radii = look.vignetteRadii(width: size.width, height: size.height)
                RadialGradient(
                    colors: [.clear, .black.opacity(look.vignetteOpacity)], center: .center, startRadius: radii.inner,
                    endRadius: radii.outer)
            }
            if let grain {
                let offset = look.grainOffset(at: time)
                // As coarse as in the video: a grain is 1/540 of the frame's height (2 pixels at 1080p).
                let point = FilmLook.grainSize(frameHeight: size.height)
                let tile = Double(grain.width) * point
                Image(decorative: grain, scale: 1 / point)
                    .interpolation(.none)
                    .resizable(resizingMode: .tile)
                    .frame(width: size.width + tile, height: size.height + tile)
                    .offset(x: -offset.x * tile, y: -offset.y * tile)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipped()
                    .blendMode(.softLight)
            }
            let light = look.light(at: time)
            if light < 1 { Color.black.opacity(1 - light) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
