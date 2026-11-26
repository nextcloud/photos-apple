// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import SwiftUI

#if canImport(UIKit)
    import UIKit
    public typealias PlatformImage = UIImage
#else
    import AppKit
    public typealias PlatformImage = NSImage
#endif

/// Design tokens (SPEC §6.5).
public enum Design {
    /// Nextcloud blue, legible as text and on tinted buttons (SPEC §20.3): see `AccentPalette`.
    public static let accent = AccentPalette.color

    @MainActor public static var tileSpacing: CGFloat {
        #if os(macOS)
            2
        #elseif os(visionOS)
            4
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        #endif
    }

    public static let coverCornerRadius: CGFloat = 10
}

extension PlatformImage {
    static func from(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
            UIImage(cgImage: cgImage)
        #else
            NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

/// Formatting helpers.
enum Formatters {
    /// "1:05", "1:02:03" in the locale's digits and separators.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let duration = Duration.seconds(total)
        return total >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond)) : duration.formatted(.time(pattern: .minuteSecond))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// The official Nextcloud logo (vector, from nextcloud/server), in the accent colour by default.
public struct NextcloudLogo: View {
    var color: Color = Design.accent

    public init(color: Color = Design.accent) {
        self.color = color
    }

    public var body: some View {
        SVGShape.nextcloudLogo
            .fill(color, style: FillStyle(eoFill: true))
            .aspectRatio(2, contentMode: .fit)
            .accessibilityLabel(Text(verbatim: "Nextcloud"))
    }
}

/// The Nextcloud Photos app icon (the Photos server app's icon, white on Nextcloud blue).
public struct PhotosAppIcon: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Design.accent, Color(red: 28 / 255, green: 175 / 255, blue: 1)], startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                SVGShape.photosIcon
                    .fill(.white)
                    .padding(side * 0.12)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text(verbatim: "Nextcloud Photos"))
    }
}

extension View {
    /// The info panel: a trailing inspector on iOS/iPadOS and macOS, a sheet on visionOS (which has no inspector).
    ///
    /// Only the app opens it; the system may only close it (a swipe, a narrower window). On iPad the system restored an
    /// inspector that had been open when the app was last quit, through the binding: the next launch showed an empty
    /// "No selection" panel beside the Library, and ⌘I then seemed to do nothing because it closed that panel.
    func infoInspector<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        let isPresented = Binding<Bool>(
            get: { isPresented.wrappedValue },
            set: { (shown: Bool) in if !shown { isPresented.wrappedValue = false } })
        #if os(visionOS)
            return sheet(isPresented: isPresented) { NavigationStack { content() } }
        #else
            return inspector(isPresented: isPresented) {
                content()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                    #if os(iOS)
                        // The iPad's inspector column is clear glass over the photo: its secondary text (section
                        // headers, row titles) came out below 3:1 on light photos (SPEC §20.3). A thick material
                        // behind the info keeps the glass look and the text legible.
                        .background(.thickMaterial)
                        // iPhone (and narrow iPad windows), where the inspector is a sheet: half height first, so the
                        // photo stays in view above the info as in Photos, and the photo can still be paged meanwhile.
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .presentationDragIndicator(.visible)
                    #endif
            }
        #endif
    }
}

// MARK: - Chrome motion (SPEC §17.3) ------------------------------------------------------------------------------------
// Shared by the toolbars, the tab bar's progress accessory, the status rows and the counters. Every helper here falls
// back to a plain cross-fade (or nothing) with Reduce Motion.

/// The animations of the app's chrome: short, critically damped springs; a fade with Reduce Motion.
enum ChromeMotion {
    /// A toolbar morphing into another one (Select ⇄ Done, a panel showing up).
    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)
    }

    /// A counter rolling to its new value.
    static func counter(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.3)
    }

    /// How long a finished activity keeps showing its check mark before its accessory goes away.
    static let finishedLinger: Duration = .seconds(2.5)
    /// The open lock shows this long before the unlocked content replaces it.
    static let unlockedLinger: Duration = .milliseconds(450)
}

extension View {
    /// A number that rolls to its new value, digit by digit (`contentTransition(.numericText)`); with Reduce Motion it
    /// changes in place. Put it on the `Text` showing `value`.
    func rollingNumber(_ value: Int) -> some View {
        modifier(RollingNumberModifier(value: Double(value)))
    }

    /// A progress percentage or other fractional number that rolls (see `rollingNumber(_:)`).
    func rollingNumber(_ value: Double) -> some View {
        modifier(RollingNumberModifier(value: value))
    }
}

private struct RollingNumberModifier: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(ChromeMotion.counter(reduceMotion: reduceMotion), value: value)
    }
}

/// What a status symbol shows: something at work, or how it ended.
enum ChromeSymbolState: Equatable {
    case idle
    case working
    case done
    case failed
}

/// The SF Symbol of a background activity, animated while it works (SPEC §17.3): the upload cloud lifts its arrow, the
/// backup breathes, the sync arrows turn; when it is done the symbol is replaced by a check mark (a cross-fade with
/// Reduce Motion, which also stops the repeating effects).
struct ChromeStatusSymbol: View {
    enum Kind: Equatable {
        case upload, backup, sync, importing
    }

    let kind: Kind
    let state: ChromeSymbolState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .modifier(WorkingEffect(kind: kind, isActive: state == .working && !reduceMotion))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: state)
    }

    var symbolName: String { Self.symbolName(kind, state) }

    static func symbolName(_ kind: Kind, _ state: ChromeSymbolState) -> String {
        switch (kind, state) {
        case (_, .done): "checkmark.circle.fill"
        case (_, .failed): "exclamationmark.circle.fill"
        case (.upload, _): "icloud.and.arrow.up"
        case (.backup, _): "arrow.triangle.2.circlepath.icloud"
        case (.sync, _): "arrow.triangle.2.circlepath"
        case (.importing, _): "square.and.arrow.down.on.square"
        }
    }

    var tint: AnyShapeStyle {
        switch state {
        case .done: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.orange)
        case .idle, .working: AnyShapeStyle(.tint)
        }
    }

    /// The effect while working: one per kind, so each reads as what it is.
    private struct WorkingEffect: ViewModifier {
        let kind: Kind
        let isActive: Bool

        func body(content: Content) -> some View {
            switch kind {
            case .upload:
                content.symbolEffect(.wiggle.up.byLayer, options: .repeat(.periodic(delay: 1.2)), isActive: isActive)
            case .backup, .importing:
                content.symbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous), isActive: isActive)
            case .sync:
                content.symbolEffect(.rotate.clockwise.byLayer, options: .repeat(.continuous), isActive: isActive)
            }
        }
    }
}

/// A padlock that clicks open (the shackle lifts, `replace.magic`) when `isOpen` turns true; a cross-fade with Reduce
/// Motion.
struct ChromeLockSymbol: View {
    let isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace.downUp)))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: isOpen)
    }
}

extension View {
    /// The favourite heart bounces each time `trigger` changes (not with Reduce Motion).
    func favoriteBounce(_ trigger: Int) -> some View {
        modifier(FavoriteBounce(trigger: trigger))
    }
}

private struct FavoriteBounce: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce.up.byLayer, value: trigger)
        }
    }
}

extension View {
    /// A floating surface of the chrome (a status pill, a map panel): Liquid Glass on iPhone, iPad and Mac, the glass
    /// material on Vision Pro; with Reduce Transparency or Increase Contrast a solid surface with a hairline edge.
    func chromeGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(ChromeGlass(shape: shape))
    }
}

private struct ChromeGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(.background, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: contrast == .increased ? 1 : 0.5) }
        } else {
            #if os(visionOS)
                content.glassBackgroundEffect(in: shape)
            #else
                content.glassEffect(.regular, in: shape)
            #endif
        }
    }
}

// MARK: - Albums and transitions (SPEC §17.4)

/// How a card (album, memory, person, place, smart album) opens its screen.
enum CardTransition: Equatable {
    /// The screen grows out of the card and shrinks back into it (iPhone, iPad).
    case zoom
    /// The system's cross-fade: Reduce Motion, and Vision Pro, where windows do not zoom.
    case crossFade
    /// A short fade-in of the pushed screen: the Mac's stacks have no navigation transitions of their own.
    case fade

    enum Platform {
        case phoneOrPad, mac, vision

        static var current: Platform {
            #if os(macOS)
                .mac
            #elseif os(visionOS)
                .vision
            #else
                .phoneOrPad
            #endif
        }
    }

    static func style(reduceMotion: Bool, platform: Platform = .current) -> CardTransition {
        switch platform {
        case .mac: .fade
        case .vision: .crossFade
        case .phoneOrPad: reduceMotion ? .crossFade : .zoom
        }
    }
}

extension EnvironmentValues {
    /// The namespace of the zoom transitions into screens pushed by value (`AppRoute`, `RouteView`), set by each
    /// navigation stack: the card and the screen it opens both have to use the stack's namespace.
    @Entry var routeTransitionNamespace: Namespace.ID?
}

extension View {
    /// Marks a card as the place its screen zooms out of (`cardTransitionDestination` with the same `id`).
    func cardTransitionSource(
        id: some Hashable, in namespace: Namespace.ID?, cornerRadius: CGFloat = Design.coverCornerRadius
    ) -> some View {
        modifier(CardTransitionSource(id: AnyHashable(id), namespace: namespace, cornerRadius: cornerRadius))
    }

    /// The pushed screen of a card: zooms out of the card (`cardTransitionSource`) on iPhone and iPad, cross-fades with
    /// Reduce Motion and on Vision Pro, fades in on the Mac. Without a namespace the push is the system's own.
    func cardTransitionDestination(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        modifier(CardTransitionDestination(id: AnyHashable(id), namespace: namespace))
    }
}

private struct CardTransitionSource: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID?
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if os(iOS)
            if let namespace {
                content.matchedTransitionSource(id: id, in: namespace) { source in
                    source.clipShape(.rect(cornerRadius: cornerRadius))
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

private struct CardTransitionDestination: ViewModifier {
    let id: AnyHashable
    let namespace: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Mac's fade: the screen has come in.
    @State private var shown = false

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .opacity(namespace == nil || shown ? 1 : 0)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(.easeOut(duration: 0.18)) { shown = true }
                }
        #else
            if let namespace {
                switch CardTransition.style(reduceMotion: reduceMotion) {
                case .zoom:
                    #if os(iOS)
                        content.navigationTransition(.zoom(sourceID: id, in: namespace))
                    #else
                        content.navigationTransition(.crossFade)
                    #endif
                case .crossFade, .fade:
                    content.navigationTransition(.crossFade)
                }
            } else {
                content
            }
        #endif
    }
}

/// The picture of a card drifts a little against the scrolling, as if it lay a bit deeper than the card (SPEC §17.4).
enum ScrollParallax {
    /// How far the picture moves at most, as a share of the card's length; the picture is enlarged by twice this, so
    /// its edges never show.
    static let amount: CGFloat = 0.05

    /// The picture's offset along the scroll axis: zero when the card is in the middle of the visible area, up to
    /// `amount` of its length (against the scrolling) when it is about to leave it.
    static func offset(itemMid: CGFloat, itemLength: CGFloat, viewportMid: CGFloat, viewportLength: CGFloat, amount: CGFloat = amount)
        -> CGFloat
    {
        let reach = viewportLength / 2 + itemLength / 2
        guard reach > 0, itemLength > 0 else { return 0 }
        let progress = min(max((itemMid - viewportMid) / reach, -1), 1)
        return -progress * amount * itemLength
    }
}

extension View {
    /// Parallax of a card's picture inside its clip shape (apply before clipping). Off with Reduce Motion. The offset is
    /// a visual effect: it is applied while rendering, without laying anything out again while scrolling.
    func scrollParallax(_ axis: Axis = .vertical) -> some View {
        modifier(ScrollParallaxEffect(axis: axis))
    }
}

private struct ScrollParallaxEffect: ViewModifier {
    let axis: Axis
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let axis = axis
            content
                .scaleEffect(1 + 2 * ScrollParallax.amount)
                .visualEffect { effect, proxy in
                    let frame: CGRect = proxy.frame(in: .scrollView(axis: axis))
                    let viewport: CGRect = proxy.bounds(of: .scrollView(axis: axis)) ?? .zero
                    let offset: CGFloat =
                        axis == .vertical
                        ? ScrollParallax.offset(
                            itemMid: frame.midY, itemLength: frame.height, viewportMid: viewport.midY, viewportLength: viewport.height)
                        : ScrollParallax.offset(
                            itemMid: frame.midX, itemLength: frame.width, viewportMid: viewport.midX, viewportLength: viewport.width)
                    return effect.offset(x: axis == .horizontal ? offset : 0, y: axis == .vertical ? offset : 0)
                }
        }
    }
}

/// A soft gradient in Nextcloud's blues for an album without a cover photo, made from the album's name: the same on every
/// device and every launch, different from album to album (SPEC §17.4).
enum AlbumGradient {
    struct Tone: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    struct Spec: Equatable {
        /// 3 × 3 colours, row by row.
        var tones: [Tone]
        /// 3 × 3 points in the unit square, row by row; the corners and edges stay on the edges.
        var points: [SIMD2<Float>]
    }

    /// The hues of the family: from a cyan blue to a violet blue around Nextcloud blue (hue 0.56).
    static let hueRange: ClosedRange<Double> = 0.5...0.7

    static func spec(for name: String, dark: Bool) -> Spec {
        var random = SeededRandom(seed: stableHash(name))
        let base = 0.53 + random.next() * 0.1
        var tones: [Tone] = []
        for _ in 0..<9 {
            let hue = min(max(base + (random.next() - 0.5) * 0.1, hueRange.lowerBound), hueRange.upperBound)
            let saturation = 0.35 + random.next() * 0.45
            let brightness = dark ? 0.32 + random.next() * 0.3 : 0.72 + random.next() * 0.26
            tones.append(Tone(hue: hue, saturation: saturation, brightness: brightness))
        }
        var points: [SIMD2<Float>] = []
        for row in 0..<3 {
            for column in 0..<3 {
                var x = Float(column) / 2
                var y = Float(row) / 2
                // Points inside an edge move along it; the middle one moves freely.
                if column == 1 { x += Float((random.next() - 0.5) * 0.3) }
                if row == 1 { y += Float((random.next() - 0.5) * 0.3) }
                points.append(SIMD2(x, y))
            }
        }
        return Spec(tones: tones, points: points)
    }

    /// FNV-1a over the name's UTF-8: `hashValue` changes with every launch.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    /// A small deterministic generator (SplitMix64), so the gradient follows from the name alone.
    struct SeededRandom {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        /// The next number in 0..<1.
        mutating func next() -> Double {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            z ^= z >> 31
            return Double(z >> 11) / Double(UInt64(1) << 53)
        }
    }
}

/// The gradient of an album without a cover (`AlbumGradient`).
struct AlbumGradientView: View {
    let name: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let spec = AlbumGradient.spec(for: name, dark: colorScheme == .dark)
        MeshGradient(
            width: 3, height: 3, points: spec.points,
            colors: spec.tones.map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness) }
        )
        .accessibilityHidden(true)
    }
}

/// A caption on a card's picture (title and count of an album): Liquid Glass, so it stays readable over any photo; a
/// solid plate with Reduce Transparency or Increase Contrast, a material on Vision Pro (SPEC §17.4).
struct CaptionPlate<Content: View>: View {
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let label = content()
            // UI tests: text on the plate's glass, which the audit measures against the cover behind it (SPEC §20.3).
            .accessibilityIdentifier("caption-plate")
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        if reduceTransparency || contrast == .increased {
            label
                .foregroundStyle(.primary)
                .background(.background, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 1) }
        } else {
            #if os(visionOS)
                label.background(.regularMaterial, in: shape)
            #else
                label.glassEffect(.regular, in: shape)
            #endif
        }
    }
}

/// A small round badge on a card's picture (shared, smart album): glass, or a solid circle with Reduce Transparency.
struct GlassCircle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: .circle)
        } else {
            #if os(visionOS)
                content.background(.regularMaterial, in: .circle)
            #else
                content.glassEffect(.regular, in: .circle)
            #endif
        }
    }
}

// MARK: - Typography (SPEC §17.5) [levels]

/// The app's text styles, defined once (SPEC §17.5). All of them are Dynamic Type styles, so they grow with the user's
/// text size; the Mac has its own, smaller type scale and gets the sizes it uses in its own apps.
///
/// - Big numbers (a year, a count that is the point of a card or a statistic) use rounded numerals.
/// - Counts next to a title use tabular digits, so a changing number does not make the line wobble.
/// - Titles on or under a cover (albums, memories) are a little smaller than a headline and may take two lines.
/// - Date headers contrast a bold date with a light day line.
public enum Typography {
    /// A year as the title of a card (Library years, Year in review).
    public static var yearTitle: Font { .system(.largeTitle, design: .rounded, weight: .bold) }

    /// A figure that is the point of its card (Insights, statistics, a year's photo count): rounded and tabular.
    public static var figure: Font { .system(.title2, design: .rounded, weight: .semibold).monospacedDigit() }

    /// The one big figure of a screen (countries visited, a smart album's count).
    public static var heroFigure: Font { .system(.title, design: .rounded, weight: .bold).monospacedDigit() }

    /// A year under a picture (a year's column, a then-and-now pair).
    public static var yearLabel: Font { .system(.title2, design: .rounded, weight: .bold).monospacedDigit() }

    /// A count beside or under a title ("1,234 photos"): rounded, tabular.
    public static var count: Font { .system(.subheadline, design: .rounded).monospacedDigit() }

    /// A small count (rows of a list, chart annotations).
    public static var smallCount: Font { .system(.caption, design: .rounded, weight: .medium).monospacedDigit() }

    /// The title of an album or memory under its cover.
    public static var cardTitle: Font {
        #if os(macOS)
            .body.weight(.semibold)
        #else
            .subheadline.weight(.semibold)
        #endif
    }

    /// The line under a card's title (count, owner, place).
    public static var cardSubtitle: Font {
        #if os(macOS)
            .subheadline
        #else
            .caption
        #endif
    }

    /// A title written on a photo (a memory, a month card).
    public static var overlayTitle: Font { .headline.weight(.bold) }

    /// The line under a title written on a photo.
    public static var overlaySubtitle: Font { .caption.weight(.medium) }

    /// A date header's date: bold.
    public static var dateTitle: Font { .title2.weight(.bold) }

    /// A smaller date (a day in the days level): bold.
    public static var dayTitle: Font { .headline.weight(.bold) }

    /// A date header's second line (weekday, place, count): light against the bold date.
    public static var dateDetail: Font { .subheadline }

    /// A section heading on a screen ("Year in review", "Memories").
    public static var sectionTitle: Font { .title2.weight(.bold) }

    /// Most lines a card title takes: two, or a few more at the accessibility text sizes (instead of a word and "…").
    public static func cardTitleLines(_ size: DynamicTypeSize) -> Int { size.isAccessibilitySize ? 4 : 2 }

    #if canImport(UIKit)
        /// The grid's date headers (UIKit): bold date, light day line.
        public static var dateTitleUIFont: UIFont {
            .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize, weight: .bold)
        }
        public static var dateDetailUIFont: UIFont {
            .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        }
        /// A moment's title on a day line: stands out from the light day.
        public static var dateEmphasisUIFont: UIFont {
            .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        }
    #elseif canImport(AppKit)
        /// The grid's date headers (AppKit): the Mac's own sizes.
        public static var dateTitleNSFont: NSFont { .systemFont(ofSize: 20, weight: .bold) }
        public static var dateDetailNSFont: NSFont { .systemFont(ofSize: 12, weight: .regular) }
        public static var dateEmphasisNSFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }
    #endif
}

extension View {
    /// An album's or memory's title under its cover: up to two lines (more at accessibility sizes), cut at the end.
    public func cardTitleStyle() -> some View {
        modifier(CardTitleStyle())
    }
}

private struct CardTitleStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .font(Typography.cardTitle)
            .lineLimit(Typography.cardTitleLines(dynamicTypeSize))
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
    }
}

// MARK: - Combined round 7

extension EnvironmentValues {
    /// Height of a control floating over the bottom of a screen (the Library's zoom picker): notices of the screen
    /// underneath stand above it.
    @Entry var floatingBottomInset: CGFloat = 0
}
