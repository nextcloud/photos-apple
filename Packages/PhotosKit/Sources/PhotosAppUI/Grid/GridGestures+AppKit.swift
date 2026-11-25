// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosCore
    import PhotosModel
    import PhotosStore

    /// What a peek needs from the Mac grid (`PhotoGridScrollView`).
    @MainActor
    protocol GridPeekHost: AnyObject {
        var collectionView: GridCollectionView { get }
        var model: GridModel { get }
        var services: AccountServices { get }
        var squareTiles: Bool { get }
    }

    /// Scrub to peek on the Mac (SPEC §16.1): the pointer resting on a video, Live Photo or stack shows its frames or
    /// copies in place, following the pointer across the tile. Moving on, scrolling or clicking ends it.
    @MainActor
    final class GridPeekHover: NSResponder {
        private weak var host: (any GridPeekHost)?
        private let overlay = GridPeekOverlayNSView()
        private let cache = GridPeekCache()
        private var loader: GridPeekLoader?
        private var tile: IndexPath?
        private var pending: IndexPath?
        private var fraction = 0.0
        private var hoverTask: Task<Void, Never>?
        /// A peek started (the tile's lift ends, SPEC §17.7).
        var began: (() -> Void)?

        init(host: any GridPeekHost) {
            self.host = host
            super.init()
            let collectionView = host.collectionView
            collectionView.addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
                    userInfo: nil))
            overlay.isHidden = true
            collectionView.addSubview(overlay)
        }

        required init?(coder: NSCoder) { fatalError() }

        var isPeeking: Bool { loader != nil }

        override func mouseMoved(with event: NSEvent) {
            guard let collectionView = host?.collectionView else { return }
            pointer(at: collectionView.convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            end()
        }

        /// The tile under the pointer when there is something to peek into.
        private func peekable(at point: NSPoint) -> (indexPath: IndexPath, item: GridMedia, kind: GridPeekKind)? {
            guard let host, let indexPath = host.collectionView.indexPathForItem(at: point),
                let item = host.model.item(section: indexPath.section, item: indexPath.item), let kind = GridPeekKind(item)
            else { return nil }
            return (indexPath, item, kind)
        }

        private func pointer(at point: NSPoint) {
            let target = peekable(at: point)
            if let tile, target?.indexPath == tile {
                move(to: point)
                return
            }
            if let pending, target?.indexPath == pending { return }
            end()
            guard let target else { return }
            pending = target.indexPath
            // Passing over tiles loads nothing: only a pointer that rests on one starts a peek.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: GridPeek.hoverDelay)
                guard !Task.isCancelled, let self, let host = self.host, let window = host.collectionView.window else { return }
                let now = host.collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                self.pending = nil
                guard self.peekable(at: now)?.indexPath == target.indexPath else { return }
                self.begin(target)
                self.move(to: now)
            }
        }

        private func begin(_ target: (indexPath: IndexPath, item: GridMedia, kind: GridPeekKind)) {
            guard let host, let attributes = host.collectionView.layoutAttributesForItem(at: target.indexPath) else { return }
            tile = target.indexPath
            began?()
            let picture = GridTile.pictureFrame(in: attributes.frame, aspectRatio: target.item.aspectRatio, square: host.squareTiles)
            overlay.frame = picture
            overlay.show(kind: target.kind)
            overlay.isHidden = false
            let loader = GridPeekLoader(item: target.item, kind: target.kind, cached: cache.frames(for: target.item))
            loader.changed = { [weak self] in self?.redraw() }
            self.loader = loader
            let scale = host.collectionView.window?.backingScaleFactor ?? 2
            let pixels = Int((max(picture.width, picture.height) * min(scale, 2)).rounded())
            loader.start(services: host.services, pixels: max(pixels, 64), fraction: fraction)
        }

        private func move(to point: NSPoint) {
            guard tile != nil, let host else { return }
            fraction = GridPeek.fraction(
                x: Double(point.x), in: overlay.frame, rightToLeft: host.collectionView.userInterfaceLayoutDirection == .rightToLeft)
            redraw()
        }

        private func redraw() {
            guard let loader else { return }
            let picture = loader.picture(at: fraction)
            overlay.update(image: picture.image, fraction: fraction, index: picture.index)
        }

        /// The peek is over: loading stops, its frames stay in the cache for the next time.
        func end() {
            hoverTask?.cancel()
            hoverTask = nil
            pending = nil
            if let loader {
                loader.cancel()
                cache.store(loader)
            }
            loader = nil
            tile = nil
            overlay.isHidden = true
            overlay.update(image: nil, fraction: 0, index: 0)
        }
    }

    /// The picture of a peek over its tile, with the bar along the bottom.
    final class GridPeekOverlayNSView: NSView {
        private let picture = CALayer()
        private let bar = GridPeekBarLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.zPosition = 50
            picture.contentsGravity = .resizeAspectFill
            picture.masksToBounds = true
            layer?.addSublayer(picture)
            layer?.addSublayer(bar)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The pointer goes through to the tile below (clicks select, double-clicks open).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.frame = bounds
            // The layer is not flipped: the bar goes along the bottom edge, which is y = 0.
            bar.frame = CGRect(x: 6, y: 6, width: max(bounds.width - 12, 0), height: 3)
            bar.layout()
            CATransaction.commit()
        }

        func show(kind: GridPeekKind) {
            bar.segments = kind.segments
            picture.contents = nil
            needsLayout = true
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
