// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import PhotosModel
    import UIKit

    // The drawing of the grid's motion on iPhone, iPad and Vision Pro (SPEC §17.2); what it decides is in `GridMotion`.

    /// A glass surface: Liquid Glass on iPhone and iPad, the system's thin material in Vision Pro windows (which are glass
    /// themselves). Reduce Transparency and Increase Contrast make the system draw both more solid.
    @MainActor
    func gridGlassView() -> UIVisualEffectView {
        #if os(visionOS)
            UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        #else
            UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        #endif
    }

    // MARK: - Layout with leaving and returning tiles

    /// The grid's compositional layout, with the way tiles leave and come back in an animated batch update (delete:
    /// collapse, archive: slide away; Reduce Motion: a fade). Other batches keep the system's defaults.
    final class GridCollectionLayout: UICollectionViewCompositionalLayout {
        /// The style of the batch that is being applied; nil outside one.
        var leaveStyle: GridLeaveStyle?
        private var leaving: Set<IndexPath> = []
        private var leavingSections = IndexSet()
        private var coming: Set<IndexPath> = []
        private var comingSections = IndexSet()

        override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
            super.prepare(forCollectionViewUpdates: updateItems)
            leaving = []
            leavingSections = []
            coming = []
            comingSections = []
            guard leaveStyle != nil else { return }
            for update in updateItems {
                switch update.updateAction {
                case .delete:
                    guard let path = update.indexPathBeforeUpdate else { continue }
                    if path.item == NSNotFound { leavingSections.insert(path.section) } else { leaving.insert(path) }
                case .insert:
                    guard let path = update.indexPathAfterUpdate else { continue }
                    if path.item == NSNotFound { comingSections.insert(path.section) } else { coming.insert(path) }
                default: break
                }
            }
        }

        override func finalizeCollectionViewUpdates() {
            super.finalizeCollectionViewUpdates()
            leaving = []
            leavingSections = []
            coming = []
            comingSections = []
        }

        override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            let attributes = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
            guard let leaveStyle, leaving.contains(itemIndexPath) || leavingSections.contains(itemIndexPath.section),
                let attributes = attributes?.copy() as? UICollectionViewLayoutAttributes
            else { return attributes }
            return styled(attributes, leaveStyle, original: layoutAttributesForItem(at: itemIndexPath))
        }

        override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            let attributes = super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
            guard let leaveStyle, coming.contains(itemIndexPath) || comingSections.contains(itemIndexPath.section),
                let attributes = attributes?.copy() as? UICollectionViewLayoutAttributes
            else { return attributes }
            return styled(attributes, leaveStyle, original: nil)
        }

        /// Where a tile goes when it leaves (and comes from when it returns): small in its place, or off to the side.
        private func styled(
            _ attributes: UICollectionViewLayoutAttributes, _ style: GridLeaveStyle, original: UICollectionViewLayoutAttributes?
        ) -> UICollectionViewLayoutAttributes {
            // Leaving tiles stay where they were while their neighbours move into the gap.
            if let original { attributes.frame = original.frame }
            attributes.alpha = 0
            guard !UIAccessibility.isReduceMotionEnabled else { return attributes }
            switch style {
            case .collapse:
                attributes.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            case .slide:
                let direction: CGFloat = collectionView?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                attributes.transform = CGAffineTransform(translationX: direction * attributes.frame.width * 0.9, y: 0)
                    .scaledBy(x: 0.9, y: 0.9)
            }
            attributes.zIndex = -1
            return attributes
        }
    }

    // MARK: - Floating date pill

    /// The glass capsule at the top of a timeline (`GridDatePill`). Its text hands over to the next section's with a
    /// short push in the scrolling direction (a cross-fade with Reduce Motion).
    final class GridDatePillView: UIView {
        private let glass = gridGlassView()
        private let label = UILabel()
        private(set) var pill: GridDatePill?
        /// Shown (scrolled away from the top); the view fades in and out.
        private(set) var isShown = false

        static var font: UIFont { .preferredFont(forTextStyle: .subheadline).withWeight(.semibold) }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            alpha = 0
            glass.cornerConfiguration = .capsule()
            glass.clipsToBounds = true
            addSubview(glass)
            label.font = Self.font
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.lineBreakMode = .byTruncatingTail
            glass.contentView.addSubview(label)
            isAccessibilityElement = true
            accessibilityTraits = [.staticText, .updatesFrequently]
            // Over the photos: soft shadow so the capsule stands off bright pictures (the glass itself has none here).
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 8
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Size the pill wants for its text, at most `maxWidth` wide.
        func fittingSize(maxWidth: CGFloat) -> CGSize {
            // Measured by the label itself, with the font it draws with.
            let width = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
                .rounded(.up)
            let height = (label.font.lineHeight + 12).rounded(.up)
            // A few points to spare: the label must never truncate a text it was measured for.
            return CGSize(width: min(width + 34, maxWidth), height: max(height, 32))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            glass.frame = bounds
            label.frame = bounds.insetBy(dx: 15, dy: 0)
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        }

        /// New text; `handover` says which way it moves in. Returns whether the size may have changed.
        @discardableResult
        func show(_ pill: GridDatePill?, handover: GridDatePill.Handover) -> Bool {
            guard pill != self.pill else { return false }
            self.pill = pill
            if isShown, handover != .none, window != nil {
                let transition = CATransition()
                transition.duration = 0.25
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if UIAccessibility.isReduceMotionEnabled {
                    transition.type = .fade
                } else {
                    transition.type = .push
                    transition.subtype = handover == .older ? .fromTop : .fromBottom
                }
                label.layer.add(transition, forKey: "handover")
            }
            label.text = pill?.text
            accessibilityLabel = pill?.accessibilityLabel
            return true
        }

        /// Fades the pill in or out.
        func setShown(_ shown: Bool, animated: Bool) {
            guard shown != isShown else { return }
            isShown = shown
            let change = { self.alpha = shown ? 1 : 0 }
            if animated, window != nil {
                let reduceMotion = UIAccessibility.isReduceMotionEnabled
                if shown, !reduceMotion { transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
                UIView.animate(springDuration: 0.3, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    change()
                    self.transform = .identity
                }
            } else {
                change()
            }
        }
    }

    // MARK: - Video duration

    /// A video's duration in a small glass capsule in the tile's bottom trailing corner (SPEC §17.2). With Reduce
    /// Transparency or Increase Contrast it is a solid dark capsule.
    final class GridVideoPill: UIView {
        private var background: UIView?
        private let label = UILabel()
        private let icon = UIImageView(image: UIImage(systemName: "video.fill"))

        static var font: UIFont {
            .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            label.font = Self.font
            label.textColor = .white
            icon.tintColor = .white
            icon.contentMode = .scaleAspectFit
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            updateBackground()
            addSubview(icon)
            addSubview(label)
            registerForTraitChanges([UITraitAccessibilityContrast.self]) { (pill: GridVideoPill, _: UITraitCollection) in
                pill.updateBackground()
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(transparencyChanged), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                object: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func transparencyChanged() { updateBackground() }

        /// Glass, or a solid capsule where transparency gets in the way of reading.
        private func updateBackground() {
            let solid = UIAccessibility.isReduceTransparencyEnabled || traitCollection.accessibilityContrast == .high
            if solid, background is UIVisualEffectView || background == nil {
                background?.removeFromSuperview()
                let view = UIView()
                view.backgroundColor = UIColor.black.withAlphaComponent(0.75)
                view.cornerConfiguration = .capsule()
                insertSubview(view, at: 0)
                background = view
            } else if !solid, !(background is UIVisualEffectView) {
                background?.removeFromSuperview()
                let glass = gridGlassView()
                #if !os(visionOS)
                    // Dark-tinted, so that the white text reads over bright pictures as well.
                    let effect = UIGlassEffect(style: .clear)
                    effect.tintColor = UIColor.black.withAlphaComponent(0.28)
                    glass.effect = effect
                #endif
                glass.cornerConfiguration = .capsule()
                glass.clipsToBounds = true
                insertSubview(glass, at: 0)
                background = glass
            }
            setNeedsLayout()
        }

        /// The duration, or nil for a video of unknown length (only the camera glyph).
        func show(duration: String?) {
            label.text = duration
            label.isHidden = duration == nil
            setNeedsLayout()
        }

        /// Width for the current text at `height`.
        func fittingWidth(height: CGFloat) -> CGFloat {
            let text = label.isHidden ? 0 : ((label.text ?? "") as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up)
            return 6 + 10 + (text > 0 ? 3 + text : 0) + 6
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            background?.frame = bounds
            icon.frame = CGRect(x: 6, y: (bounds.height - 10) / 2, width: 10, height: 10)
            label.frame = CGRect(x: icon.frame.maxX + 3, y: 0, width: max(bounds.width - icon.frame.maxX - 3 - 6, 0), height: bounds.height)
        }
    }

    // MARK: - Heart burst

    extension UIView {
        /// A heart that springs up over the view and fades (favourite, SPEC §17.2); a plain fade with Reduce Motion.
        func playHeartBurst(side: CGFloat) {
            let heart = UIImageView(image: UIImage(systemName: "heart.fill"))
            heart.tintColor = .white
            heart.contentMode = .scaleAspectFit
            heart.isUserInteractionEnabled = false
            heart.isAccessibilityElement = false
            heart.layer.shadowColor = UIColor.black.cgColor
            heart.layer.shadowOpacity = 0.35
            heart.layer.shadowRadius = 6
            heart.layer.shadowOffset = .zero
            let size = min(max(side * 0.42, 18), 72)
            heart.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            addSubview(heart)
            heart.alpha = 0
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if !reduceMotion { heart.transform = CGAffineTransform(scaleX: 0.4, y: 0.4) }
            UIView.animate(springDuration: 0.35, bounce: 0.3) {
                heart.alpha = 1
                heart.transform = .identity
            } completion: { _ in
                UIView.animate(withDuration: 0.3, delay: 0.25, options: [.curveEaseIn]) {
                    heart.alpha = 0
                    if !reduceMotion { heart.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }
                } completion: { _ in
                    heart.removeFromSuperview()
                }
            }
        }
    }
#endif
