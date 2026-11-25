// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
    import PhotosCore
    import PhotosModel
    import PhotosStore
    import UIKit
    import UIKit.UIGestureRecognizerSubclass

    /// What the grid gestures need from the grid (`PhotoGridController`).
    @MainActor
    protocol GridGestureHost: AnyObject {
        var gestureCollectionView: UICollectionView { get }
        var model: GridModel { get }
        var gestureIsSelecting: Bool { get }
        var services: AccountServices { get }
        var squareTiles: Bool { get }
        /// The selection as the grid has it now.
        func currentSelection() -> Set<FileID>
        /// Selects or deselects tiles by flat index, and tells the screen.
        func applyRangeChanges(_ changes: [(index: Int, selected: Bool)])
    }

    extension GridGestureHost {
        /// Flat index of the tile at a point of the collection view; nil between tiles, on headers and placeholders.
        func tileIndex(at point: CGPoint) -> Int? {
            guard let indexPath = gestureCollectionView.indexPathForItem(at: point) else { return nil }
            return model.flatIndex(section: indexPath.section, item: indexPath.item)
        }

        func fileId(ofIndex index: Int) -> FileID? {
            model.items.indices.contains(index) ? model.items[index].fileId : nil
        }

        func indexPath(ofIndex index: Int) -> IndexPath? {
            model.position(ofIndex: index).map { IndexPath(item: $0.item, section: $0.section) }
        }
    }

    // MARK: - Range selection (SPEC §16.1)

    /// In the selection mode, a finger that slides sideways over the tiles selects the range from the tile it started on
    /// to the tile under it (or deselects, when it started on a selected one), as in Photos; dragged to the top or bottom
    /// edge, the grid scrolls on. A vertical move still scrolls. Two fingers start the system's own multi-selection.
    @MainActor
    final class GridRangeSelector: NSObject, UIGestureRecognizerDelegate {
        private weak var host: (any GridGestureHost)?
        let pan = UIPanGestureRecognizer()
        private var range: GridRangeSelection?
        private var link: CADisplayLink?
        private var lastTick: CFTimeInterval = 0

        init(host: any GridGestureHost) {
            self.host = host
            super.init()
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pan.addTarget(self, action: #selector(handle(_:)))
            host.gestureCollectionView.addGestureRecognizer(pan)
        }

        var isActive: Bool { range != nil }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host, host.gestureIsSelecting else { return false }
            return host.tileIndex(at: touch.location(in: host.gestureCollectionView)) != nil
        }

        /// Only a sideways start: up and down is scrolling.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let host else { return false }
            let velocity = pan.velocity(in: host.gestureCollectionView)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// The grid's scrolling waits until this has decided (it only takes touches on tiles while selecting).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer === host?.gestureCollectionView.panGestureRecognizer
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            guard let host else { return }
            let collectionView = host.gestureCollectionView
            switch gesture.state {
            case .began:
                let location = gesture.location(in: collectionView)
                let translation = gesture.translation(in: collectionView)
                let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                guard let anchor = host.tileIndex(at: start) ?? host.tileIndex(at: location), let anchorId = host.fileId(ofIndex: anchor)
                else {
                    gesture.state = .failed
                    return
                }
                let selection = GridRangeSelection(anchor: anchor, anchorId: anchorId, base: host.currentSelection())
                range = selection
                host.applyRangeChanges(selection.start { host.fileId(ofIndex: $0) })
                follow(location)
                startAutoscroll()
            case .changed:
                follow(gesture.location(in: collectionView))
            default:
                stopAutoscroll()
                range = nil
            }
        }

        /// The tile under the finger is the end of the range now.
        private func follow(_ location: CGPoint) {
            guard let host, var range, let index = host.tileIndex(at: location) else { return }
            let changes = range.move(to: index) { host.fileId(ofIndex: $0) }
            self.range = range
            if !changes.isEmpty { host.applyRangeChanges(changes) }
        }

        private func startAutoscroll() {
            guard link == nil, host != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            lastTick = 0
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        private func stopAutoscroll() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard let collectionView = host?.gestureCollectionView, range != nil else { return }
            let elapsed = lastTick == 0 ? 0 : min(link.timestamp - lastTick, 0.05)
            lastTick = link.timestamp
            let insets = collectionView.adjustedContentInset
            let y = pan.location(in: collectionView).y - collectionView.contentOffset.y
            let speed = GridAutoscroll.speed(
                y: Double(y), top: Double(insets.top), bottom: Double(collectionView.bounds.height - insets.bottom))
            guard speed != 0, elapsed > 0 else { return }
            let maximum = max(collectionView.contentSize.height + insets.bottom - collectionView.bounds.height, -insets.top)
            let offset = min(max(collectionView.contentOffset.y + CGFloat(speed * elapsed), -insets.top), maximum)
            guard offset != collectionView.contentOffset.y else { return }
            collectionView.contentOffset.y = offset
            follow(pan.location(in: collectionView))
        }
    }

    // MARK: - Scrub to peek (SPEC §16.1)

    /// A finger held on a tile for a moment and then slid sideways: the scrub of a peek. A quicker move fails it (the
    /// grid scrolls), a finger that stays still fails it after `GridPeek.slideWindow` and lets the context menu come.
    final class GridHoldSlideRecognizer: UIGestureRecognizer {
        private(set) var startLocation: CGPoint = .zero
        private var startTime: TimeInterval = 0
        private var timeout: DispatchWorkItem?

        override func reset() {
            super.reset()
            timeout?.cancel()
            timeout = nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            guard touches.count == 1, numberOfTouches == 1, let touch = touches.first else {
                state = .failed
                return
            }
            startLocation = touch.location(in: view)
            startTime = touch.timestamp
            // Held still: not a scrub. The context menu (which waits for this) comes.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    if let self, self.state == .possible { self.state = .failed }
                }
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + GridPeek.slideWindow, execute: work)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesMoved(touches, with: event)
            guard let touch = touches.first else { return }
            let point = touch.location(in: view)
            let dx = point.x - startLocation.x
            let dy = point.y - startLocation.y
            switch state {
            case .possible:
                guard touch.timestamp - startTime >= GridPeek.holdDuration else {
                    if hypot(dx, dy) > 10 { state = .failed }
                    return
                }
                if abs(dx) > 6, abs(dx) >= abs(dy) {
                    state = .began
                } else if abs(dy) > 12 {
                    state = .failed
                }
            case .began, .changed:
                state = .changed
            default:
                break
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            state = state == .began || state == .changed ? .ended : .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            state = state == .began || state == .changed ? .cancelled : .failed
        }
    }

    /// Peeks into videos, Live Photos and stacks in place: frames (or copies) follow the finger or the pointer across the
    /// tile, with a bar that says where in the video it is. Nothing opens; leaving the tile ends it and stops loading.
    @MainActor
    final class GridPeekPresenter: NSObject, UIGestureRecognizerDelegate {
        private weak var host: (any GridGestureHost)?
        let hold = GridHoldSlideRecognizer()
        private let hover = UIHoverGestureRecognizer()
        private let overlay = GridPeekOverlayView()
        private let cache = GridPeekCache()
        private var loader: GridPeekLoader?
        private var tile: IndexPath?
        private var fraction = 0.0
        private var hoverTask: Task<Void, Never>?
        /// The Live Photo tile under the pointer, whose badge plays.
        private var hoveredLive: IndexPath?

        init(host: any GridGestureHost) {
            self.host = host
            super.init()
            let collectionView = host.gestureCollectionView
            hold.delegate = self
            hold.addTarget(self, action: #selector(handleHold(_:)))
            collectionView.addGestureRecognizer(hold)
            // Pointer on iPad (trackpad, mouse); Vision Pro does not tell apps where the eyes are.
            hover.addTarget(self, action: #selector(handleHover(_:)))
            collectionView.addGestureRecognizer(hover)
            overlay.isHidden = true
            overlay.isUserInteractionEnabled = false
            overlay.layer.zPosition = 50
            collectionView.addSubview(overlay)
        }

        var isPeeking: Bool { loader != nil }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host, !host.gestureIsSelecting else { return false }
            return peekable(at: touch.location(in: host.gestureCollectionView)) != nil
        }

        /// Scrolling, the context menu and the drag of a tile wait until this has decided (it only takes touches on tiles
        /// with something to peek into, and decides within `GridPeek.slideWindow`): a held finger that slides scrubs.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let collectionView = host?.gestureCollectionView else { return false }
            if otherGestureRecognizer === collectionView.panGestureRecognizer { return true }
            return otherGestureRecognizer.view === collectionView && !(otherGestureRecognizer is UIPinchGestureRecognizer)
                && !(otherGestureRecognizer is UIHoverGestureRecognizer) && !(otherGestureRecognizer is UIPanGestureRecognizer)
                && !(otherGestureRecognizer is GridHoldSlideRecognizer)
        }

        /// The tile at a point when there is something to peek into.
        private func peekable(at point: CGPoint) -> (indexPath: IndexPath, item: GridMedia, kind: GridPeekKind)? {
            guard let host, let indexPath = host.gestureCollectionView.indexPathForItem(at: point),
                let item = host.model.item(section: indexPath.section, item: indexPath.item), let kind = GridPeekKind(item)
            else { return nil }
            return (indexPath, item, kind)
        }

        @objc private func handleHold(_ gesture: GridHoldSlideRecognizer) {
            guard let host else { return }
            let location = gesture.location(in: host.gestureCollectionView)
            switch gesture.state {
            case .began:
                hoverTask?.cancel()
                guard let target = peekable(at: gesture.startLocation) else { return }
                begin(target)
                move(to: location)
            case .changed:
                move(to: location)
            default:
                end()
            }
        }

        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let host, !host.gestureIsSelecting else {
                end()
                return
            }
            switch gesture.state {
            case .began, .changed:
                let location = gesture.location(in: host.gestureCollectionView)
                let target = peekable(at: location)
                setHoveredLive(target?.kind == .livePhoto ? target?.indexPath : nil)
                if let tile, target?.indexPath == tile {
                    move(to: location)
                    return
                }
                end()
                guard let target else { return }
                // Passing over tiles loads nothing: only a pointer that rests on one starts a peek.
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: GridPeek.hoverDelay)
                    guard !Task.isCancelled, let self, let host = self.host else { return }
                    let now = gesture.location(in: host.gestureCollectionView)
                    guard self.peekable(at: now)?.indexPath == target.indexPath else { return }
                    self.begin(target)
                    self.move(to: now)
                }
            default:
                setHoveredLive(nil)
                end()
            }
        }

        /// The Live badge of the tile under the pointer comes alive (SPEC §17.2).
        private func setHoveredLive(_ indexPath: IndexPath?) {
            guard indexPath != hoveredLive, let collectionView = host?.gestureCollectionView else { return }
            if let hoveredLive { (collectionView.cellForItem(at: hoveredLive) as? PhotoCell)?.setLiveActive(false) }
            hoveredLive = indexPath
            if let indexPath { (collectionView.cellForItem(at: indexPath) as? PhotoCell)?.setLiveActive(true) }
        }

        private func begin(_ target: (indexPath: IndexPath, item: GridMedia, kind: GridPeekKind)) {
            end()
            guard let host, let attributes = host.gestureCollectionView.layoutAttributesForItem(at: target.indexPath) else { return }
            tile = target.indexPath
            // The Live badge plays along while the motion is scrubbed (SPEC §17.2).
            if target.kind == .livePhoto {
                (host.gestureCollectionView.cellForItem(at: target.indexPath) as? PhotoCell)?.setLiveActive(true)
            }
            let picture = GridTile.pictureFrame(in: attributes.frame, aspectRatio: target.item.aspectRatio, square: host.squareTiles)
            overlay.frame = picture
            overlay.show(kind: target.kind)
            overlay.isHidden = false
            let loader = GridPeekLoader(item: target.item, kind: target.kind, cached: cache.frames(for: target.item))
            loader.changed = { [weak self] in self?.redraw() }
            self.loader = loader
            let scale = host.gestureCollectionView.traitCollection.displayScale
            let pixels = Int((max(picture.width, picture.height) * min(scale, 2)).rounded())
            loader.start(services: host.services, pixels: max(pixels, 64), fraction: fraction)
        }

        private func move(to location: CGPoint) {
            guard tile != nil, let host else { return }
            fraction = GridPeek.fraction(
                x: Double(location.x), in: overlay.frame,
                rightToLeft: host.gestureCollectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            redraw()
        }

        private func redraw() {
            guard let loader else { return }
            let picture = loader.picture(at: fraction)
            overlay.update(image: picture.image, fraction: fraction, index: picture.index)
        }

        /// The peek is over (the finger or pointer left, the grid scrolled or changed): its frames stay in the cache.
        func end() {
            hoverTask?.cancel()
            hoverTask = nil
            if let loader {
                loader.cancel()
                cache.store(loader)
            }
            loader = nil
            if let tile, let host { (host.gestureCollectionView.cellForItem(at: tile) as? PhotoCell)?.setLiveActive(false) }
            tile = nil
            overlay.isHidden = true
            overlay.update(image: nil, fraction: 0, index: 0)
        }
    }

    /// The picture of a peek over its tile, with a bar along the bottom: how far into the video, or which copy.
    final class GridPeekOverlayView: UIView {
        private let picture = CALayer()
        private let bar = GridPeekBarLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            picture.contentsGravity = .resizeAspectFill
            picture.masksToBounds = true
            layer.addSublayer(picture)
            layer.addSublayer(bar)
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.frame = bounds
            bar.frame = CGRect(x: 6, y: bounds.height - 9, width: max(bounds.width - 12, 0), height: 3)
            bar.layout()
            CATransaction.commit()
        }

        func show(kind: GridPeekKind) {
            bar.segments = kind.segments
            picture.contents = nil
            setNeedsLayout()
        }

        func update(image: CGImage?, fraction: Double, index: Int) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let image { picture.contents = image } else if fraction == 0, index == 0 { picture.contents = nil }
            bar.set(fraction: fraction, index: index)
            CATransaction.commit()
        }
    }
#endif

#if canImport(UIKit) || canImport(AppKit)
    import QuartzCore

    /// The bar of a peek: a track with how far into the video (or, for a stack, one segment per copy).
    final class GridPeekBarLayer: CALayer {
        private let track = CALayer()
        private let fill = CALayer()
        private var pieces: [CALayer] = []
        var segments = 0 {
            didSet {
                guard segments != oldValue else { return }
                pieces.forEach { $0.removeFromSuperlayer() }
                pieces = (0..<segments).map { _ in
                    let piece = CALayer()
                    piece.cornerRadius = 1.5
                    addSublayer(piece)
                    return piece
                }
                track.isHidden = segments > 0
                fill.isHidden = segments > 0
                layout()
            }
        }
        private var fraction = 0.0
        private var index = 0

        override init() {
            super.init()
            setUp()
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) { fatalError() }

        private func setUp() {
            shadowColor = CGColor(gray: 0, alpha: 1)
            shadowOpacity = 0.45
            shadowRadius = 1.5
            shadowOffset = .zero
            for part in [track, fill] {
                part.cornerRadius = 1.5
                addSublayer(part)
            }
            track.backgroundColor = CGColor(gray: 1, alpha: 0.4)
            fill.backgroundColor = CGColor(gray: 1, alpha: 1)
        }

        func layout() {
            track.frame = bounds
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(max(fraction, 0), 1)), height: bounds.height)
            guard segments > 0 else { return }
            let gap: CGFloat = 2
            let width = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            for (offset, piece) in pieces.enumerated() {
                piece.frame = CGRect(x: CGFloat(offset) * (width + gap), y: 0, width: max(width, 1), height: bounds.height)
                piece.backgroundColor = CGColor(gray: 1, alpha: offset == index ? 1 : 0.4)
            }
        }

        func set(fraction: Double, index: Int) {
            self.fraction = fraction
            self.index = index
            layout()
        }
    }
#endif
