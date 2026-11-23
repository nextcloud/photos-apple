// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit

    /// Date scrubber at the trailing edge of the Mac grid (SPEC §6.4): year labels along the scroller, a month label
    /// that follows the pointer or the scroll position, and click or drag to jump.
    ///
    /// It only takes the mouse in a narrow strip at the edge, so the tiles below its labels stay clickable. The labels
    /// appear while the pointer is in the strip or the grid scrolls, and fade out afterwards.
    final class GridScrubberView: NSView {
        struct Tick: Equatable {
            /// Position along the track, 0 (newest) … 1 (oldest).
            var fraction: Double
            var label: String
        }

        /// Width of the whole view (room for the labels).
        static let width: CGFloat = 150
        /// Width of the strip that reacts to the mouse.
        static let stripWidth: CGFloat = 18
        private static let inset: CGFloat = 10

        var ticks: [Tick] = [] {
            didSet { if ticks != oldValue { needsDisplay = true } }
        }
        /// Month label for a position along the track.
        var labelAt: ((Double) -> String)?
        /// The user clicked or dragged to a position along the track.
        var onScrub: ((Double) -> Void)?
        /// Accessibility: jump to the next (+1, older) or previous (−1) year.
        var onStep: ((Int) -> Void)?

        private var position = 0.0
        private var positionLabel = ""
        private var hoverFraction: Double?
        private var isDragging = false
        private var hideTimer: Timer?
        private var tracking: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            alphaValue = 0
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityLabel(String(localized: "Timeline position", bundle: .module))
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        private var strip: NSRect {
            NSRect(x: bounds.maxX - Self.stripWidth, y: 0, width: Self.stripWidth, height: bounds.height)
        }

        private var trackHeight: CGFloat { max(bounds.height - 2 * Self.inset, 1) }

        private func y(for fraction: Double) -> CGFloat {
            Self.inset + CGFloat(min(max(fraction, 0), 1)) * trackHeight
        }

        private func fraction(at point: NSPoint) -> Double {
            Double(min(max((point.y - Self.inset) / trackHeight, 0), 1))
        }

        // MARK: Mouse

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, let superview else { return nil }
            return strip.contains(convert(point, from: superview)) ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: strip, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { hover(event) }
        override func mouseMoved(with event: NSEvent) { hover(event) }

        override func mouseExited(with event: NSEvent) {
            hoverFraction = nil
            needsDisplay = true
            scheduleHide()
        }

        private func hover(_ event: NSEvent) {
            hoverFraction = fraction(at: convert(event.locationInWindow, from: nil))
            reveal()
        }

        override func mouseDown(with event: NSEvent) {
            isDragging = true
            scrub(event)
        }

        override func mouseDragged(with event: NSEvent) { scrub(event) }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            scheduleHide()
        }

        private func scrub(_ event: NSEvent) {
            let fraction = fraction(at: convert(event.locationInWindow, from: nil))
            hoverFraction = fraction
            reveal()
            onScrub?(fraction)
        }

        // MARK: State

        /// The grid scrolled: show where it is now.
        func scrolled(to position: Double, label: String) {
            guard position != self.position || label != positionLabel else { return }
            self.position = position
            positionLabel = label
            setAccessibilityValue(label)
            reveal()
            scheduleHide()
        }

        private func reveal() {
            hideTimer?.invalidate()
            needsDisplay = true
            guard alphaValue < 1 else { return }
            // Reduce Motion: the labels appear and go without a fade.
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { alphaValue = 1 } else { animator().alphaValue = 1 }
        }

        private func scheduleHide() {
            hideTimer?.invalidate()
            guard hoverFraction == nil, !isDragging else { return }
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hoverFraction == nil, !self.isDragging else { return }
                    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        self.alphaValue = 0
                        return
                    }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.35
                        self.animator().alphaValue = 0
                    }
                }
            }
        }

        // MARK: Accessibility

        override func accessibilityPerformIncrement() -> Bool {
            onStep?(1)
            return onStep != nil
        }

        override func accessibilityPerformDecrement() -> Bool {
            onStep?(-1)
            return onStep != nil
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            let bubbleFraction = hoverFraction ?? position
            let bubbleText = hoverFraction.flatMap { labelAt?($0) } ?? positionLabel
            let bubbleY = y(for: bubbleFraction)
            let right = bounds.maxX - Self.stripWidth - 2

            let tickAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            // Opaque with Increase Contrast or Reduce Transparency, so the tiles behind do not show through the labels.
            let workspace = NSWorkspace.shared
            let opaque = workspace.accessibilityDisplayShouldIncreaseContrast || workspace.accessibilityDisplayShouldReduceTransparency
            var lastY = -CGFloat.infinity
            for tick in ticks {
                let tickY = y(for: tick.fraction)
                // Year labels that would run into each other or into the month label are left out.
                guard tickY - lastY >= 18, bubbleText.isEmpty || abs(tickY - bubbleY) >= 22 else { continue }
                lastY = tickY
                let text = NSAttributedString(string: tick.label, attributes: tickAttributes)
                let size = text.size()
                let pill = NSRect(
                    x: right - size.width - 12, y: tickY - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
                NSColor.windowBackgroundColor.withAlphaComponent(opaque ? 1 : 0.8).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                text.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2))
            }

            // Where the pointer or the scroll position is.
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bounds.maxX - Self.stripWidth + 3, y: bubbleY - 1.5, width: Self.stripWidth - 6, height: 3),
                xRadius: 1.5, yRadius: 1.5
            ).fill()

            guard !bubbleText.isEmpty else { return }
            let text = NSAttributedString(
                string: bubbleText,
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            let size = text.size()
            var bubble = NSRect(
                x: right - size.width - 18, y: bubbleY - size.height / 2 - 4, width: size.width + 18, height: size.height + 8)
            bubble.origin.y = min(max(bubble.origin.y, 2), bounds.maxY - bubble.height - 2)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bubble, xRadius: bubble.height / 2, yRadius: bubble.height / 2).fill()
            text.draw(at: NSPoint(x: bubble.minX + 9, y: bubble.minY + 4))
        }
    }
#endif
