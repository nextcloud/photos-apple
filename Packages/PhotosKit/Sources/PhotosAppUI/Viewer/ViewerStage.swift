// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosModel
import SwiftUI

// MARK: - The viewer as a stage (SPEC §17.1)

/// The decisions behind the viewer as a stage: its colour, where the photo goes while the info card is open, and the
/// geometry of closing it with a drag back into its tile. Pure functions, so they are tested without a screen.
enum ViewerStage {
    /// The stage is dark in Dark Mode and while the controls are hidden (as in Photos: a tap on a photo in Light Mode
    /// turns the white stage black); otherwise it is light.
    static func isDark(darkAppearance: Bool, controlsHidden: Bool) -> Bool {
        darkAppearance || controlsHidden
    }

    /// The two lines of the date pill: the day, and the time with the place ("22 November 2026" / "14:36 · Lisbon").
    static func pillLines(date: Date, place: String?, timeZone: TimeZone = .current, locale: Locale = .current) -> (
        title: String, detail: String
    ) {
        var dayStyle = Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: timeZone)
        dayStyle.calendar = Calendar(identifier: .gregorian)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        let time: String = date.formatted(timeStyle)
        let trimmedPlace: String = (place ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (date.formatted(dayStyle), trimmedPlace.isEmpty ? time : "\(time) · \(trimmedPlace)")
    }

    /// How the page is scaled and moved so that the photo fits between `top` and `bottom` (page coordinates) — above
    /// the info card on iPhone, as in Photos. A photo that fits already is only moved; it is never enlarged.
    static func infoPlacement(content: CGSize, page: CGSize, top: CGFloat, bottom: CGFloat) -> (scale: CGFloat, offsetY: CGFloat) {
        guard page.width > 0, page.height > 0, bottom - top > 1 else { return (1, 0) }
        let fitted: CGSize = ViewerZoom.fittedSize(content: content, in: page)
        let room: CGSize = ViewerZoom.fittedSize(content: content, in: CGSize(width: page.width, height: bottom - top))
        guard fitted.width > 0, fitted.height > 0 else { return (1, 0) }
        let scale: CGFloat = min(1, room.height / fitted.height, room.width / fitted.width)
        let offsetY: CGFloat = (top + bottom) / 2 - page.height / 2
        return (scale, offsetY)
    }
}

/// Where the page is while it is dragged down to close and while it lands in its tile.
///
/// The page is clipped to `clip` (page coordinates, the photo's rectangle), then scaled by `scale` around the page's
/// centre and moved by `offset`.
struct ViewerDismissPose: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    /// Nil: the page is not clipped (the viewer at rest).
    var clip: CGRect?
    /// 0…1: how far towards closing, for the backdrop and the controls fading out.
    var progress: CGFloat = 0

    static let rest = ViewerDismissPose()
}

enum ViewerDismissal {
    /// How small the photo gets while it is dragged all the way down.
    static let smallestDragScale: CGFloat = 0.55

    /// The photo's rectangle in a page of `page` size: fitted and centred.
    static func photoRect(content: CGSize, page: CGSize) -> CGRect {
        let size: CGSize = ViewerZoom.fittedSize(content: content, in: page)
        return CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The photo follows the finger and shrinks the further down it is dragged (not when dragged up).
    static func dragPose(translation: CGSize, page: CGSize, photo: CGRect) -> ViewerDismissPose {
        let progress: CGFloat = ViewerSwipe.dismissProgress(translation: translation.height, height: page.height)
        let scale: CGFloat = 1 - (1 - smallestDragScale) * progress
        return ViewerDismissPose(scale: scale, offset: translation, clip: photo, progress: progress)
    }

    /// The pose in which the photo exactly covers its tile: `tile` and `pageOrigin` are in the same (global)
    /// coordinates. The photo fills the tile as the grid shows it (aspect fill); what is outside the tile is clipped.
    static func landingPose(tile: CGRect, pageOrigin: CGPoint, page: CGSize, photo: CGRect) -> ViewerDismissPose {
        guard photo.width > 0, photo.height > 0, tile.width > 0, tile.height > 0 else {
            return ViewerDismissPose(scale: 1, offset: .zero, clip: photo, progress: 1)
        }
        let scale: CGFloat = max(tile.width / photo.width, tile.height / photo.height)
        let clipSize = CGSize(width: tile.width / scale, height: tile.height / scale)
        let clip = CGRect(
            x: photo.midX - clipSize.width / 2, y: photo.midY - clipSize.height / 2, width: clipSize.width, height: clipSize.height)
        // A point q of the page lands at pageOrigin + centre + scale × (q − centre) + offset.
        let center = CGPoint(x: page.width / 2, y: page.height / 2)
        let offset = CGSize(
            width: tile.midX - pageOrigin.x - center.x - scale * (photo.midX - center.x),
            height: tile.midY - pageOrigin.y - center.y - scale * (photo.midY - center.y))
        return ViewerDismissPose(scale: scale, offset: offset, clip: clip, progress: 1)
    }

    /// The finger's speed as the spring's initial velocity: in units of the distance still to go per second, only the
    /// part of it that points the way the photo moves, and capped (a wild flick does not overshoot).
    static func springVelocity(_ velocity: CGVector, from: CGSize, to: CGSize) -> Double {
        let distance = CGVector(dx: to.width - from.width, dy: to.height - from.height)
        let length: CGFloat = hypot(distance.dx, distance.dy)
        guard length > 1, velocity.dx.isFinite, velocity.dy.isFinite else { return 0 }
        let along: CGFloat = (velocity.dx * distance.dx + velocity.dy * distance.dy) / length
        return Double(min(8, max(0, along / length)))
    }

    /// A tile counts as a landing place only when enough of it is on screen.
    static func isLandable(tile: CGRect?, screen: CGRect) -> Bool {
        guard let tile, tile.width > 4, tile.height > 4 else { return false }
        let visible: CGRect = tile.intersection(screen)
        return !visible.isNull && visible.width * visible.height >= tile.width * tile.height * 0.5
    }
}

/// The clip of the page while it is dragged and while it lands: the photo's rectangle, animated.
struct ViewerClipShape: Shape {
    var rect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(rect.origin.x, rect.origin.y), AnimatablePair(rect.size.width, rect.size.height)) }
        set {
            rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in bounds: CGRect) -> Path { Path(rect) }
}

extension View {
    /// The page in a dismissal pose: clipped to the photo, scaled and moved. At rest nothing is clipped (the clip is
    /// then the whole page and beyond, so paging is not cut).
    func viewerDismissPose(_ pose: ViewerDismissPose, page: CGSize) -> some View {
        let clip: CGRect = pose.clip ?? CGRect(x: -page.width, y: -page.height, width: page.width * 3, height: page.height * 3)
        return
            self
            .clipShape(ViewerClipShape(rect: clip))
            .scaleEffect(pose.scale)
            .offset(pose.offset)
    }
}

extension EnvironmentValues {
    /// How far below the top of a page the badges on a photo (Live, RAW) go: below the floating controls on iPhone and
    /// iPad, the old fixed distance elsewhere.
    @Entry var viewerControlsInset: CGFloat = 60
}

// MARK: - Glass controls (iPhone, iPad)

#if os(iOS)
    /// The viewer's controls floating over the photo: a round close button and the date pill at the top, the action bar
    /// at the bottom — Liquid Glass, faded out together with a tap on the photo (SPEC §17.1).
    struct ViewerStageControls<MoreMenu: View>: View {
        let item: MediaItem?
        let isVisible: Bool
        /// 0…1 while the photo is dragged down to close: the controls fade with the backdrop.
        var dismissProgress: CGFloat = 0
        var offersActions = true
        let close: () -> Void
        let toggleFavorite: (MediaItem) -> Void
        let toggleInfo: () -> Void
        let edit: (MediaItem) -> Void
        let delete: () -> Void
        @ViewBuilder let more: (MediaItem) -> MoreMenu
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if offersActions, let item { actionBar(item) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .opacity(isVisible ? 1 - Double(dismissProgress) : 0)
            .allowsHitTesting(isVisible && dismissProgress == 0)
            .accessibilityHidden(!isVisible)
            .animation(.easeInOut(duration: 0.25), value: isVisible)
        }

        var topBar: some View {
            ZStack {
                if let item { pill(item) }
                HStack {
                    Button(action: close) {
                        Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(glass.interactive(), in: .circle)
                    .help(String(localized: "Close", bundle: .module))
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 4)
        }

        /// "22 November 2026 / 14:36 · Lisbon"; a tap shows the info.
        func pill(_ item: MediaItem) -> some View {
            let lines = ViewerStage.pillLines(date: item.timestamp, place: item.place)
            return Button(action: toggleInfo) {
                VStack(spacing: 1) {
                    Text(lines.title)
                        .font(.subheadline.weight(.semibold))
                    Text(lines.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(glass.interactive(), in: .capsule)
            // Leaves room for the close button on either side, so the pill stays centred.
            .padding(.horizontal, 60)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(Text("Shows the info", bundle: .module, comment: "Viewer: hint of the date pill at the top."))
            .disabled(!offersActions)
        }

        var glass: Glass {
            // Increase Contrast: the glass takes more of the background colour, for the text on it.
            contrast == .increased ? .regular.tint(Color(uiColor: .systemBackground).opacity(0.6)) : .regular
        }

        func actionBar(_ item: MediaItem) -> some View {
            GlassEffectContainer {
                HStack(spacing: 2) {
                    ShareMediaButton(items: [item])
                        .frame(width: 44, height: 44)
                    Button {
                        toggleFavorite(item)
                    } label: {
                        Label(
                            MediaViewer.favoriteTitle(remove: item.isFavorite), systemImage: item.isFavorite ? "heart.fill" : "heart"
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                    }
                    .symbolEffect(.bounce, value: item.isFavorite)
                    Button(action: toggleInfo) {
                        Label(String(localized: "Info", bundle: .module), systemImage: "info.circle")
                            .frame(width: 44, height: 44)
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    if item.kind == .image {
                        Button {
                            edit(item)
                        } label: {
                            Label(String(localized: "Edit", bundle: .module), systemImage: "slider.horizontal.3")
                                .frame(width: 44, height: 44)
                        }
                    }
                    Menu {
                        more(item)
                    } label: {
                        Label(String(localized: "More", bundle: .module), systemImage: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    Button(role: .destructive, action: delete) {
                        Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!item.permissions.canDelete)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(glass, in: .capsule)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
#endif
