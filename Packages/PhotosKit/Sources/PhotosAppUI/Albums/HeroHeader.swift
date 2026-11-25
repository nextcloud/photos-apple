// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import SwiftUI

#if os(iOS)
    import UIKit
#endif

// MARK: - Hero headers (SPEC §17.4)

/// A full-width cover with the title above a grid's first row (an album, a memory, a person; iPhone and iPad). It scrolls
/// with the photos; once its title has gone under the navigation bar, the bar shows the title instead; pulled down past
/// the top, the cover stretches.
struct GridHero {
    var content: AnyView
    /// Told when the title moved under the navigation bar (true) or came back (false). Set by `MediaGridScreen`.
    var collapsedChanged: @MainActor (Bool) -> Void = { _ in }

    init(@ViewBuilder content: () -> some View) {
        self.content = AnyView(content())
    }

    /// Hero headers are an iPhone and iPad thing: the Mac and Vision Pro keep the title in the window's toolbar.
    static var isSupported: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }
}

/// Geometry of a hero header in the grid's scroll view. The hero lies above the first row, in the content inset: its
/// bottom is at content y 0 and its top at the top of the screen while the grid rests at its top.
enum HeroHeaderLayout {
    /// The part of the title band that has to show below the bar for the hero to count as open.
    static let titleBand: Double = 64

    /// Height of the hero below the navigation bar: about a third of the screen on iPhone in portrait, less in
    /// landscape, at most 380 points on iPad.
    static func visibleHeight(width: Double, viewportHeight: Double) -> Double {
        guard width > 0, viewportHeight > 0 else { return 0 }
        return min(width * 0.62, viewportHeight * 0.42, 380).rounded()
    }

    /// The hero's frame in the content: from the top of the screen down to the first row. Pulled down past the top,
    /// it grows upward with the pull, so the cover stretches instead of a gap opening above it.
    static func frame(offsetY: Double, safeTop: Double, visibleHeight: Double, width: Double) -> CGRect {
        let restingTop = -(safeTop + visibleHeight)
        let top = min(restingTop, offsetY)
        return CGRect(x: 0, y: top, width: width, height: -top)
    }

    /// The title has gone under the navigation bar: less than `titleBand` of the hero shows below the bar.
    static func isCollapsed(offsetY: Double, safeTop: Double) -> Bool {
        -offsetY - safeTop < titleBand
    }

}

/// The hero itself: the cover filling it, the title and a line of details at the bottom in white on a scrim. Under the
/// status bar and the bar's glass buttons the system's own scroll edge effect keeps them readable, in light and dark.
struct HeroHeaderView<Art: View, Badge: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var art: () -> Art
    /// Before the title (a person's face).
    @ViewBuilder var badge: () -> Badge
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var strong: Bool { contrast == .increased || reduceTransparency }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            art()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
            LinearGradient(
                colors: [.clear, .black.opacity(OverlayLegibility.scrimOpacity(base: 0.6, increased: strong))],
                startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom
            )
            .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 12) {
                badge()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline.weight(.medium)).lineLimit(2).opacity(0.92)
                    }
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(strong ? 0.6 : 0.3), radius: strong ? 2 : 6, y: 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            // The hero has a fixed height: the largest sizes would push the title out of it.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

extension HeroHeaderView where Badge == EmptyView {
    init(title: String, subtitle: String?, @ViewBuilder art: @escaping () -> Art) {
        self.init(title: title, subtitle: subtitle, art: art, badge: { EmptyView() })
    }
}

#if os(iOS)
    /// Hosts a `GridHero` in the grid's collection view (`PhotoGridController`): above the first row, in the content
    /// inset, scrolling with the tiles without any work per frame except while it is stretched.
    @MainActor
    final class GridHeroHost {
        private var hosting: UIHostingController<AnyView>?
        private var hero: GridHero?
        private var visibleHeight: CGFloat = 0
        private var collapsed: Bool?

        var isActive: Bool { hero != nil }

        func update(_ hero: GridHero?, in controller: UIViewController, collectionView: UICollectionView) {
            self.hero = hero
            guard let hero else {
                remove(from: collectionView)
                return
            }
            if let hosting {
                hosting.rootView = hero.content
            } else {
                let hosting = UIHostingController(rootView: hero.content)
                // The hero draws under the bar itself; SwiftUI must not move its content out of the safe area.
                hosting.safeAreaRegions = []
                hosting.sizingOptions = []
                hosting.view.backgroundColor = .clear
                controller.addChild(hosting)
                // Behind the tiles and the refresh control.
                collectionView.insertSubview(hosting.view, at: 0)
                hosting.didMove(toParent: controller)
                self.hosting = hosting
            }
            layout(collectionView)
        }

        /// Places the hero for the current scroll position; called on every layout and scroll.
        func layout(_ collectionView: UICollectionView) {
            guard let hosting, let hero else { return }
            let safeTop = collectionView.safeAreaInsets.top
            let height = CGFloat(
                HeroHeaderLayout.visibleHeight(
                    width: Double(collectionView.bounds.width), viewportHeight: Double(collectionView.bounds.height - safeTop)))
            if height != visibleHeight {
                let atTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 1
                visibleHeight = height
                collectionView.contentInset.top = height
                if atTop { collectionView.contentOffset.y = -collectionView.adjustedContentInset.top }
            }
            let offsetY = Double(collectionView.contentOffset.y)
            let frame = HeroHeaderLayout.frame(
                offsetY: offsetY, safeTop: Double(safeTop), visibleHeight: Double(height), width: Double(collectionView.bounds.width))
            if hosting.view.frame != frame { hosting.view.frame = frame }
            let isCollapsed = HeroHeaderLayout.isCollapsed(offsetY: offsetY, safeTop: Double(safeTop))
            guard isCollapsed != collapsed else { return }
            collapsed = isCollapsed
            let report = hero.collapsedChanged
            // Not inside SwiftUI's update of the grid.
            DispatchQueue.main.async { report(isCollapsed) }
        }

        private func remove(from collectionView: UICollectionView) {
            guard let hosting else { return }
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
            self.hosting = nil
            collectionView.contentInset.top = 0
            visibleHeight = 0
            collapsed = nil
        }
    }
#endif

/// While a grid with a hero loads: the hero where it will be, the tiles' skeleton below it.
struct HeroSkeleton: View {
    let hero: GridHero
    let zoomStep: Int

    var body: some View {
        GeometryReader { proxy in
            // As `GridHeroHost` measures it: the grid reaches under the bars at the top and the bottom.
            let visible = HeroHeaderLayout.visibleHeight(
                width: Double(proxy.size.width), viewportHeight: Double(proxy.size.height + proxy.safeAreaInsets.bottom))
            VStack(spacing: 0) {
                hero.content
                    .frame(height: CGFloat(visible) + proxy.safeAreaInsets.top)
                    .clipped()
                GridSkeleton(zoomStep: zoomStep, showsHeader: false)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}
