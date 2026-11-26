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

    /// Adds Return/Space to open, Escape to deselect, ⌘+/⌘− to zoom, and per-item context menus.
    final class GridCollectionView: NSCollectionView {
        weak var owner: PhotoGridScrollView?

        override func keyDown(with event: NSEvent) {
            let command = event.modifierFlags.contains(.command)
            if let owner, owner.handleCullingKey(event) { return }
            switch event.charactersIgnoringModifiers {
            case "\r", " ": owner?.openSelection()
            case "\u{1b}": owner?.clearSelection()
            case "+" where command, "=" where command: owner?.zoom(in: true)
            case "-" where command: owner?.zoom(in: false)
            default:
                // Arrow keys move the selection; with nothing selected they start at the first tile on screen.
                if selectionIndexPaths.isEmpty, let special = event.specialKey,
                    [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(special)
                {
                    owner?.selectFirstVisible()
                } else {
                    super.keyDown(with: event)
                }
            }
        }

        override func cancelOperation(_ sender: Any?) {
            owner?.clearSelection()
        }

        /// Edit ▸ Copy: the standard menu item reaches the grid through the responder chain.
        @objc func copy(_ sender: Any?) {
            owner?.copySelection()
        }

        /// Copy is offered while something is selected.
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if item.action == #selector(copy(_:)) { return owner?.canCopy ?? false }
            return true
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            guard let indexPath = indexPathForItem(at: point) else { return nil }
            return owner?.menu(for: indexPath)
        }
    }

    #if DEBUG
        /// UI checks without touching the real keyboard: `PHOTOS_DEBUG_GRID_KEYS=down,right,return` hands these key
        /// events to the grid of this process, one every 0.6 s, once the grid has items.
        @MainActor
        enum GridDebugKeys {
            private static var used = false

            static func runOnce(in collectionView: NSCollectionView) {
                guard !used, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_KEYS"], !raw.isEmpty else { return }
                used = true
                let keys = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for (index, key) in keys.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3 + 0.6 * Double(index)) { [weak collectionView] in
                        guard let collectionView, let event = event(for: key, window: collectionView.window) else { return }
                        collectionView.window?.makeFirstResponder(collectionView)
                        collectionView.keyDown(with: event)
                    }
                }
            }

            static func event(for key: String, window: NSWindow?) -> NSEvent? {
                let table: [String: (String, UInt16)] = [
                    "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
                    "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                    "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
                    "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                    "return": ("\r", 36), "space": (" ", 49), "escape": ("\u{1b}", 53),
                    // Culling (SPEC §15.2).
                    "p": ("p", 35), "x": ("x", 7), "u": ("u", 32), "c": ("c", 8), "0": ("0", 29), "1": ("1", 18), "2": ("2", 19),
                    "3": ("3", 20), "4": ("4", 21), "5": ("5", 23),
                ]
                guard let (characters, code) = table[key] else { return nil }
                let arrow = (123...126).contains(Int(code))
                return NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: arrow ? [.numericPad, .function] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            }
        }
    #endif

    #if DEBUG
        /// UI checks of the continuous pinch without a trackpad: `PHOTOS_DEBUG_GRID_PINCH=0.06,0.12,0.18` pinches at the
        /// middle of the grid through these magnifications, one every 0.5 s, once the grid has items, and holds the last
        /// one (for a screenshot) unless the list ends with `end`. `PHOTOS_DEBUG_GRID_HOVER=0.3,0.4` lifts the tile at
        /// that point of the visible grid as if the pointer rested there.
        @MainActor
        enum GridDebugPinch {
            private static var used = false

            static func runOnce(in grid: PhotoGridScrollView) {
                guard !used else { return }
                used = true
                if let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_HOVER"] {
                    let fractions = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if fractions.count == 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak grid] in
                            guard let grid else { return }
                            let clip = grid.contentView.bounds
                            let point = NSPoint(
                                x: clip.minX + clip.width * CGFloat(fractions[0]), y: clip.minY + clip.height * CGFloat(fractions[1]))
                            grid.debugHover(at: grid.collectionView.convert(point, from: grid.contentView))
                        }
                    }
                }
                guard let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_PINCH"], !raw.isEmpty else { return }
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let values = parts.compactMap(Double.init)
                let ends = parts.last == "end"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak grid] in
                    guard let grid else { return }
                    let clip = grid.contentView.bounds
                    let location = NSPoint(x: clip.midX, y: clip.midY)
                    grid.pinch(.began, magnification: 0, location: location) {}
                    for (index, value) in values.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(index + 1)) { [weak grid] in
                            grid?.pinch(.changed, magnification: value, location: location) {}
                            guard ends, index == values.count - 1 else { return }
                            grid?.pinch(.ended, magnification: value, location: location) {}
                        }
                    }
                }
            }
        }
    #endif

    final class MenuActionItem: NSMenuItem {
        let handler: @MainActor () -> Void

        init(title: String, handler: @escaping @MainActor () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @MainActor @objc func run() { handler() }
    }
#endif
