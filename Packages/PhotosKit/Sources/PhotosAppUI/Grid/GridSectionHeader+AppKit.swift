// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosCore
    import PhotosDomain
    import UniformTypeIdentifiers
    import PhotosMedia
    import PhotosModel
    import PhotosStore
    import SwiftUI

    final class SectionHeaderView: NSVisualEffectView, NSCollectionViewElement {
        static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
        private let titleLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")
        private var metrics = GridHeaderMetrics(titleHeight: 26, subtitleHeight: 16)
        /// The moment this day starts (SPEC §16.1): its title is a link that opens it.
        private var moment: MomentHeaders.Entry?
        private var momentLabel: String?
        var openMoment: ((String) -> Void)?
        // Bold date, light day line (SPEC §17.5).
        static var subtitleFont: NSFont { Typography.dateDetailNSFont }

        override init(frame: NSRect) {
            super.init(frame: frame)
            material = .headerView
            blendingMode = .withinWindow
            titleLabel.font = Typography.dateTitleNSFont
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setAccessibilityRole(.staticText)
            subtitleLabel.font = Self.subtitleFont
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            addGestureRecognizer(click)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        func configure(_ text: GridHeaderText, metrics: GridHeaderMetrics) {
            self.metrics = metrics
            titleLabel.stringValue = text.title ?? ""
            titleLabel.isHidden = text.title == nil
            moment = text.moment
            momentLabel = text.momentAccessibilityLabel
            if let moment = text.moment {
                subtitleLabel.attributedStringValue = Self.momentLine(moment.title, day: text.subtitle)
                subtitleLabel.setAccessibilityElement(false)
            } else {
                subtitleLabel.stringValue = text.subtitle ?? ""
                subtitleLabel.setAccessibilityElement(true)
            }
            subtitleLabel.isHidden = text.subtitle == nil && text.moment == nil
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }

        /// "Sunday in Lisbon ›  Sun 22 November": the moment in the label colour, the day after it as before.
        static func momentLine(_ title: String, day: String?) -> NSAttributedString {
            let line = NSMutableAttributedString(
                string: title, attributes: [.font: Typography.dateEmphasisNSFont, .foregroundColor: NSColor.labelColor])
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let symbol = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)?.withSymbolConfiguration(
                configuration)
            {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                line.append(NSAttributedString(string: " "))
                line.append(NSAttributedString(attachment: attachment))
            }
            if let day {
                line.append(
                    NSAttributedString(
                        string: "  " + day, attributes: [.font: subtitleFont, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            return line
        }

        /// Where a click opens the moment: the moment's line, as far as its text goes.
        private var momentRect: NSRect? {
            guard moment != nil, !subtitleLabel.isHidden else { return nil }
            let width = min(subtitleLabel.attributedStringValue.size().width + 8, subtitleLabel.frame.width)
            return NSRect(
                x: subtitleLabel.frame.minX - 4, y: subtitleLabel.frame.minY - 3, width: width, height: subtitleLabel.frame.height + 6)
        }

        @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let moment, let rect = momentRect, rect.contains(gesture.location(in: self)) else { return }
            openMoment?(moment.momentId)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if let rect = momentRect { addCursorRect(rect, cursor: .pointingHand) }
        }

        // VoiceOver: with a moment the header is a button that opens it.
        override func isAccessibilityElement() -> Bool { moment != nil }
        override func accessibilityRole() -> NSAccessibility.Role? { moment != nil ? .button : super.accessibilityRole() }
        override func accessibilityLabel() -> String? { momentLabel }
        override func accessibilityPerformPress() -> Bool {
            guard let moment else { return false }
            openMoment?(moment.momentId)
            return true
        }

        /// Laid out by hand from the same metrics the layout takes the header height from, so nothing is clipped.
        override func layout() {
            super.layout()
            let width = max(bounds.width - 24, 0)
            var y = CGFloat(metrics.top)
            if !titleLabel.isHidden {
                titleLabel.frame = NSRect(x: 12, y: y, width: width, height: CGFloat(metrics.titleHeight))
                y += CGFloat(metrics.titleHeight + metrics.gap)
            }
            if !subtitleLabel.isHidden {
                subtitleLabel.frame = NSRect(x: 12, y: y, width: width, height: CGFloat(metrics.subtitleHeight))
            }
            window?.invalidateCursorRects(for: self)
        }
    }
#endif
