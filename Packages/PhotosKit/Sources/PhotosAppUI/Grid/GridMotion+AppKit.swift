// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import PhotosModel
    import QuartzCore

    /// The tile under the pointer lifts (SPEC §17.7): its picture grows by a few points and casts a soft shadow, as
    /// things the pointer can act on do on macOS 27. One tracking area for the whole grid; only layer properties of one
    /// tile change (on the GPU, nothing is laid out). Scrolling, a pinch or a peek put it down again; the pointer has to
    /// move before the next tile lifts.
    @MainActor
    final class GridHoverLift: NSResponder {
        private weak var host: (any GridPeekHost)?
        private weak var liftedView: NSView?
        private var liftedPath: IndexPath?
        /// The lifted picture's frame in its tile.
        private var liftedPicture: CGRect = .zero
        /// While a pinch zooms the grid nothing lifts.
        var isSuspended = false {
            didSet { if isSuspended { drop() } }
        }

        init(host: any GridPeekHost) {
            self.host = host
            super.init()
            host.collectionView.addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
                    userInfo: nil))
        }

        required init?(coder: NSCoder) { fatalError() }

        override func mouseMoved(with event: NSEvent) {
            guard !isSuspended, let collectionView = host?.collectionView else { return }
            pointer(at: collectionView.convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            drop()
        }

        #if DEBUG
            func debugPointer(at point: NSPoint) { pointer(at: point) }
        #endif

        private func pointer(at point: NSPoint) {
            guard let host else { return }
            let indexPath = host.collectionView.indexPathForItem(at: point)
            // Over the picture only: in the aspect ratio grid the rest of the tile is empty.
            let target = indexPath.flatMap { indexPath -> (IndexPath, NSView, CGRect)? in
                guard let item = host.model.item(section: indexPath.section, item: indexPath.item),
                    let view = host.collectionView.item(at: indexPath)?.view
                else { return nil }
                let picture = GridTile.pictureFrame(in: view.bounds, aspectRatio: item.aspectRatio, square: host.squareTiles)
                return picture.contains(view.convert(point, from: host.collectionView)) ? (indexPath, view, picture) : nil
            }
            guard target?.0 != liftedPath || liftedView == nil else { return }
            drop()
            guard let (indexPath, view, picture) = target else { return }
            liftedPath = indexPath
            liftedView = view
            liftedPicture = picture
            Self.apply(lifted: true, to: view, picture: picture)
        }

        /// The lifted tile settles back (at once when `animated` is false, e.g. for a reused tile).
        func drop(animated: Bool = true) {
            if let view = liftedView {
                Self.apply(lifted: false, to: view, picture: liftedPicture, animated: animated)
            }
            liftedView = nil
            liftedPath = nil
        }

        /// A tile's view is reused for another item: no lift and no settling animation stays on it.
        static func reset(_ view: NSView) {
            guard let layer = view.layer,
                layer.zPosition != 0 || layer.shadowOpacity != 0 || !CATransform3DIsIdentity(layer.sublayerTransform)
            else { return }
            for key in ["sublayerTransform", "shadowOpacity", "shadowPath"] { layer.removeAnimation(forKey: "lift." + key) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = CATransform3DIdentity
            layer.shadowOpacity = 0
            layer.zPosition = 0
            CATransaction.commit()
        }

        static func apply(lifted: Bool, to view: NSView, picture: CGRect, animated: Bool = true) {
            guard let layer = view.layer else { return }
            let workspace = NSWorkspace.shared
            let scale =
                lifted
                ? GridLiftMetrics.scale(
                    side: Double(min(picture.width, picture.height)), reduceMotion: workspace.accessibilityDisplayShouldReduceMotion) : 1
            let center = CGPoint(x: picture.midX, y: picture.midY)
            let transform = GridLayerTransform.scale(CGFloat(scale), about: layerPoint(center, in: view), of: layer)
            let shadowRect = CGRect(
                x: picture.midX - picture.width * scale / 2, y: picture.midY - picture.height * scale / 2, width: picture.width * scale,
                height: picture.height * scale)
            let path = CGPath(rect: layerRect(shadowRect, in: view), transform: nil)
            let opacity: Float = lifted ? Float(GridLiftMetrics.shadowOpacity) : 0
            // Down on screen, whichever way the layer's geometry runs.
            let drop = CGFloat(GridLiftMetrics.shadowDrop) * (layer.contentsAreFlipped() ? 1 : -1)

            // The picture may grow over its neighbours and its shadow falls on them.
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowRadius = CGFloat(GridLiftMetrics.shadowRadius)
            layer.shadowOffset = CGSize(width: 0, height: drop)
            layer.zPosition = lifted ? 10 : 0
            let duration = lifted ? GridLiftMetrics.liftDuration : GridLiftMetrics.dropDuration
            if animated {
                animate(layer, "sublayerTransform", to: NSValue(caTransform3D: transform), duration: duration)
                animate(layer, "shadowOpacity", to: opacity, duration: duration)
                animate(layer, "shadowPath", to: path, duration: duration)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = transform
            layer.shadowOpacity = opacity
            layer.shadowPath = path
            CATransaction.commit()
        }

        /// From where the property is shown now to `value`: a lift that is still rising settles back from there.
        private static func animate(_ layer: CALayer, _ key: String, to value: Any, duration: Double) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "lift." + key)
        }

        private static func layerPoint(_ point: CGPoint, in view: NSView) -> CGPoint {
            view.convertToLayer(point)
        }

        private static func layerRect(_ rect: CGRect, in view: NSView) -> CGRect {
            let a = view.convertToLayer(rect.origin)
            let b = view.convertToLayer(CGPoint(x: rect.maxX, y: rect.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
    }

    /// Scales a layer's sublayers about a point (the layer's own geometry is AppKit's: its anchor point stays as it is).
    enum GridLayerTransform {
        @MainActor static func scale(_ scale: CGFloat, about point: CGPoint, of layer: CALayer) -> CATransform3D {
            guard scale != 1 else { return CATransform3DIdentity }
            // The sublayer transform applies about the anchor point; move the pivot there, scale, and move it back.
            let bounds = layer.bounds
            let anchor = CGPoint(
                x: bounds.minX + layer.anchorPoint.x * bounds.width, y: bounds.minY + layer.anchorPoint.y * bounds.height)
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            return CATransform3DConcat(
                CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), CATransform3DMakeScale(scale, scale, 1)),
                CATransform3DMakeTranslation(dx, dy, 0))
        }
    }

    /// The continuous trackpad zoom of the grid (SPEC §17.7): scales what the clip view shows about the pointer while the
    /// fingers move between two zoom steps, and cross-fades into the new layout when a step is reached.
    @MainActor
    final class GridPinchScaler {
        private weak var clipView: NSClipView?
        /// Where the pinch is centred, in the clip view's coordinates.
        private var pivot: NSPoint = .zero
        private(set) var isScaled = false

        init(clipView: NSClipView) {
            self.clipView = clipView
            clipView.wantsLayer = true
        }

        func begin(at pivot: NSPoint) {
            self.pivot = pivot
        }

        /// Scales the grid by `scale` about the pinch's centre, following the fingers (no animation).
        func show(scale: Double) {
            guard let clipView, let layer = clipView.layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pinch.settle")
            layer.sublayerTransform = GridLayerTransform.scale(CGFloat(scale), about: clipView.convertToLayer(pivot), of: layer)
            CATransaction.commit()
            isScaled = scale != 1
        }

        /// The pinch ended between two steps: the grid springs back to its laid-out size.
        func settle() {
            guard let layer = clipView?.layer, isScaled else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let animation = CABasicAnimation(keyPath: "sublayerTransform")
            animation.fromValue =
                layer.presentation()?.value(forKeyPath: "sublayerTransform") ?? layer.value(forKeyPath: "sublayerTransform")
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = reduceMotion ? 0.12 : 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = CATransform3DIdentity
            layer.add(animation, forKey: "pinch.settle")
            CATransaction.commit()
            isScaled = false
        }

        /// The grid is about to be laid out for a new step: what is shown now (scaled to the new step's size) cross-fades
        /// into the new layout, and the scale is dropped. Call before the relayout, in the same transaction.
        func crossfadeIntoNewLayout() {
            guard let layer = clipView?.layer else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "pinch.step")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pinch.settle")
            layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
            isScaled = false
        }

        /// Ends any scale at once (the grid is replaced, e.g. by the Library's days).
        func reset() {
            guard let layer = clipView?.layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pinch.settle")
            layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
            isScaled = false
        }
    }
#endif
