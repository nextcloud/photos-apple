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

    final class PhotoCell: UICollectionViewCell {
        static let reuseIdentifier = "PhotoCell"
        private let imageView = UIImageView()
        private let placeholderIcon = UIImageView()
        /// The file's name and "No preview" under the symbol of a file the server has no preview of (SPEC §20.1).
        private let placeholderName = UILabel()
        private let placeholderCaption = UILabel()
        private var noPicture: GridTileNoPicture?
        /// The video's duration in a small glass capsule (SPEC §17.2).
        private let videoPill = GridVideoPill()
        private let favoriteIcon = UIImageView(image: UIImage(systemName: "heart.fill"))
        private let liveIcon = UIImageView(image: UIImage(systemName: "livephoto"))
        private let stackIcon = UIImageView(image: UIImage(systemName: "square.stack.fill"))
        private let partnerIcon = UIImageView(image: UIImage(systemName: GridTileBadges.partnerSymbol))
        private let checkmark = UIImageView()
        private let gradient = CAGradientLayer()
        /// Rating and flag (SPEC §15.2); rejected photos are dimmed.
        private let cullingBadge = CullingBadgeView()
        private var isDimmed = false
        private var isTileSelected = false
        /// The photo the selection look was last drawn for: only a change of the same tile animates (not a reused cell).
        private var selectionShownFor: FileID?
        /// What the picture is now, for the way the next one arrives (`GridTileArrival`).
        private var shown = GridTileArrival.Shown.nothing
        /// Loads the preview and says what to draw; shared with the AppKit grid.
        private let tilePicture = GridTilePicture()
        var fileId: FileID? { tilePicture.fileId }
        private var menuActions: (() -> [GridMenuAction])?
        /// Square tile, or the picture whole in the photo's shape (`TileStyle`).
        private var square = true
        private var aspectRatio = 1.0
        /// "1:05" of a video.
        private var duration: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = .secondarySystemFill
            contentView.addSubview(imageView)
            placeholderIcon.tintColor = .tertiaryLabel
            placeholderIcon.contentMode = .scaleAspectFit
            placeholderIcon.isHidden = true
            contentView.addSubview(placeholderIcon)
            placeholderName.font = .preferredFont(forTextStyle: .caption2)
            placeholderName.textColor = .secondaryLabel
            placeholderCaption.font = .preferredFont(forTextStyle: .caption2)
            placeholderCaption.textColor = .tertiaryLabel
            placeholderCaption.text = GridTileNoPicture.caption
            for label: UILabel in [placeholderName, placeholderCaption] {
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingMiddle
                label.adjustsFontForContentSizeCategory = true
                label.isHidden = true
                contentView.addSubview(label)
            }
            contentView.layer.addSublayer(gradient)
            for icon in [favoriteIcon, liveIcon, partnerIcon] {
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
            }
            // The top edge has no shade: a soft shadow keeps the white badge visible on bright pictures.
            partnerIcon.layer.shadowColor = UIColor.black.cgColor
            partnerIcon.layer.shadowOpacity = 0.5
            partnerIcon.layer.shadowRadius = 1.5
            partnerIcon.layer.shadowOffset = .zero
            partnerIcon.isHidden = true
            checkmark.contentMode = .scaleAspectFit
            // The empty circle is white on the photo: a soft shadow keeps it visible on bright pictures.
            checkmark.layer.shadowColor = UIColor.black.cgColor
            checkmark.layer.shadowOpacity = 0.35
            checkmark.layer.shadowRadius = 1.5
            checkmark.layer.shadowOffset = .zero
            // On the picture without a shade: a soft shadow keeps it visible on bright pictures.
            stackIcon.tintColor = .white
            stackIcon.contentMode = .scaleAspectFit
            stackIcon.layer.shadowColor = UIColor.black.cgColor
            stackIcon.layer.shadowOpacity = 0.5
            stackIcon.layer.shadowRadius = 1.5
            stackIcon.layer.shadowOffset = .zero
            stackIcon.isHidden = true
            // The Live badge stays readable on bright pictures without a shade.
            liveIcon.layer.shadowColor = UIColor.black.cgColor
            liveIcon.layer.shadowOpacity = 0.4
            liveIcon.layer.shadowRadius = 1.5
            liveIcon.layer.shadowOffset = .zero
            [videoPill, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge, checkmark].forEach {
                contentView.addSubview($0)
            }
            // Pointer (iPad trackpad or mouse): the tile under it is highlighted. Vision Pro: the tile looked at lifts
            // towards the eyes with the system's lift effect, drawn by the system outside the app (SPEC §17.7).
            #if os(visionOS)
                hoverStyle = UIHoverStyle(effect: .lift, shape: .rect(cornerRadius: GridTile.visionHoverCornerRadius))
            #else
                hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect)
            #endif
            tilePicture.show = { [weak self] display in self?.show(display) }
            isAccessibilityElement = true
            // Double-tap (VoiceOver), Switch Control and Voice Control activate the cell like a tap: it opens the photo.
            accessibilityTraits = [.image, .button]
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The picture's place in the tile: all of it, or the photo's shape in the aspect ratio grid. Badges and
            // the selection mark go with the picture.
            let bounds = GridTile.pictureFrame(in: contentView.bounds, aspectRatio: aspectRatio, square: square)
            let x = bounds.minX
            let y = bounds.minY
            imageView.frame = bounds
            let showsText: Bool = noPicture?.showsText(tileSide: Double(min(bounds.width, bounds.height))) ?? false
            placeholderName.isHidden = !showsText || shown != .placeholder
            placeholderCaption.isHidden = placeholderName.isHidden
            if showsText {
                // Symbol, name and "No preview", centred together.
                let glyph = min(bounds.width * 0.24, 36)
                let line = ceil(placeholderName.font.lineHeight)
                let top = y + (bounds.height - glyph - 6 - 2 * line) / 2
                placeholderIcon.frame = CGRect(x: x + (bounds.width - glyph) / 2, y: top, width: glyph, height: glyph)
                placeholderName.frame = CGRect(x: x + 6, y: top + glyph + 6, width: bounds.width - 12, height: line)
                placeholderCaption.frame = CGRect(x: x + 6, y: top + glyph + 6 + line, width: bounds.width - 12, height: line)
            } else {
                let glyph = min(max(bounds.width * 0.34, 14), 44)
                placeholderIcon.frame = CGRect(
                    x: x + (bounds.width - glyph) / 2, y: y + (bounds.height - glyph) / 2, width: glyph, height: glyph)
            }
            gradient.frame = CGRect(x: x, y: y + bounds.height * 0.6, width: bounds.width, height: bounds.height * 0.4)
            // The selection mark sits in the bottom trailing corner, as in Apple Photos; duration and video badge
            // move left of it.
            let mark = CGFloat(GridTile.checkmarkSide(tileSide: Double(min(bounds.width, bounds.height))))
            checkmark.frame = CGRect(x: bounds.maxX - mark - 4, y: bounds.maxY - mark - 4, width: mark, height: mark)
            let markShown = !checkmark.isHidden
            let trailingBadges = GridTile.showsTrailingBadges(tileSide: Double(bounds.width), checkmarkShown: markShown)
            let pill = GridVideoPillLayout.layout(tileWidth: Double(bounds.width))
            videoPill.alpha = trailingBadges && pill != .hidden ? 1 : 0
            videoPill.show(duration: pill == .duration ? duration : nil)
            let pillHeight = (GridVideoPill.font.lineHeight + 4).rounded(.up)
            let pillWidth = videoPill.fittingWidth(height: pillHeight)
            let right = markShown ? checkmark.frame.minX - 4 : bounds.maxX - 4
            videoPill.frame = CGRect(x: right - pillWidth, y: bounds.maxY - pillHeight - 4, width: pillWidth, height: pillHeight)
            favoriteIcon.frame = CGRect(x: x + 4, y: bounds.maxY - 16, width: 13, height: 12)
            // The flag and stars take the top leading corner; the Live Photo badge follows them.
            let cullingWidth = cullingBadge.fittingWidth
            cullingBadge.frame = CGRect(x: x + 5, y: y + 5, width: cullingWidth, height: 15)
            liveIcon.frame = CGRect(x: x + 4 + (cullingWidth > 0 ? cullingWidth + 4 : 0), y: y + 4, width: 16, height: 16)
            stackIcon.frame = CGRect(x: bounds.maxX - 20, y: y + 4, width: 16, height: 16)
            // Both in the top trailing corner: the partner badge moves left of the stack badge.
            let partnerRight = stackIcon.isHidden ? bounds.maxX - 4 : stackIcon.frame.minX - 3
            partnerIcon.frame = CGRect(x: partnerRight - 17, y: y + 4, width: 17, height: 14)
        }

        /// The picture the tile shows right now (first picture of the context menu's preview).
        var picture: UIImage? { tilePicture.hasPicture ? imageView.image : nil }

        /// Called by UIKit whenever the cell is selected or deselected and when the collection view starts or stops
        /// editing (the selection mode), also for cells that are not on screen yet.
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)
            updateSelection(editing: state.isEditing, selected: state.isSelected)
        }

        func updateSelection(editing: Bool, selected: Bool) {
            let wasHidden = checkmark.isHidden
            // Only a tile on screen whose own state changed animates (not a reused cell, not the first configuration).
            let animated = window != nil && selectionShownFor == fileId && fileId != nil && selected != isTileSelected
            selectionShownFor = fileId
            checkmark.isHidden = !(editing || selected)
            let image =
                selected
                ? UIImage(
                    systemName: "checkmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor]))
                : UIImage(systemName: "circle")
            // Selected: a white tick on the accent colour (the view's inherited tint). Not selected: a white ring.
            checkmark.tintColor = selected ? nil : .white
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if let image {
                if animated, !wasHidden {
                    // The tick springs in (SPEC §17.2).
                    checkmark.setSymbolImage(image, contentTransition: .replace.downUp)
                    if selected, !reduceMotion { checkmark.addSymbolEffect(.bounce) }
                } else {
                    checkmark.image = image
                }
            }
            isTileSelected = selected
            // Pressed into the page: a selected tile shrinks a little and rounds its corners (no shrink with Reduce
            // Motion).
            let side = Double(min(contentView.bounds.width, contentView.bounds.height))
            let look = { [self] in
                imageView.alpha = (selected ? GridSelectionLook.selectedAlpha : 1) * (isDimmed ? 0.4 : 1)
                imageView.layer.cornerRadius = selected ? CGFloat(GridSelectionLook.cornerRadius(tileSide: side)) : 0
                let scale = selected && !reduceMotion ? CGFloat(GridSelectionLook.scale) : 1
                contentView.transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
            }
            if animated {
                UIView.animate(
                    springDuration: 0.3, bounce: reduceMotion ? 0 : 0.2, options: [.allowUserInteraction, .beginFromCurrentState]
                ) {
                    look()
                }
            } else {
                look()
            }
            if selected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
            // The badges make room for the mark.
            if wasHidden != checkmark.isHidden { setNeedsLayout() }
        }

        /// Shows `item`. Called again for the same item when its badges, the zoom or the screen scale change: the
        /// picture then stays until a sharper one has loaded (no flash).
        func configure(item: GridMedia, owner: PhotoGridController, tileSide: Double, scale: Double) {
            let services = owner.services
            if square != owner.squareTiles || aspectRatio != item.aspectRatio {
                square = owner.squareTiles
                aspectRatio = item.aspectRatio
                setNeedsLayout()
            }
            updateBadges(item, owner: owner)
            let culling = CullingTileBadge(owner.culling.mark(item.fileId), tileSide: tileSide)
            cullingBadge.show(culling)
            isDimmed = culling.isDimmed
            imageView.alpha = (isTileSelected ? GridSelectionLook.selectedAlpha : 1) * (isDimmed ? 0.4 : 1)
            if let text = culling.accessibilityText { accessibilityLabel = (accessibilityLabel ?? "") + ", " + text }
            // What the photo shows, written on this device (SPEC §16.2).
            if let text = services.descriptions.text(of: item.fileId) { accessibilityLabel = (accessibilityLabel ?? "") + ", " + text }
            setNeedsUpdateConfiguration()
            tilePicture.configure(
                item: item, request: services.previewRequest(for: item, tileSide: tileSide, scale: scale, square: square),
                source: GridTilePicture.Source(services: services))
        }

        /// A tile of the first sync's skeleton: grey, nothing on it, nothing to open.
        func showPlaceholder() {
            tilePicture.reset()
            square = true
            let badges: [UIView] = [videoPill, favoriteIcon, liveIcon, stackIcon, partnerIcon, cullingBadge]
            for badge in badges { badge.isHidden = true }
            isDimmed = false
            gradient.isHidden = true
            menuActions = nil
            accessibilityLabel = String(localized: "Loading…", bundle: .module)
            setNeedsLayout()
        }

        private func show(_ display: GridTilePicture.Display) {
            switch display {
            case .clear:
                imageView.layer.removeAnimation(forKey: "arrival")
                imageView.layer.removeAnimation(forKey: "settle")
                imageView.image = nil
                placeholderIcon.isHidden = true
                hidePlaceholderText()
                shown = .nothing
            case .blur(let image):
                imageView.image = UIImage(cgImage: image)
                shown = .blur
            case .picture(let image):
                let arrival = GridTileArrival.transition(
                    from: shown, isAsync: tilePicture.isDelivering, reduceMotion: UIAccessibility.isReduceMotionEnabled)
                imageView.image = UIImage(cgImage: image)
                placeholderIcon.isHidden = true
                hidePlaceholderText()
                shown = .picture
                if window != nil { animateArrival(arrival) }
            case .placeholder(let value):
                placeholderIcon.image = UIImage(systemName: value.symbol)
                placeholderIcon.isHidden = false
                placeholderName.text = value.name
                noPicture = value
                if let text = value.accessibilityText, let label = accessibilityLabel, !label.hasSuffix(text) {
                    accessibilityLabel = label + ", " + text
                }
                shown = .placeholder
                setNeedsLayout()
            }
        }

        private func hidePlaceholderText() {
            noPicture = nil
            placeholderName.isHidden = true
            placeholderCaption.isHidden = true
        }

        /// The preview comes in over the BlurHash: a cross-fade and a tiny settle, both run by Core Animation (nothing
        /// per frame on the main thread, no layout change).
        private func animateArrival(_ arrival: GridTileArrival) {
            guard arrival != .instant else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = GridTileArrival.fadeDuration
            imageView.layer.add(fade, forKey: "arrival")
            guard arrival == .fadeAndSettle else { return }
            let settle = CABasicAnimation(keyPath: "contentsRect")
            settle.fromValue = NSValue(cgRect: GridTileArrival.settleContentsRect)
            settle.toValue = NSValue(cgRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            settle.duration = GridTileArrival.settleDuration
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            imageView.layer.add(settle, forKey: "settle")
        }

        /// A heart over the tile (favourite).
        func playHeartBurst() {
            contentView.playHeartBurst(side: min(contentView.bounds.width, contentView.bounds.height))
        }

        /// The Live badge plays (layer by layer) while the tile is held, hovered or peeked into.
        func setLiveActive(_ active: Bool) {
            guard !liveIcon.isHidden else { return }
            if active {
                liveIcon.addSymbolEffect(.variableColor.iterative.reversing, options: .repeating)
            } else {
                liveIcon.removeAllSymbolEffects()
            }
        }

        private func updateBadges(_ item: GridMedia, owner: PhotoGridController) {
            let badges = GridTileBadges(item: item, isPartner: owner.services.partnerPaths.contains(directory: item.directory))
            // The partner badge, or the backup state of a device photo (SPEC §21.1).
            partnerIcon.isHidden = badges.cornerSymbol == nil
            if let symbol = badges.cornerSymbol { partnerIcon.image = UIImage(systemName: symbol) }
            duration = badges.duration
            videoPill.isHidden = !badges.showsVideo
            if favoriteIcon.isHidden, badges.showsFavorite, fileId == item.fileId, window != nil {
                // Made a favourite while on screen: the badge bounces in.
                favoriteIcon.isHidden = false
                if !UIAccessibility.isReduceMotionEnabled { favoriteIcon.addSymbolEffect(.bounce) }
            }
            favoriteIcon.isHidden = !badges.showsFavorite
            liveIcon.isHidden = !badges.showsLivePhoto
            stackIcon.isHidden = !badges.showsStack
            // Videos have their glass capsule; the shade is only under the favourite's heart.
            gradient.isHidden = !badges.showsFavorite
            let increased = UIAccessibility.isDarkerSystemColorsEnabled || UIAccessibility.isReduceTransparencyEnabled
            gradient.colors = [
                UIColor.clear.cgColor, UIColor.black.withAlphaComponent(GridTile.shadeOpacity(increased: increased)).cgColor,
            ]
            accessibilityLabel = badges.accessibilityLabel
            let id = item.fileId
            menuActions = { [weak owner] in owner?.menuActions(for: id) ?? [] }
            setNeedsLayout()
        }

        /// The context menu actions (favourite, archive, delete…) for VoiceOver's actions rotor.
        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            get {
                guard let fileId, let actions = menuActions?() else { return nil }
                return GridMenuAction.flattened(actions).map { action in
                    UIAccessibilityCustomAction(name: action.title) { _ in
                        action.handler([fileId])
                        return true
                    }
                }
            }
            set {}
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            tilePicture.reset()
            selectionShownFor = nil
            liveIcon.removeAllSymbolEffects()
            contentView.transform = .identity
            imageView.layer.cornerRadius = 0
        }
    }
#endif
