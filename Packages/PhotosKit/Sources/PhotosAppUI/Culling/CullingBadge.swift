// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Keeps the ratings and flags of the account for a grid's tiles (SPEC §15.2) and tells the grid which tiles to redraw
/// when they change: rating a photo here, on another device or on the web (after the next tag refresh).
@MainActor
final class GridCullingObserver {
    private(set) var marks: [FileID: CullingMark] = [:]
    private var task: Task<Void, Never>?
    /// The files whose mark changed.
    var changed: ((Set<FileID>) -> Void)?

    init(services: AccountServices) {
        let store = CullingStore(database: services.database)
        task = Task { [weak self] in
            do {
                for try await marks in store.observeMarks() {
                    guard let self, !Task.isCancelled else { return }
                    let before = self.marks
                    self.marks = marks
                    let ids = Set(before.keys).union(marks.keys).filter { before[$0] != marks[$0] }
                    if !ids.isEmpty { self.changed?(ids) }
                }
            } catch {}
        }
    }

    deinit {
        task?.cancel()
    }

    func mark(_ id: FileID) -> CullingMark { marks[id] ?? .none }
}

/// What a tile shows of a mark.
struct CullingTileBadge: Equatable {
    /// "flag.fill" (picked), "xmark" (rejected) or nil.
    var flagSymbol: String?
    /// "★★★"; empty when unrated or the tile is too small for it.
    var stars: String
    /// Rejected photos are dimmed, as in Lightroom: what is left to look at stands out.
    var isDimmed: Bool
    /// Added to the tile's accessibility label: "3 stars, Pick".
    var accessibilityText: String?

    var isHidden: Bool { flagSymbol == nil && stars.isEmpty }

    /// Below this tile side (points) the stars are left out; the flag stays.
    static let minimumSideForStars: Double = 56

    init(_ mark: CullingMark, tileSide: Double) {
        flagSymbol =
            switch mark.flag {
            case .pick: "flag.fill"
            case .reject: "xmark"
            case .none: nil
            }
        stars = tileSide >= Self.minimumSideForStars ? String(repeating: "★", count: mark.rating) : ""
        isDimmed = mark.flag == .reject
        accessibilityText = mark.isEmpty ? nil : CullingWording.description(of: mark)
    }
}

#if os(macOS)
    /// The flag and stars in the top leading corner of a tile (macOS grid).
    final class CullingBadgeView: NSView {
        private let flag = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private(set) var badge: CullingTileBadge?

        override init(frame: NSRect) {
            super.init(frame: frame)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            flag.contentTintColor = .white
            flag.imageScaling = .scaleProportionallyUpOrDown
            flag.shadow = shadow
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.shadow = shadow
            addSubview(flag)
            addSubview(label)
            isHidden = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ badge: CullingTileBadge) {
            self.badge = badge
            isHidden = badge.isHidden
            if let symbol = badge.flagSymbol {
                flag.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                flag.contentTintColor = badge.isDimmed ? .white : .systemYellow
                flag.isHidden = false
            } else {
                flag.isHidden = true
            }
            label.stringValue = badge.stars
            label.isHidden = badge.stars.isEmpty
            needsLayout = true
        }

        /// The width the badge needs, for the tile to place what follows it.
        var fittingWidth: CGFloat {
            guard !isHidden else { return 0 }
            label.sizeToFit()
            return (flag.isHidden ? 0 : 15) + (label.isHidden ? 0 : label.frame.width + (flag.isHidden ? 0 : 2))
        }

        override func layout() {
            super.layout()
            var x: CGFloat = 0
            if !flag.isHidden {
                flag.frame = CGRect(x: 0, y: (bounds.height - 13) / 2, width: 13, height: 13)
                x = 15
            }
            label.sizeToFit()
            label.frame.origin = CGPoint(x: x, y: (bounds.height - label.frame.height) / 2)
        }
    }
#elseif canImport(UIKit)
    /// The flag and stars in the top leading corner of a tile (iPhone, iPad, Vision Pro grid).
    final class CullingBadgeView: UIView {
        private let flag = UIImageView()
        private let label = UILabel()
        private(set) var badge: CullingTileBadge?

        override init(frame: CGRect) {
            super.init(frame: frame)
            for view in [flag, label] as [UIView] {
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.7
                view.layer.shadowRadius = 2
                view.layer.shadowOffset = .zero
                addSubview(view)
            }
            flag.contentMode = .scaleAspectFit
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            isHidden = true
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ badge: CullingTileBadge) {
            self.badge = badge
            isHidden = badge.isHidden
            if let symbol = badge.flagSymbol {
                flag.image = UIImage(systemName: symbol)
                flag.tintColor = badge.isDimmed ? .white : .systemYellow
                flag.isHidden = false
            } else {
                flag.isHidden = true
            }
            label.text = badge.stars
            label.isHidden = badge.stars.isEmpty
            setNeedsLayout()
        }

        var fittingWidth: CGFloat {
            guard !isHidden else { return 0 }
            label.sizeToFit()
            return (flag.isHidden ? 0 : 15) + (label.isHidden ? 0 : label.bounds.width + (flag.isHidden ? 0 : 2))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            var x: CGFloat = 0
            if !flag.isHidden {
                flag.frame = CGRect(x: 0, y: (bounds.height - 13) / 2, width: 13, height: 13)
                x = 15
            }
            label.sizeToFit()
            label.frame.origin = CGPoint(x: x, y: (bounds.height - label.bounds.height) / 2)
        }
    }
#endif

/// Moving through a grid's tiles in reading order (auto-advance after a rating).
enum GridNavigation {
    /// The tile after `indexPath`, across sections; nil after the last one.
    static func indexPath(after indexPath: IndexPath, sectionCount: Int, itemCount: (Int) -> Int) -> IndexPath? {
        if indexPath.item + 1 < itemCount(indexPath.section) { return IndexPath(item: indexPath.item + 1, section: indexPath.section) }
        var section = indexPath.section + 1
        while section < sectionCount {
            if itemCount(section) > 0 { return IndexPath(item: 0, section: section) }
            section += 1
        }
        return nil
    }
}
