// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// What a zoom view tells the viewer.
@MainActor
struct ZoomSurfaceEvents {
    /// The zoom scale changed (reported when a gesture ends and whenever "zoomed" or "needs more pixels" flips).
    var scaleChanged: (CGFloat) -> Void = { _ in }
    /// A single tap or click on the photo.
    var tapped: () -> Void = {}
    /// A long press began or ended (Live Photos).
    var pressing: (Bool) -> Void = { _ in }
    /// A vertical swipe on the photo while it is not zoomed (iPhone, iPad).
    var verticalDrag: (ViewerSwipe.Phase) -> Void = { _ in }
}

// A photo in a real zooming scroll view (SPEC VW-1): `UIScrollView` on iOS and visionOS, `NSScrollView` with
// magnification on the Mac. The system does what a scale effect cannot: zoom around the fingers or the pointer,
// keep the photo inside the page, rubber-band, pan with two fingers on a trackpad.
//
// Both take the same input:
// - `image`: the picture to show (a preview, later a larger one of the same shape);
// - `contentSize`: its shape, known before the first image arrives;
// - `command`: Zoom In / Zoom Out / Zoom to Fit from the menu bar, carried out by the page that is shown;
// - `isCurrent`: a page that is paged away goes back to the fitted size;
// - `liveText`: the photo shown may be analysed for Live Text and Visual Look Up (`LiveTextPolicy`).

#if canImport(UIKit)
    import UIKit

    struct ZoomSurface: UIViewRepresentable {
        var image: CGImage?
        var contentSize: CGSize
        var command: ViewerZoomCommand?
        var isCurrent: Bool
        var animates: Bool
        var pressEnabled: Bool
        var liveText = false
        var events: ZoomSurfaceEvents

        final class Coordinator {
            var lastCommand: Int?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> ZoomScrollView {
            let view = ZoomScrollView()
            context.coordinator.lastCommand = command?.id
            return view
        }

        func updateUIView(_ view: ZoomScrollView, context: Context) {
            view.events = events
            view.animates = animates
            view.pressEnabled = pressEnabled
            view.show(image, contentSize: contentSize)
            if !isCurrent { view.resetZoom() }
            view.updateLiveText(enabled: liveText)
            // Every page sees the command; only the one on screen carries it out.
            if let command, command.id != context.coordinator.lastCommand, isCurrent { view.apply(command) }
            context.coordinator.lastCommand = command?.id
        }
    }

    final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
        var events = ZoomSurfaceEvents()
        var animates = true
        var pressEnabled = false {
            didSet { press.isEnabled = pressEnabled }
        }

        private let imageView = UIImageView()
        private var shownImage: CGImage?
        private var shape: CGSize = .zero
        private var laidOutSize: CGSize = .zero
        private var reportedScale: CGFloat = ViewerZoom.minimumScale
        private let press = UILongPressGestureRecognizer()
        #if os(iOS)
            private var swipe: VerticalSwipe?
        #endif
        private var liveText: LiveTextInteraction?

        init() {
            super.init(frame: .zero)
            delegate = self
            minimumZoomScale = ViewerZoom.minimumScale
            maximumZoomScale = ViewerZoom.maximumScale
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            backgroundColor = .clear
            // The frame has the photo's shape, so filling it never distorts; a BlurHash placeholder is stretched to it.
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            addSubview(imageView)
            liveText = LiveTextInteraction(on: imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.require(toFail: doubleTap)
            addGestureRecognizer(tap)
            press.minimumPressDuration = 0.3
            press.addTarget(self, action: #selector(pressed(_:)))
            press.isEnabled = false
            addGestureRecognizer(press)
            #if os(iOS)
                swipe = VerticalSwipe(
                    view: self,
                    isAllowed: { [weak self] in
                        guard let self else { return false }
                        return !ViewerZoom.isZoomed(self.zoomScale)
                    },
                    handler: { [weak self] phase in self?.events.verticalDrag(phase) })
            #endif
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // MARK: Content

        func show(_ image: CGImage?, contentSize: CGSize) {
            if image !== shownImage {
                shownImage = image
                imageView.image = image.map { UIImage(cgImage: $0) }
            }
            guard !Self.sameShape(contentSize, shape) else { return }
            shape = contentSize
            refit()
        }

        static func sameShape(_ first: CGSize, _ second: CGSize) -> Bool {
            guard first.height > 0, second.height > 0 else { return first == second }
            return abs(first.width / first.height - second.width / second.height) < 0.01
        }

        /// Analyses the picture shown for Live Text while `enabled`; otherwise the analysis stops and its result goes.
        func updateLiveText(enabled: Bool) {
            liveText?.update(image: shownImage, enabled: enabled)
        }

        private func layoutLiveText() {
            liveText?.layout(visible: bounds.inset(by: safeAreaInsets), zoomed: ViewerZoom.isZoomed(zoomScale))
        }

        /// The photo fitted into the page, at scale 1.
        private func refit() {
            if zoomScale != ViewerZoom.minimumScale { zoomScale = ViewerZoom.minimumScale }
            let fitted: CGSize = ViewerZoom.fittedSize(content: shape, in: bounds.size)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            center()
            report(force: true)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != laidOutSize {
                laidOutSize = bounds.size
                refit()
            }
            center()
            layoutLiveText()
        }

        /// Keeps a photo that is smaller than the page in its middle (as in Apple's PhotoScroller sample).
        private func center() {
            let origin: CGPoint = ViewerZoom.centeredOrigin(content: imageView.frame.size, bounds: bounds.size)
            if imageView.frame.origin != origin { imageView.frame.origin = origin }
        }

        // MARK: Zoom

        func resetZoom() {
            guard zoomScale != ViewerZoom.minimumScale else { return }
            setZoomScale(ViewerZoom.minimumScale, animated: false)
            report(force: true)
        }

        func apply(_ command: ViewerZoomCommand) {
            let middle: CGPoint = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: imageView)
            zoom(to: command.target(from: zoomScale), around: middle)
        }

        /// `point` is in the photo's own coordinates.
        private func zoom(to scale: CGFloat, around point: CGPoint) {
            guard ViewerZoom.isZoomed(scale) else {
                setZoomScale(ViewerZoom.minimumScale, animated: animates)
                if !animates { report(force: true) }
                return
            }
            let rect: CGRect = ViewerZoom.zoomRect(scale: scale, around: point, content: imageView.bounds.size, bounds: bounds.size)
            zoom(to: rect, animated: animates)
            if !animates { report(force: true) }
        }

        private func report(force: Bool = false) {
            let scale: CGFloat = zoomScale
            let flipped: Bool =
                ViewerZoom.isZoomed(scale) != ViewerZoom.isZoomed(reportedScale)
                || (scale >= ViewerZoom.highResolutionScale) != (reportedScale >= ViewerZoom.highResolutionScale)
            guard flipped || (force && scale != reportedScale) else { return }
            reportedScale = scale
            events.scaleChanged(scale)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
            report()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            report(force: true)
            layoutLiveText()
        }

        // MARK: Gestures

        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            zoom(to: ViewerZoom.doubleTapTarget(from: zoomScale), around: recognizer.location(in: imageView))
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            // A tap on text, a link or the Live Text button is Live Text's, not a request to hide the bars.
            if liveText?.claims(recognizer.location(in: imageView)) == true { return }
            events.tapped()
        }

        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began, liveText?.claims(recognizer.location(in: imageView)) == true { return }
            switch recognizer.state {
            case .began: events.pressing(true)
            case .ended, .cancelled, .failed: events.pressing(false)
            default: break
            }
        }
    }

    #if os(iOS)
        /// A pan that only takes drags which start up or down, for "swipe down to close" and "swipe up for info".
        ///
        /// It has a delegate of its own, so the scroll view it sits on keeps the delegate methods it implements for
        /// its own recognizers. The pager around the page waits for this recognizer to fail, which it does at once
        /// for a sideways drag — paging is not delayed, and a vertical drag never pages.
        @MainActor
        final class VerticalSwipe: NSObject, UIGestureRecognizerDelegate {
            private let recognizer = UIPanGestureRecognizer()
            private let isAllowed: () -> Bool
            private let handler: (ViewerSwipe.Phase) -> Void
            /// Leaves touches on controls (a video scrubber, buttons) alone.
            var ignoresControls = false

            init(view: UIView, isAllowed: @escaping () -> Bool, handler: @escaping (ViewerSwipe.Phase) -> Void) {
                self.isAllowed = isAllowed
                self.handler = handler
                super.init()
                recognizer.maximumNumberOfTouches = 1
                recognizer.addTarget(self, action: #selector(panned(_:)))
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }

            @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
                // In window coordinates: the page itself moves with the finger.
                let translation: CGFloat = recognizer.translation(in: nil).y
                switch recognizer.state {
                case .began, .changed: handler(.changed(translation: translation))
                case .ended: handler(.ended(translation: translation, velocity: recognizer.velocity(in: nil).y))
                case .cancelled, .failed: handler(.cancelled)
                default: break
                }
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard isAllowed() else { return false }
                return ViewerSwipe.isVertical(velocity: recognizer.velocity(in: nil))
            }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                !(ignoresControls && touch.view is UIControl)
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool {
                // The pans of the scroll views around this page (the pager), not those inside it.
                guard otherGestureRecognizer is UIPanGestureRecognizer, let scrollView = otherGestureRecognizer.view as? UIScrollView,
                    let own = recognizer.view
                else { return false }
                return scrollView !== own && own.isDescendant(of: scrollView)
            }
        }
    #endif

#elseif canImport(AppKit)
    import AppKit

    struct ZoomSurface: NSViewRepresentable {
        var image: CGImage?
        var contentSize: CGSize
        var command: ViewerZoomCommand?
        var isCurrent: Bool
        var animates: Bool
        var pressEnabled: Bool
        var liveText = false
        var events: ZoomSurfaceEvents

        final class Coordinator {
            var lastCommand: Int?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> MacZoomView {
            let view = MacZoomView()
            context.coordinator.lastCommand = command?.id
            return view
        }

        func updateNSView(_ view: MacZoomView, context: Context) {
            view.events = events
            view.animates = animates
            view.pressEnabled = pressEnabled
            view.show(image, contentSize: contentSize)
            if !isCurrent { view.resetZoom() }
            view.updateLiveText(enabled: liveText)
            // Every page sees the command; only the one on screen carries it out.
            if let command, command.id != context.coordinator.lastCommand, isCurrent { view.apply(command) }
            context.coordinator.lastCommand = command?.id
        }
    }

    /// Centres a photo that is smaller than the page, which a plain clip view pins to a corner.
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect: NSRect = super.constrainBoundsRect(proposedBounds)
            guard let document = documentView else { return rect }
            rect.origin = ViewerZoom.clampedOffset(proposedBounds.origin, content: document.frame.size, bounds: rect.size)
            return rect
        }
    }

    final class MacZoomView: NSScrollView, NSGestureRecognizerDelegate {
        var events = ZoomSurfaceEvents()
        var animates = true
        var pressEnabled = false {
            didSet { press.isEnabled = pressEnabled }
        }

        private let photo = NSView()
        private var shownImage: CGImage?
        private var shape: CGSize = .zero
        private var laidOutSize: CGSize = .zero
        private var reportedScale: CGFloat = ViewerZoom.minimumScale
        private let press = NSPressGestureRecognizer()
        private let drag = NSPanGestureRecognizer()
        private var liveText: LiveTextOverlay?

        init() {
            super.init(frame: .zero)
            let clip = CenteringClipView()
            clip.drawsBackground = false
            contentView = clip
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = false
            automaticallyAdjustsContentInsets = false
            allowsMagnification = true
            minMagnification = ViewerZoom.minimumScale
            maxMagnification = ViewerZoom.maximumScale
            photo.wantsLayer = true
            // The frame has the photo's shape, so filling it never distorts; a BlurHash placeholder is stretched to it.
            photo.layer?.contentsGravity = .resize
            documentView = photo
            liveText = LiveTextOverlay(over: photo)

            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
            doubleClick.numberOfClicksRequired = 2
            doubleClick.delaysPrimaryMouseButtonEvents = false
            addGestureRecognizer(doubleClick)
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            addGestureRecognizer(click)
            press.minimumPressDuration = 0.3
            press.target = self
            press.action = #selector(pressed(_:))
            press.isEnabled = false
            press.delaysPrimaryMouseButtonEvents = false
            addGestureRecognizer(press)
            // A mouse has no two-finger scroll: a zoomed photo can be dragged.
            drag.target = self
            drag.action = #selector(dragged(_:))
            drag.delegate = self
            drag.delaysPrimaryMouseButtonEvents = false
            addGestureRecognizer(drag)

            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(
                self, selector: #selector(magnifyEnded(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // MARK: Content

        func show(_ image: CGImage?, contentSize: CGSize) {
            if image !== shownImage {
                shownImage = image
                photo.layer?.contents = image
            }
            guard !Self.sameShape(contentSize, shape) else { return }
            shape = contentSize
            refit()
        }

        static func sameShape(_ first: CGSize, _ second: CGSize) -> Bool {
            guard first.height > 0, second.height > 0 else { return first == second }
            return abs(first.width / first.height - second.width / second.height) < 0.01
        }

        /// Analyses the picture shown for Live Text while `enabled`; otherwise the analysis stops and its result goes.
        func updateLiveText(enabled: Bool) {
            liveText?.update(image: shownImage, enabled: enabled)
        }

        /// The photo fitted into the page at magnification 1. The magnification is kept: the window was resized or
        /// the info inspector opened, and the user is still looking at the same detail.
        private func refit() {
            let fitted: CGSize = ViewerZoom.fittedSize(content: shape, in: bounds.size)
            photo.frame = NSRect(origin: .zero, size: fitted)
            let constrained: NSRect = contentView.constrainBoundsRect(contentView.bounds)
            contentView.scroll(to: constrained.origin)
            reflectScrolledClipView(contentView)
        }

        override func layout() {
            super.layout()
            if bounds.size != laidOutSize {
                laidOutSize = bounds.size
                refit()
            }
        }

        // MARK: Zoom

        func resetZoom() {
            guard magnification != ViewerZoom.minimumScale else { return }
            magnification = ViewerZoom.minimumScale
            report(force: true)
        }

        func apply(_ command: ViewerZoomCommand) {
            let middle = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
            zoom(to: command.target(from: magnification), around: middle)
        }

        /// `point` is in the photo's own coordinates.
        private func zoom(to scale: CGFloat, around point: NSPoint) {
            guard animates else {
                setMagnification(scale, centeredAt: point)
                report(force: true)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                self.animator().setMagnification(scale, centeredAt: point)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.report(force: true) }
            }
            // The scale is known now; the 4096 px preview can load while the animation runs.
            reportedScale = scale
            events.scaleChanged(scale)
        }

        private func report(force: Bool = false) {
            let scale: CGFloat = magnification
            liveText?.setZoomed(ViewerZoom.isZoomed(scale))
            let flipped: Bool =
                ViewerZoom.isZoomed(scale) != ViewerZoom.isZoomed(reportedScale)
                || (scale >= ViewerZoom.highResolutionScale) != (reportedScale >= ViewerZoom.highResolutionScale)
            guard flipped || (force && scale != reportedScale) else { return }
            reportedScale = scale
            events.scaleChanged(scale)
        }

        @objc private func boundsChanged(_ notification: Notification) {
            report()
        }

        @objc private func magnifyEnded(_ notification: Notification) {
            report(force: true)
        }

        // MARK: Events

        /// A photo that is not zoomed has nothing to scroll: the swipe belongs to the pager around it. A scroll view
        /// keeps scroll events to itself otherwise, and the photos could no longer be paged with the trackpad.
        override func scrollWheel(with event: NSEvent) {
            if ViewerZoom.isZoomed(magnification) {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }

        @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
            zoom(to: ViewerZoom.doubleTapTarget(from: magnification), around: recognizer.location(in: photo))
        }

        @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
            events.tapped()
        }

        @objc private func pressed(_ recognizer: NSPressGestureRecognizer) {
            // Pressing on text selects it; it does not play the Live Photo.
            if recognizer.state == .began, liveText?.claims(recognizer.location(in: photo)) == true { return }
            switch recognizer.state {
            case .began: events.pressing(true)
            case .ended, .cancelled, .failed: events.pressing(false)
            default: break
            }
        }

        @objc private func dragged(_ recognizer: NSPanGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            let translation: NSPoint = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            var bounds: NSRect = contentView.bounds
            bounds.origin.x -= translation.x / magnification
            bounds.origin.y -= translation.y / magnification
            contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
            reflectScrolledClipView(contentView)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard gestureRecognizer === drag else { return true }
            // A drag over text selects it instead of moving the photo.
            return ViewerZoom.isZoomed(magnification) && liveText?.claims(gestureRecognizer.location(in: photo)) != true
        }
    }
#endif
