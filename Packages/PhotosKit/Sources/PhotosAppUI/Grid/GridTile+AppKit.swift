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

    /// The view of a tile. To accessibility it is a button: pressing it opens the photo (VoiceOver, automation).
    final class PhotoTileView: NSView {
        var label = ""
        var isTileSelected = false
        var onPress: (() -> Void)?
        var actions: (() -> [GridMenuAction])?
        var fileId: FileID?

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { label }
        override func isAccessibilitySelected() -> Bool { isTileSelected }
        /// Badges and the picture are described by the label.
        override func accessibilityChildren() -> [Any]? { [] }

        override func accessibilityPerformPress() -> Bool {
            guard let onPress else { return false }
            onPress()
            return true
        }

        /// The context menu actions (favourite, archive, delete…) as accessibility actions.
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            guard let fileId, let actions = actions?(), !actions.isEmpty else { return nil }
            return GridMenuAction.flattened(actions).map { action in
                NSAccessibilityCustomAction(name: action.title) {
                    action.handler([fileId])
                    return true
                }
            }
        }
    }

    /// Darkens the lower edge of a tile so the white badges stay readable on bright pictures.
    final class TileShadeView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func makeBackingLayer() -> CALayer {
            let gradient = CAGradientLayer()
            let workspace = NSWorkspace.shared
            let increased = workspace.accessibilityDisplayShouldIncreaseContrast || workspace.accessibilityDisplayShouldReduceTransparency
            gradient.colors = [
                NSColor.black.withAlphaComponent(GridTile.shadeOpacity(increased: increased)).cgColor, NSColor.clear.cgColor,
            ]
            // Layer coordinates start at the bottom on the Mac: dark at the bottom, clear at the top.
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            return gradient
        }
    }

    final class PhotoItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("PhotoItem")
        private let tileView = PhotoTileView()
        private let photoView = NSView()
        private let placeholderIcon = NSImageView()
        /// The file's name and "No preview" under the symbol of a file the server has no preview of (SPEC §20.1).
        private let placeholderName = NSTextField(labelWithString: "")
        private let placeholderCaption = NSTextField(labelWithString: GridTileNoPicture.caption)
        private var noPicture: GridTileNoPicture?
        private let shade = TileShadeView()
        private let durationLabel = NSTextField(labelWithString: "")
        private let videoIcon = NSImageView(image: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!)
        private let favoriteIcon = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!)
        private let liveIcon = NSImageView(image: NSImage(systemSymbolName: "livephoto", accessibilityDescription: nil)!)
        private let stackIcon = NSImageView(image: NSImage(systemSymbolName: "square.stack.fill", accessibilityDescription: nil)!)
        private let partnerIcon = NSImageView(
            image: NSImage(systemSymbolName: GridTileBadges.partnerSymbol, accessibilityDescription: nil)!)
        private let selectionRing = NSView()
        /// Rating and flag (SPEC §15.2).
        private let cullingBadge = CullingBadgeView()
        /// Rejected: the picture is dimmed.
        private var isDimmed = false
        /// Loads the preview and says what to draw; shared with the UIKit grid.
        private let picture = GridTilePicture()
        var fileId: FileID? { picture.fileId }
        /// Square tile, or the picture whole in the photo's shape (`TileStyle`).
        private var square = true
        private var aspectRatio = 1.0
        /// What the picture is now, for the way the next one arrives (`GridTileArrival`).
        private var shown = GridTileArrival.Shown.nothing

        override func loadView() {
            picture.show = { [weak self] display in self?.show(display) }
            let container = tileView
            container.wantsLayer = true
            container.layer?.masksToBounds = true
            photoView.wantsLayer = true
            // The tile's grey is the picture's: in the aspect ratio grid it has the photo's shape.
            photoView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            photoView.layer?.contentsGravity = .resizeAspectFill
            photoView.layer?.masksToBounds = true
            placeholderIcon.contentTintColor = .tertiaryLabelColor
            placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
            placeholderIcon.isHidden = true
            placeholderName.font = .systemFont(ofSize: 11, weight: .medium)
            placeholderName.textColor = .secondaryLabelColor
            placeholderCaption.font = .systemFont(ofSize: 10)
            placeholderCaption.textColor = .tertiaryLabelColor
            for label: NSTextField in [placeholderName, placeholderCaption] {
                label.alignment = .center
                label.lineBreakMode = .byTruncatingMiddle
                label.isHidden = true
            }
            durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            durationLabel.textColor = .white
            for icon in [favoriteIcon, liveIcon, videoIcon, partnerIcon] {
                icon.contentTintColor = .white
                icon.imageScaling = .scaleProportionallyUpOrDown
            }
            // The top edge has no shade: a soft shadow keeps the white badge visible on bright pictures.
            let partnerShadow = NSShadow()
            partnerShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            partnerShadow.shadowBlurRadius = 2
            partnerIcon.shadow = partnerShadow
            partnerIcon.isHidden = true
            selectionRing.wantsLayer = true
            selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
            selectionRing.layer?.borderWidth = 3
            selectionRing.isHidden = true
            // On the picture without a shade: a soft shadow keeps it visible on bright pictures.
            stackIcon.contentTintColor = .white
            stackIcon.imageScaling = .scaleProportionallyUpOrDown
            stackIcon.isHidden = true
            let stackShadow = NSShadow()
            stackShadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            stackShadow.shadowBlurRadius = 2
            stackIcon.shadow = stackShadow
            [
                photoView, placeholderIcon, placeholderName, placeholderCaption, shade, durationLabel, videoIcon, favoriteIcon, liveIcon,
                stackIcon, partnerIcon,
                cullingBadge, selectionRing,
            ].forEach {
                container.addSubview($0)
            }
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            // The picture's place in the tile: all of it, or the photo's shape in the aspect ratio grid. Badges and
            // the selection ring go with the picture.
            let bounds = GridTile.pictureFrame(in: view.bounds, aspectRatio: aspectRatio, square: square)
            let x = bounds.minX
            let y = bounds.minY
            photoView.frame = bounds
            selectionRing.frame = bounds
            let showsText: Bool = noPicture?.showsText(tileSide: Double(min(bounds.width, bounds.height))) ?? false
            placeholderName.isHidden = !showsText || shown != .placeholder
            placeholderCaption.isHidden = placeholderName.isHidden
            if showsText {
                // Symbol, name and "No preview", centred together (y grows upwards in this view).
                let glyph = min(bounds.width * 0.24, 36)
                let lines = 30.0
                let top = y + (bounds.height + glyph + 6 + lines) / 2
                placeholderIcon.frame = CGRect(x: x + (bounds.width - glyph) / 2, y: top - glyph, width: glyph, height: glyph)
                placeholderName.frame = CGRect(x: x + 6, y: top - glyph - 6 - 15, width: bounds.width - 12, height: 15)
                placeholderCaption.frame = CGRect(x: x + 6, y: top - glyph - 6 - 30, width: bounds.width - 12, height: 14)
            } else {
                let glyph = min(max(bounds.width * 0.34, 14), 44)
                placeholderIcon.frame = CGRect(
                    x: x + (bounds.width - glyph) / 2, y: y + (bounds.height - glyph) / 2, width: glyph, height: glyph)
            }
            shade.frame = CGRect(x: x, y: y, width: bounds.width, height: min(bounds.height * 0.4, 36))
            durationLabel.sizeToFit()
            var right = bounds.maxX - 5
            if !durationLabel.isHidden {
                durationLabel.frame.origin = CGPoint(x: right - durationLabel.frame.width, y: y + 3)
                right = durationLabel.frame.minX - 3
            }
            videoIcon.frame = CGRect(x: right - 16, y: y + 4, width: 16, height: 12)
            favoriteIcon.frame = CGRect(x: x + 5, y: y + 4, width: 13, height: 12)
            // The flag and stars take the top leading corner; the Live Photo badge follows them.
            let cullingWidth = cullingBadge.fittingWidth
            cullingBadge.frame = CGRect(x: x + 5, y: bounds.maxY - 19, width: cullingWidth, height: 15)
            liveIcon.frame = CGRect(x: x + 4 + (cullingWidth > 0 ? cullingWidth + 4 : 0), y: bounds.maxY - 20, width: 16, height: 16)
            stackIcon.frame = CGRect(x: bounds.maxX - 20, y: bounds.maxY - 20, width: 16, height: 16)
            // Both in the top trailing corner: the partner badge moves left of the stack badge.
            let partnerRight = stackIcon.isHidden ? bounds.maxX - 4 : stackIcon.frame.minX - 3
            partnerIcon.frame = CGRect(x: partnerRight - 17, y: bounds.maxY - 18, width: 17, height: 14)
        }

        override var isSelected: Bool {
            didSet {
                selectionRing.isHidden = !isSelected
                updateAlpha()
                tileView.isTileSelected = isSelected
            }
        }

        private func updateAlpha() {
            photoView.alphaValue = (isSelected ? 0.8 : 1) * (isDimmed ? 0.4 : 1)
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridScrollView, tileSide: Double, scale: Double) {
            let services = owner.services
            if square != owner.squareTiles || aspectRatio != item.aspectRatio {
                square = owner.squareTiles
                aspectRatio = item.aspectRatio
                view.needsLayout = true
            }
            photoView.isHidden = false
            updateBadges(item, owner: owner)
            let culling = CullingTileBadge(owner.culling.mark(item.fileId), tileSide: tileSide)
            cullingBadge.show(culling)
            isDimmed = culling.isDimmed
            updateAlpha()
            if let text = culling.accessibilityText { tileView.label += ", " + text }
            // What the photo shows, written on this device (SPEC §16.2).
            if let text = services.descriptions.text(of: item.fileId) { tileView.label += ", " + text }
            picture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square),
                source: GridTilePicture.Source(services: services))
        }

        /// A tile of the first sync's skeleton: grey, nothing on it, nothing to open.
        func showPlaceholder() {
            picture.reset()
            square = true
            let badges: [NSView] = [durationLabel, videoIcon, favoriteIcon, liveIcon, stackIcon, partnerIcon, shade, cullingBadge]
            for badge in badges { badge.isHidden = true }
            isDimmed = false
            updateAlpha()
            tileView.fileId = nil
            tileView.label = String(localized: "Loading…", bundle: .module)
            tileView.onPress = nil
            tileView.actions = nil
            view.needsLayout = true
        }

        private func show(_ display: GridTilePicture.Display) {
            switch display {
            case .clear:
                photoView.layer?.removeAllAnimations()
                photoView.layer?.contents = nil
                placeholderIcon.isHidden = true
                hidePlaceholderText()
                shown = .nothing
            case .blur(let image):
                photoView.layer?.contents = image
                shown = .blur
            case .picture(let image):
                let arrival = GridTileArrival.transition(
                    from: shown, isAsync: picture.isDelivering,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                photoView.layer?.contents = image
                placeholderIcon.isHidden = true
                hidePlaceholderText()
                shown = .picture
                if view.window != nil { animateArrival(arrival) }
            case .placeholder(let value):
                placeholderIcon.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)
                placeholderIcon.isHidden = false
                placeholderName.stringValue = value.name
                noPicture = value
                if let text = value.accessibilityText, !tileView.label.hasSuffix(text) { tileView.label += ", " + text }
                shown = .placeholder
                view.needsLayout = true
            }
        }

        private func hidePlaceholderText() {
            noPicture = nil
            placeholderName.isHidden = true
            placeholderCaption.isHidden = true
        }

        /// A heart springs up over the tile and fades (a fade only with Reduce Motion).
        func playHeartBurst() {
            guard let host = view.layer,
                let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 48, weight: .regular).applying(.init(paletteColors: [.white])))
            else { return }
            let side = min(max(min(view.bounds.width, view.bounds.height) * 0.42, 18), 72)
            let heart = CALayer()
            heart.contents = symbol
            heart.contentsGravity = .resizeAspect
            heart.frame = CGRect(x: view.bounds.midX - side / 2, y: view.bounds.midY - side / 2, width: side, height: side)
            heart.shadowColor = NSColor.black.cgColor
            heart.shadowOpacity = 0.35
            heart.shadowRadius = 6
            heart.shadowOffset = .zero
            heart.opacity = 0
            host.addSublayer(heart)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.25, 0.6, 1]
            var animations: [CAAnimation] = [fade]
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.4, 1.08, 1, 1.25]
                scale.keyTimes = [0, 0.3, 0.6, 1]
                animations.append(scale)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = 0.9
            CATransaction.begin()
            CATransaction.setCompletionBlock { heart.removeFromSuperlayer() }
            heart.add(group, forKey: "burst")
            CATransaction.commit()
        }

        /// The preview comes in over the BlurHash: a cross-fade and a tiny settle, run by Core Animation (SPEC §17.2).
        private func animateArrival(_ arrival: GridTileArrival) {
            guard arrival != .instant, let layer = photoView.layer else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = GridTileArrival.fadeDuration
            layer.add(fade, forKey: "arrival")
            guard arrival == .fadeAndSettle else { return }
            let settle = CABasicAnimation(keyPath: "contentsRect")
            settle.fromValue = NSValue(rect: GridTileArrival.settleContentsRect)
            settle.toValue = NSValue(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            settle.duration = GridTileArrival.settleDuration
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            layer.add(settle, forKey: "settle")
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridScrollView) {
            let badges = GridTileBadges(item: item, isPartner: owner.services.partnerPaths.contains(directory: item.directory))
            // The partner badge, or the backup state of a device photo (SPEC §21.1).
            partnerIcon.isHidden = badges.cornerSymbol == nil
            if let symbol = badges.cornerSymbol { partnerIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            durationLabel.stringValue = badges.duration ?? ""
            durationLabel.isHidden = badges.duration == nil
            videoIcon.isHidden = !badges.showsVideo
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
            stackIcon.isHidden = !badges.showsStack
            shade.isHidden = !badges.showsShade
            let id = item.fileId
            tileView.fileId = id
            tileView.label = badges.accessibilityLabel
            tileView.onPress = { [weak owner] in owner?.open(id) }
            tileView.actions = { [weak owner] in owner?.menuActions(for: id) ?? [] }
            view.needsLayout = true
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            GridHoverLift.reset(view)
            picture.reset()
        }
    }
#endif
