// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import PhotosCore
    import PhotosDomain
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI
    import UIKit

    /// The place of the grid's header in the collection view: it holds the one hosting view.
    final class GridHeaderSlot: UICollectionReusableView {
        static let reuseIdentifier = "GridHeaderSlot"

        func hold(_ content: UIView?) {
            guard let content else { return }
            if content.superview !== self {
                content.removeFromSuperview()
                addSubview(content)
            }
            content.autoresizingMask = []
            fit(content)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            subviews.forEach(fit)
        }

        /// The header takes the slot's size, but never an empty one: a slot can be zero-sized for a moment while it is
        /// reused, and a SwiftUI scroll view (the memory stories) that is animating in a zero-sized host trapped in
        /// `ResolvedScrollBehavior.updateTarget` (STATUS §M8).
        private func fit(_ content: UIView) {
            guard !bounds.isEmpty, content.frame != bounds else { return }
            content.frame = bounds
        }
    }

    final class SectionHeader: UICollectionReusableView {
        static let reuseIdentifier = "SectionHeader"
        // Bold date, light day line (SPEC §17.5).
        static var titleFont: UIFont { Typography.dateTitleUIFont }
        static var subtitleFont: UIFont { Typography.dateDetailUIFont }
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private var metrics = GridHeaderMetrics(titleHeight: 28, subtitleHeight: 20)
        /// The moment's title and the day: a button that opens the moment (SPEC §16.1).
        private let momentButton = UIControl()
        private var moment: MomentHeaders.Entry?
        var openMoment: ((String) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // No band behind the text: the headers scroll with the photos, the date pill stays (SPEC §17.2).
            subtitleLabel.textColor = .secondaryLabel
            titleLabel.accessibilityTraits = .header
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            momentButton.isHidden = true
            momentButton.isAccessibilityElement = true
            momentButton.accessibilityTraits = [.button, .header]
            // Pointer (iPad) and gaze (Vision Pro): the title is highlighted like a button.
            momentButton.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 6))
            momentButton.addTarget(self, action: #selector(momentTapped), for: .touchUpInside)
            addSubview(momentButton)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Laid out by hand from the same metrics the layout takes the header height from, so nothing is clipped.
        override func layoutSubviews() {
            super.layoutSubviews()
            let area = bounds.inset(by: layoutMargins)
            var y = CGFloat(metrics.top)
            if !titleLabel.isHidden {
                titleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.titleHeight))
                y += CGFloat(metrics.titleHeight + metrics.gap)
            }
            if !subtitleLabel.isHidden {
                subtitleLabel.frame = CGRect(x: area.minX, y: y, width: area.width, height: CGFloat(metrics.subtitleHeight))
                // The button covers the text (and a little around it), not the whole width of the header.
                let textWidth = min(subtitleLabel.intrinsicContentSize.width, area.width)
                momentButton.frame = CGRect(x: area.minX - 6, y: y - 4, width: textWidth + 12, height: CGFloat(metrics.subtitleHeight) + 8)
            }
        }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.font = Self.titleFont
            subtitleLabel.font = Self.subtitleFont
            titleLabel.text = text.title
            titleLabel.isHidden = text.title == nil
            moment = text.moment
            if let moment = text.moment {
                subtitleLabel.attributedText = Self.momentLine(moment.title, day: text.subtitle, font: Self.subtitleFont)
                momentButton.accessibilityLabel = text.momentAccessibilityLabel
                momentButton.accessibilityHint = String(
                    localized: "Opens the moment", bundle: .module,
                    comment: "VoiceOver hint of a moment title on a day header of the library.")
                subtitleLabel.isAccessibilityElement = false
            } else {
                subtitleLabel.attributedText = nil
                subtitleLabel.text = text.subtitle
                subtitleLabel.isAccessibilityElement = true
            }
            momentButton.isHidden = text.moment == nil
            subtitleLabel.isHidden = text.subtitle == nil && text.moment == nil
            setNeedsLayout()
        }

        /// "Sunday in Lisbon ›  Sun 22 November": the moment in the label colour, the day after it as before.
        static func momentLine(_ title: String, day: String?, font: UIFont) -> NSAttributedString {
            let line = NSMutableAttributedString(
                string: title, attributes: [.font: Typography.dateEmphasisUIFont.withSize(font.pointSize), .foregroundColor: UIColor.label])
            let symbol = UIImage(
                systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(font: font.withSize(font.pointSize * 0.75)))
            if let symbol {
                let attachment = NSTextAttachment(image: symbol.withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal))
                line.append(NSAttributedString(string: " "))
                line.append(NSAttributedString(attachment: attachment))
            }
            if let day {
                line.append(
                    NSAttributedString(string: "  " + day, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
            }
            return line
        }

        @objc private func momentTapped() {
            guard let moment else { return }
            openMoment?(moment.momentId)
        }
    }

    extension UIFont {
        func withWeight(_ weight: UIFont.Weight) -> UIFont {
            UIFont.systemFont(ofSize: pointSize, weight: weight)
        }
    }
#endif
