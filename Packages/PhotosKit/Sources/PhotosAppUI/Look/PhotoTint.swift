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

/// The viewer's backdrop.
enum ViewerBackdropStyle: String, CaseIterable, Identifiable {
    /// Black, as before.
    case black
    /// Black with a deep shade of the photo's colour.
    case tinted
    /// A soft glow of the photo's colours around it.
    case ambient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: String(localized: "Black", bundle: .module, comment: "Viewer background setting: plain black.")
        case .tinted:
            String(localized: "Photo Color", bundle: .module, comment: "Viewer background setting: black tinted with the photo's colour.")
        case .ambient:
            String(localized: "Ambient Glow", bundle: .module, comment: "Viewer background setting: a soft glow of the photo's colours.")
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
}

/// The viewer's backdrop: black, or toned with the colour of the photo shown, blended between two photos while paging.
struct ViewerBackdrop: View {
    let tint: ViewerTint
    @Environment(SessionModel.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LookSettings.backdropKey) private var style: ViewerBackdropStyle = .tinted

    var body: some View {
        ZStack {
            Color.black
            if style != .black, PhotoTintLookup.allowed(contrast: contrast), let blend = tint.blend {
                if style == .ambient, !reduceTransparency {
                    ambient(blend)
                } else {
                    tone(blend).color
                }
            }
        }
        // A jump (a step with Reduce Motion, a page taken out) fades; paging follows the finger by itself.
        .animation(.easeInOut(duration: 0.4), value: tint.current)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The backdrop colour between the two pages.
    func tone(_ blend: (from: FileID, to: FileID, amount: Double)) -> PaletteColor {
        let services = session.services
        let from = tint.color(of: blend.from, services: services).map(PhotoTintRole.backdrop.tone) ?? .black
        let to = tint.color(of: blend.to, services: services).map(PhotoTintRole.backdrop.tone) ?? .black
        return from.mixed(with: to, amount: blend.amount)
    }

    /// The photo's colours, toned dark, scaled up and blurred into a glow; two photos cross-fade while paging.
    func ambient(_ blend: (from: FileID, to: FileID, amount: Double)) -> some View {
        let services = session.services
        let from = tint.ambientImage(of: blend.from, services: services)
        let to = blend.to == blend.from ? nil : tint.ambientImage(of: blend.to, services: services)
        return ZStack {
            // Without a BlurHash the glow falls back to the plain tone.
            tone(blend).color
            glow(from).opacity(1 - blend.amount)
            glow(to).opacity(blend.amount)
        }
    }

    @ViewBuilder func glow(_ image: CGImage?) -> some View {
        if let image {
            // Filling the backdrop's own size, not the picture's.
            Color.clear
                .overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
                .clipped()
                .blur(radius: 48, opaque: true)
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
            if let color {
                content
                    .toolbarBackground(color.color.opacity(opaque ? 1 : 0.92), for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                    // A large title is drawn under the bar's background, where the wash would hide it.
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
