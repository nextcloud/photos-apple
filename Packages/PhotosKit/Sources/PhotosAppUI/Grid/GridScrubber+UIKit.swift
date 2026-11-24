// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import UIKit

    /// Date scrubber at the trailing edge of the grid on iOS, iPadOS and visionOS (SPEC §6.4), the counterpart of the
    /// Mac's: year labels along the visible part of the grid (between the bars), the month at the scroll position, and
    /// a handle that can be dragged to jump.
    ///
    /// Like the scroll indicator in Photos it appears while the grid scrolls and fades out afterwards, and it can only
    /// be grabbed while it is shown: the tiles under it stay tappable. Year labels that do not fit are left out
    /// (`GridScrubberTrack.visibleLabels`), and every label sits on a background of its own, so it can be read over
    /// photos. With VoiceOver it stays as an adjustable element (swipe up or down to go a year back or forward).
    final class GridScrubberView: UIView {
        struct Tick: Equatable {
            /// Position along the track, 0 (newest) … 1 (oldest).
            var fraction: Double
            var label: String
        }

        /// Width of the whole view (room for the month label at large text sizes).
        static let width: CGFloat = 240
        /// Width of the strip at the edge that can be grabbed.
        static let stripWidth: CGFloat = 36
        private static let inset: CGFloat = 12

        var ticks: [Tick] = [] {
            didSet { if ticks != oldValue { setNeedsDisplay() } }
        }
        /// Month label for a position along the track.
        var labelAt: ((Double) -> String)?
        /// The user dragged to a position along the track.
        var onScrub: ((Double) -> Void)?
        /// VoiceOver: jump to the next (+1, older) or previous (−1) year.
        var onStep: ((Int) -> Void)?

        private(set) var isScrubbing = false
        private var position = 0.0
        private var positionLabel = ""
        private var hideTask: Task<Void, Never>?
        #if os(iOS)
            private let feedback = UISelectionFeedbackGenerator()
            /// The year under the finger, for a tick of feedback when it changes.
            private var scrubbedYear: String?
        #endif

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            contentMode = .redraw
            alpha = 0
            isAccessibilityElement = true
            accessibilityTraits = .adjustable
            accessibilityLabel = String(localized: "Timeline position", bundle: .module)
            // Touch down grabs the handle at once, as in Photos; a pan would wait for the finger to move.
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
            press.minimumPressDuration = 0
            addGestureRecognizer(press)
            registerForTraitChanges(
                [UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
            ) { (view: GridScrubberView, _: UITraitCollection) in
                view.setNeedsDisplay()
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(accessibilityChanged), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
            accessibilityChanged()
        }

        required init?(coder: NSCoder) { fatalError() }

        private var strip: CGRect {
            CGRect(x: bounds.maxX - Self.stripWidth, y: 0, width: Self.stripWidth, height: bounds.height)
        }

        private var track: GridScrubberTrack {
            GridScrubberTrack(bounds: Double(bounds.height), inset: Double(Self.inset))
        }

        /// Shown, so the strip can be grabbed.
        private var isShown: Bool { !isHidden && alpha > 0.01 }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            isShown && strip.insetBy(dx: 0, dy: -4).contains(point)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }

        // MARK: Touch

        @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                isScrubbing = true
                #if os(iOS)
                    feedback.prepare()
                    scrubbedYear = nil
                #endif
                scrub(gesture)
            case .changed:
                scrub(gesture)
            default:
                isScrubbing = false
                setNeedsDisplay()
                scheduleHide()
            }
        }

        private func scrub(_ gesture: UIGestureRecognizer) {
            let fraction = track.fraction(at: Double(gesture.location(in: self).y))
            reveal()
            onScrub?(fraction)
            // The grid reports the new position (`scrolled(to:label:userInitiated:)`); the handle follows the finger.
            position = fraction
            if let label = labelAt?(fraction) { positionLabel = label }
            setNeedsDisplay()
            #if os(iOS)
                let year = ticks.last(where: { $0.fraction <= fraction + 0.000_1 })?.label
                if let year, scrubbedYear != nil, year != scrubbedYear { feedback.selectionChanged() }
                scrubbedYear = year
            #endif
        }

        // MARK: State

        /// The grid scrolled. `userInitiated`: the user scrolls it (not a jump to a photo, not a relayout), so the
        /// scrubber appears.
        func scrolled(to position: Double, label: String, userInitiated: Bool) {
            guard !isScrubbing else { return }
            if position != self.position || label != positionLabel {
                self.position = position
                positionLabel = label
                accessibilityValue = label
                setNeedsDisplay()
            }
            guard userInitiated else { return }
            reveal()
            scheduleHide()
        }

        private func reveal() {
            hideTask?.cancel()
            guard alpha < 1 else { return }
            if UIAccessibility.isReduceMotionEnabled {
                alpha = 1
            } else {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.alpha = 1 }
            }
        }

        private func scheduleHide() {
            hideTask?.cancel()
            guard !isScrubbing, !UIAccessibility.isVoiceOverRunning else { return }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, !self.isScrubbing else { return }
                if UIAccessibility.isReduceMotionEnabled {
                    self.alpha = 0
                } else {
                    UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.alpha = 0
                    }
                }
            }
        }

        /// VoiceOver finds the scrubber only while it is shown: with VoiceOver on it stays.
        @objc private func accessibilityChanged() {
            if UIAccessibility.isVoiceOverRunning {
                hideTask?.cancel()
                alpha = 1
            } else if !isScrubbing {
                scheduleHide()
            }
        }

        // MARK: Accessibility

        override func accessibilityIncrement() { onStep?(1) }
        override func accessibilityDecrement() { onStep?(-1) }

        // MARK: Drawing

        private var tickFont: UIFont {
            UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), maximumPointSize: 20)
        }

        private var bubbleFont: UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold), maximumPointSize: 24)
        }

        override func draw(_ rect: CGRect) {
            let track = track
            let handleY = CGFloat(track.y(for: position))
            let right = bounds.maxX - Self.stripWidth - 2
            // Opaque with Increase Contrast or Reduce Transparency, so the tiles behind do not show through the labels.
            let opaque = traitCollection.accessibilityContrast == .high || UIAccessibility.isReduceTransparencyEnabled
            let pillColor = UIColor.systemBackground.withAlphaComponent(opaque ? 1 : 0.85)
            let bubbleText = positionLabel

            let font = tickFont
            let tickAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            let tickHeight = font.lineHeight + 4
            let bubbleHeight = bubbleFont.lineHeight + 8
            let positions: [Double] = ticks.map { (tick: Tick) -> Double in track.y(for: tick.fraction) }
            let shown: [Int] = GridScrubberTrack.visibleLabels(
                at: positions, spacing: Double(tickHeight + 4), bubbleY: bubbleText.isEmpty ? nil : Double(handleY),
                clearance: Double((tickHeight + bubbleHeight) / 2 + 2))
            for index in shown {
                let text = NSAttributedString(string: ticks[index].label, attributes: tickAttributes)
                let size = text.size()
                let tickY = CGFloat(positions[index])
                let pill = CGRect(x: right - size.width - 12, y: tickY - tickHeight / 2, width: size.width + 12, height: tickHeight)
                pillColor.setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
                text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
            }

            // The handle, where the scroll indicator would be.
            let handle = CGRect(x: bounds.maxX - 10, y: handleY - 22, width: 6, height: 44)
            (isScrubbing ? tintColor : UIColor.secondaryLabel)?.setFill()
            UIBezierPath(roundedRect: handle, cornerRadius: 3).fill()

            guard !bubbleText.isEmpty else { return }
            let text = NSAttributedString(string: bubbleText, attributes: [.font: bubbleFont, .foregroundColor: UIColor.white])
            let size = text.size()
            var bubble = CGRect(
                x: max(right - size.width - 18, 2), y: handleY - bubbleHeight / 2, width: size.width + 18, height: bubbleHeight)
            bubble.origin.y = min(max(bubble.origin.y, 2), bounds.maxY - bubble.height - 2)
            tintColor.setFill()
            UIBezierPath(roundedRect: bubble, cornerRadius: bubble.height / 2).fill()
            text.draw(at: CGPoint(x: bubble.minX + 9, y: bubble.minY + 4))
        }
    }
#endif
