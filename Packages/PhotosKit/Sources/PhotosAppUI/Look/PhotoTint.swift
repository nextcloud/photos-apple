// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI

// MARK: - Colour from the photo (SPEC §16.8.1)

/// The look settings (Settings ▸ Appearance). Per device, like the other display settings.
enum LookSettings {
    static let backdropKey = "lookViewerBackdrop"
    static let headerTintKey = "lookHeaderTint"
    static let liveCoversKey = "lookLiveCovers"
}

/// The viewer's backdrop. Each style has a dark and a light version: the stage is dark in Dark Mode and while the
/// viewer's controls are hidden, light otherwise (SPEC §17.1, `ViewerStage.isDark`).
enum ViewerBackdropStyle: String, CaseIterable, Identifiable {
    /// Pure black, or pure white on a light stage (the default; the raw value is kept from when it was always black).
    case black
    /// A deep shade of the photo's colour, or a pale one on a light stage.
    case tinted
    /// A blurred, enlarged copy of the photo, dimmed or brightened for the stage.
    case ambient

    /// What the viewer shows when nothing was chosen.
    static let standard: ViewerBackdropStyle = .black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black:
            String(
                localized: "Black or White", bundle: .module,
                comment: "Viewer background setting: pure black in Dark Mode, pure white in Light Mode.")
        case .tinted:
            String(localized: "Photo Color", bundle: .module, comment: "Viewer background setting: black tinted with the photo's colour.")
        case .ambient:
            String(
                localized: "Ambient Glow", bundle: .module,
                comment: "Viewer background setting: a blurred, enlarged copy of the photo behind it.")
        }
    }
}

extension PaletteColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// Finds the dominant colour of a photo from what is on the device already: its BlurHash, else a preview in memory.
@MainActor
enum PhotoTintLookup {
    static func dominant(_ item: MediaItem, services: AccountServices) -> PaletteColor? {
        if let color = PhotoColors.dominant(blurhash: item.blurhash) { return color }
        guard let image = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: 1024) else { return nil }
        return PhotoColors.dominant(image: image)
    }

    static func dominant(_ fileId: FileID, services: AccountServices) -> PaletteColor? {
        guard let item = try? services.library.item(fileId) else {
            // Not in the index (a cover of a shared album): a preview in memory, if there is one.
            return services.images.cache.bestMemoryImage(fileId: fileId, etag: "", upTo: 1024).flatMap(PhotoColors.dominant(image:))
        }
        return dominant(item, services: services)
    }

    /// Whether colours from photos are drawn at all: not with Increase Contrast, where plain black and white read best.
    nonisolated static func allowed(contrast: ColorSchemeContrast) -> Bool { contrast != .increased }
}

/// The viewer's pages and where the pager is between them, for the backdrop. Kept apart from the viewer's own state, so
/// following the scroll position redraws the backdrop and nothing else.
@MainActor
@Observable
final class ViewerTint {
    /// The photo of each page.
    var pages: [FileID] = [] {
        didSet { if pages != oldValue { indexOfCurrent = current.flatMap { pages.firstIndex(of: $0) } } }
    }
    var current: FileID? {
        didSet { indexOfCurrent = current.flatMap { pages.firstIndex(of: $0) } }
    }
    /// Where the pager is, in pages (2.5: halfway between the third and fourth page), as the scroll view reports it.
    var scrollPosition: Double = 0
    @ObservationIgnored private var indexOfCurrent: Int?
    @ObservationIgnored private var colors: [FileID: PaletteColor?] = [:]
    @ObservationIgnored private var ambient: [FileID: CGImage?] = [:]
    @ObservationIgnored private var copies: [FileID: CGImage] = [:]

    /// The two pages the pager is between and how far it is from the first to the second.
    var blend: (from: FileID, to: FileID, amount: Double)? {
        guard let index = indexOfCurrent, pages.indices.contains(index) else { return nil }
        let position = ViewerTint.position(scroll: scrollPosition, current: index, count: pages.count)
        let lower = max(0, min(pages.count - 1, Int(position.rounded(.down))))
        let upper = min(pages.count - 1, lower + 1)
        return (pages[lower], pages[upper], max(0, min(1, position - Double(lower))))
    }

    /// The scroll position in pages, trusted only near the page shown (a right-to-left layout reports it mirrored; a
    /// position far from the current page is a layout in progress).
    nonisolated static func position(scroll: Double, current: Int, count: Int) -> Double {
        guard scroll.isFinite, count > 0 else { return Double(current) }
        if abs(scroll - Double(current)) < 1.5 { return scroll }
        let mirrored = Double(count - 1) - scroll
        if abs(mirrored - Double(current)) < 1.5 { return mirrored }
        return Double(current)
    }

    func color(of fileId: FileID, services: AccountServices?) -> PaletteColor? {
        if let known = colors[fileId] { return known }
        guard let services else { return nil }
        let color = PhotoTintLookup.dominant(fileId, services: services)
        // A colour from a BlurHash never changes; a missing one may come with the preview, so it is asked again.
        if color != nil { colors[fileId] = color }
        return color
    }

    func ambientImage(of fileId: FileID, services: AccountServices?) -> CGImage? {
        if let known = ambient[fileId] { return known }
        guard let services else { return nil }
        let image = PhotoColors.ambientImage(blurhash: (try? services.library.item(fileId))?.blurhash)
        ambient[fileId] = image
        return image
    }

    /// The picture behind the blurred copy of a photo: a small preview in memory (the grid's tile, usually), else its
    /// BlurHash; nothing is loaded for it. A preview is kept, a BlurHash is asked again (the preview may come).
    func copyImage(of fileId: FileID, services: AccountServices?) -> CGImage? {
        if let known = copies[fileId] { return known }
        guard let services, let item = try? services.library.item(fileId) else { return nil }
        let etag: String = services.images.displayedEtag(fileId: fileId, etag: item.etag)
        if let preview = services.images.cache.bestMemoryImage(fileId: fileId, etag: etag, upTo: 1024) {
            if copies.count > 40 { copies.removeAll() }
            copies[fileId] = preview
            return preview
        }
        return BlurHashCache.image(item.blurhash)
    }
}

/// The backdrop's colour on a light stage: the photo's colour, pale (black text on it keeps ≥ 7:1).
enum ViewerBackdropTone {
    /// The photo's colour toned for the stage: deep on a dark one, pale on a light one.
    static func tone(_ dominant: PaletteColor, dark: Bool) -> PaletteColor {
        dark ? PhotoTintRole.backdrop.tone(dominant) : light(dominant)
    }

    static func light(_ dominant: PaletteColor) -> PaletteColor {
        PhotoTintRole.headerLight.tone(dominant).mixed(with: .white, amount: 0.55)
    }

    /// How much of the stage's own colour lies over the blurred copy of the photo: enough for the glass controls and
    /// for the photo to stand out, little enough to keep its colours.
    static func copyWash(dark: Bool) -> Double { dark ? 0.5 : 0.6 }
}

/// The viewer's backdrop: black or white with the stage, toned with the colour of the photo shown, or a blurred copy of
/// it — blended between two photos while paging. The stage's colour scheme (`colorScheme` in the environment) decides
/// between the dark and the light version (SPEC §16.8.1, §17.1).
struct ViewerBackdrop: View {
    let tint: ViewerTint
    @Environment(SessionModel.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LookSettings.backdropKey) private var style: ViewerBackdropStyle = .standard

    var dark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            dark ? Color.black : Color.white
            if style != .black, PhotoTintLookup.allowed(contrast: contrast), let blend = tint.blend {
                if style == .ambient, !reduceTransparency {
                    ambient(blend)
                } else {
                    tone(blend).color
                }
            }
        }
        // A jump (a step with Reduce Motion, a page taken out) fades; paging follows the finger by itself. The stage
        // turning dark or light (controls hidden or shown) cross-fades too.
        .animation(.easeInOut(duration: 0.4), value: tint.current)
        .animation(.easeInOut(duration: 0.3), value: dark)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The backdrop colour between the two pages.
    func tone(_ blend: (from: FileID, to: FileID, amount: Double)) -> PaletteColor {
        let services = session.services
        let base: PaletteColor = dark ? .black : .white
        let dark: Bool = dark
        let toned: (PaletteColor) -> PaletteColor = { (color: PaletteColor) -> PaletteColor in
            ViewerBackdropTone.tone(color, dark: dark)
        }
        let from: PaletteColor = tint.color(of: blend.from, services: services).map(toned) ?? base
        let to: PaletteColor = tint.color(of: blend.to, services: services).map(toned) ?? base
        return from.mixed(with: to, amount: blend.amount)
    }

    /// The photo itself, enlarged and blurred behind it under a wash of the stage's colour; two photos cross-fade while
    /// paging. Without a preview in memory the BlurHash stands in; without either, the plain tone.
    func ambient(_ blend: (from: FileID, to: FileID, amount: Double)) -> some View {
        let services = session.services
        let from = tint.copyImage(of: blend.from, services: services)
        let to = blend.to == blend.from ? nil : tint.copyImage(of: blend.to, services: services)
        return ZStack {
            tone(blend).color
            copy(from).opacity(1 - blend.amount)
            copy(to).opacity(blend.amount)
            (dark ? Color.black : Color.white).opacity(ViewerBackdropTone.copyWash(dark: dark))
        }
    }

    @ViewBuilder func copy(_ image: CGImage?) -> some View {
        if let image {
            // Filling the backdrop's own size, not the picture's; enlarged, so the blur has no pale edges.
            Color.clear
                .overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .scaleEffect(1.25)
                }
                .clipped()
                .blur(radius: 60, opaque: true)
        }
    }
}

// MARK: Headers

/// Tints the header (navigation bar, window toolbar) of an album or memory with the colour of its cover.
struct PhotoHeaderTint: ViewModifier {
    let fileId: FileID?
    @Environment(SessionModel.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LookSettings.headerTintKey) private var enabled = true
    @State private var dominant: PaletteColor?

    var wash: PaletteColor? {
        guard enabled, PhotoTintLookup.allowed(contrast: contrast), let dominant else { return nil }
        return HeaderWash.color(dominant, dark: colorScheme == .dark)
    }

    func body(content: Content) -> some View {
        content
            .modifier(HeaderBackground(color: wash, opaque: reduceTransparency))
            .task(id: fileId) {
                guard let fileId, let services = session.services else { return }
                dominant = PhotoTintLookup.dominant(fileId, services: services)
                // The cover's preview may arrive a moment later: one more look then.
                if dominant == nil {
                    try? await Task.sleep(for: .seconds(1))
                    dominant = PhotoTintLookup.dominant(fileId, services: services)
                }
            }
    }
}

/// What a header wash is made of.
enum HeaderWash {
    /// The toned colour softened towards the window's background: a hint of colour, and only more contrast for the text
    /// (the background is the opposite of the text colour).
    static func color(_ dominant: PaletteColor, dark: Bool) -> PaletteColor {
        let role: PhotoTintRole = dark ? .headerDark : .headerLight
        return role.tone(dominant).mixed(with: dark ? .black : .white, amount: dark ? 0.15 : 0.45)
    }
}

private struct HeaderBackground: ViewModifier {
    let color: PaletteColor?
    let opaque: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
            if let color, opaque {
                // Reduce Transparency: a solid bar in the cover's colour.
                content
                    .toolbarBackground(color.color, for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                    // A large title is drawn under the bar's background, where the wash would hide it.
                    .navigationBarTitleDisplayMode(.inline)
            } else if let color {
                // Edge to edge (SPEC §17.2): the photos scroll under the bar with the system's soft blur; the cover's
                // colour is a wash over the top edge that fades out below the bar instead of a solid band.
                content
                    .overlay(alignment: .top) {
                        // 36 pt below the bar, and up under it to the top of the screen.
                        Color.clear
                            .frame(height: 36)
                            .background {
                                LinearGradient(
                                    stops: [
                                        .init(color: color.color.opacity(0.85), location: 0),
                                        .init(color: color.color.opacity(0.5), location: 0.65),
                                        .init(color: color.color.opacity(0), location: 1),
                                    ], startPoint: .top, endPoint: .bottom
                                )
                                .ignoresSafeArea(edges: .top)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                content
            }
        #elseif os(macOS)
            if let color {
                content
                    .toolbarBackground(color.color.opacity(opaque ? 1 : 0.92), for: .windowToolbar)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            } else {
                content
            }
        #else
            // Vision Pro: windows are glass; a coloured bar would not belong there.
            content
        #endif
    }
}

extension View {
    /// The header of an album or memory takes a hint of its cover's colour (SPEC §16.8.1).
    func photoHeaderTint(_ fileId: FileID?) -> some View {
        modifier(PhotoHeaderTint(fileId: fileId))
    }
}

/// The colour under the white titles of a memory card: a deep shade of the cover's colour instead of black.
@MainActor
enum MemoryScrimColor {
    /// By cover: the cards are drawn again and again, the index is asked once.
    private static var known: [FileID: PaletteColor] = [:]

    static func color(cover: FileID, services: AccountServices?, contrast: ColorSchemeContrast, reduceTransparency: Bool) -> Color {
        guard UserDefaults.standard.object(forKey: LookSettings.headerTintKey) as? Bool ?? true,
            PhotoTintLookup.allowed(contrast: contrast), !reduceTransparency, let services
        else { return .black }
        if let color = known[cover] { return color.color }
        guard let dominant = PhotoTintLookup.dominant(cover, services: services) else { return .black }
        let toned = PhotoTintRole.scrim.tone(dominant)
        if known.count > 500 { known.removeAll() }
        known[cover] = toned
        return toned.color
    }
}

extension ViewerTint {
    /// The pager's position in pages from its scroll offset.
    nonisolated static func pagePosition(offset: CGFloat, width: CGFloat) -> Double {
        width > 0 ? Double(offset / width) : 0
    }
}

/// Keeps the backdrop's pages and current page in step with the viewer.
struct ViewerTintTracking: ViewModifier {
    let tint: ViewerTint
    let pages: [FileID]
    let current: FileID?

    func body(content: Content) -> some View {
        content
            .onChange(of: pages, initial: true) { _, pages in tint.pages = pages }
            .onChange(of: current, initial: true) { _, current in tint.current = current }
    }
}
