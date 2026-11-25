// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosDomain
import PhotosModel
import PhotosStore

// The platform-neutral half of the grid's motion (SPEC §17.2): the floating date pill, how a tile's picture arrives,
// selected tiles, and the choreography of favourite, delete and archive. `PhotoGrid+UIKit` and `PhotoGrid+AppKit` draw it.

// MARK: - Floating date pill

/// The glass capsule pinned at the top of a timeline grid: the month (or year) of the photos at the top, and the place
/// of the moment they belong to ("November 2026 · Lisbon"). It replaces the pinned section headers; the headers in the
/// content stay as light text without a band.
struct GridDatePill: Equatable {
    /// "November 2026", or the year when zoomed out to years.
    var title: String
    /// The moment's place, else its title (SPEC §16.1); nil outside moments.
    var detail: String?

    var text: String { detail.map { "\(title) · \($0)" } ?? title }

    /// VoiceOver: the same words without the middle dot.
    var accessibilityLabel: String { detail.map { "\(title), \($0)" } ?? title }

    /// Sections above the one at the top that are searched for the moment it belongs to (a moment's title is on its
    /// newest day; a trip of a few weeks is the longest moment there is).
    static let momentLookBack = 62

    /// Offset below the top of the content (points) from which on the pill is shown: at the very top the first header
    /// says the same thing in large type.
    static let revealOffset = 12.0

    /// The pill for the section at `index`; nil for a grid without dates (albums, search results).
    static func make(sections: [GridSection], index: Int, moments: MomentHeaders, locale: Locale = .current) -> GridDatePill? {
        guard let section = sections[safe: index] else { return nil }
        switch section.kind {
        case .flat: return nil
        case .year: return GridDatePill(title: DayLabel.yearLabel(for: section.date, locale: locale))
        case .month: return GridDatePill(title: DayLabel.monthYearLabel(for: section.date, locale: locale))
        case .day:
            let moment = Self.moment(of: index, in: sections, moments: moments)
            return GridDatePill(
                title: DayLabel.monthYearLabel(for: section.date, locale: locale), detail: moment.map { $0.place ?? $0.title })
        }
    }

    /// The moment a day section belongs to: the nearest titled day at or above it (moments do not overlap) when its
    /// days reach down to this one.
    static func moment(of index: Int, in sections: [GridSection], moments: MomentHeaders) -> MomentHeaders.Entry? {
        guard !moments.entries.isEmpty, let day = sections[safe: index]?.id else { return nil }
        var position = index
        while position >= 0, index - position <= momentLookBack {
            let section = sections[position]
            if section.kind == .day, let entry = moments[section.id] {
                return (entry.oldestDay ?? section.id) <= day ? entry : nil
            }
            position -= 1
        }
        return nil
    }

    /// Which way the text hands over to the next section's: older photos come up from below as the grid scrolls down.
    enum Handover: Equatable {
        case none
        /// Scrolled down to older photos: the new text pushes in from below.
        case older
        /// Scrolled up to newer photos: from above.
        case newer
    }

    static func handover(from oldIndex: Int?, to newIndex: Int) -> Handover {
        guard let oldIndex, oldIndex != newIndex else { return .none }
        return newIndex > oldIndex ? .older : .newer
    }
}

// MARK: - Photo arrival

/// How a tile's picture comes in (SPEC §17.2): a preview that arrives after the BlurHash cross-fades from it with a tiny
/// settle (the picture eases from 4 % larger into place, inside the tile: no layout shift). Pictures that are at hand
/// when the tile is configured (scrolling through what was seen) are shown at once — nothing animates while scrolling
/// fast.
enum GridTileArrival: Equatable {
    case instant
    /// A sharper picture over a softer one of the same photo, or with Reduce Motion: a short cross-fade only.
    case fade
    case fadeAndSettle

    /// What the tile showed before.
    enum Shown: Equatable {
        case nothing, blur, picture, placeholder
    }

    static let fadeDuration = 0.22
    static let settleDuration = 0.45
    /// The picture starts this much larger and settles to its size.
    static let settleScale = 1.04

    /// - Parameters:
    ///   - previous: what the tile showed.
    ///   - isAsync: the picture was loaded after the tile was configured (not taken from memory then).
    static func transition(from previous: Shown, isAsync: Bool, reduceMotion: Bool) -> GridTileArrival {
        guard isAsync else { return .instant }
        switch previous {
        case .picture: return .fade
        case .nothing, .blur, .placeholder: return reduceMotion ? .fade : .fadeAndSettle
        }
    }

    /// The part of the picture shown at the start of the settle (`CALayer.contentsRect`): the middle, `1 / settleScale`
    /// of it, which the tile's aspect fill makes 4 % larger.
    static var settleContentsRect: CGRect {
        let side = 1 / settleScale
        let inset = (1 - side) / 2
        return CGRect(x: inset, y: inset, width: side, height: side)
    }
}

// MARK: - Physical selection

/// A selected tile shrinks a little and rounds its corners, as if pressed into the page (SPEC §17.2).
enum GridSelectionLook {
    /// Scale of a selected tile.
    static let scale = 0.92

    /// Corner radius of a selected tile's picture: a hint on small tiles, 10 pt at most.
    static func cornerRadius(tileSide: Double) -> Double {
        min(10, max(3, (tileSide * 0.07).rounded()))
    }

    /// Opacity of a selected picture: a little dimmed, so that the selection reads in black and white as well.
    static let selectedAlpha = 0.85
}

// MARK: - Action feedback

/// How tiles leave the grid when the user removes them (and how they come back when the change is undone).
enum GridLeaveStyle: Equatable, Sendable {
    /// Delete: the tile shrinks away and its neighbours flow into the gap.
    case collapse
    /// Archive, remove from album: the tile slides away to the side.
    case slide
}

/// What the screen has just asked for, so that the grid can animate the model change that follows (the change itself
/// comes later, through the library's observation, together with whatever else synced).
///
/// Tiles the user removed leave with their style; when they come back within `returnWindow` (Undo), they return the
/// same way. Changes nobody asked for (a sync, another device) are applied without animation as before.
struct GridActionExpectations {
    /// How long after the action its change is expected.
    static let leaveWindow: TimeInterval = 8
    /// How long removed tiles are remembered for an Undo.
    static let returnWindow: TimeInterval = 120

    private struct Entry {
        var style: GridLeaveStyle
        var time: TimeInterval
    }

    private var leaving: [FileID: Entry] = [:]
    private var removed: [FileID: Entry] = [:]

    var isEmpty: Bool { leaving.isEmpty && removed.isEmpty }

    /// The user deleted, archived or removed `ids`.
    mutating func expectLeaving(_ ids: some Sequence<FileID>, style: GridLeaveStyle, now: TimeInterval) {
        prune(now: now)
        for id in ids { leaving[id] = Entry(style: style, time: now) }
    }

    /// The style for a change that removes `gone` and brings back `back`: the style of the expected tiles among them
    /// (a mix takes the first found), nil when none of them was expected. Leaving tiles are remembered for an Undo,
    /// returning ones forgotten.
    mutating func style(gone: some Collection<FileID>, back: some Collection<FileID>, now: TimeInterval) -> GridLeaveStyle? {
        prune(now: now)
        var style: GridLeaveStyle?
        for id in gone {
            guard let entry = leaving.removeValue(forKey: id) else { continue }
            style = style ?? entry.style
            removed[id] = Entry(style: entry.style, time: now)
        }
        for id in back {
            guard let entry = removed.removeValue(forKey: id) else { continue }
            style = style ?? entry.style
        }
        return style
    }

    private mutating func prune(now: TimeInterval) {
        leaving = leaving.filter { now - $0.value.time <= Self.leaveWindow }
        removed = removed.filter { now - $0.value.time <= Self.returnWindow }
    }
}

/// Item-level updates for a batch that animates single tiles: which tiles leave and which come, by index path, for a
/// change between two models whose sections otherwise stay. Nil when the change is more than that (tiles reordered,
/// placeholders, too many tiles) — the grid then applies the section change without animation.
struct GridItemChanges: Equatable {
    /// Sections of the old model that are gone (their tiles leave with them).
    var deletedSections = IndexSet()
    /// Sections of the new model that are new.
    var insertedSections = IndexSet()
    /// Tiles that leave, by their place in the old model.
    var deletedItems: [IndexPath] = []
    /// Tiles that come, by their place in the new model.
    var insertedItems: [IndexPath] = []
    /// Sections (new indexes) whose header may read differently (a month's first day changed).
    var headerChanges = IndexSet()
    /// The ids of the tiles that leave and come.
    var gone: [FileID] = []
    var back: [FileID] = []

    /// More tiles than this in one change are not animated one by one.
    static let limit = 400

    static func make(old: GridModel, new: GridModel, changes: GridModel.SectionChanges, limit: Int = limit) -> GridItemChanges? {
        var result = GridItemChanges(deletedSections: changes.deleted, insertedSections: changes.inserted)
        var newIndexById: [Int: Int] = [:]
        for (index, section) in new.sections.enumerated() { newIndexById[section.id] = index }
        var count = 0
        for oldIndex in changes.deleted {
            guard let section = old.sections[safe: oldIndex], section.placeholders == 0 else { return nil }
            result.gone += old.items[section.range].map(\.fileId)
            count += section.range.count
        }
        for newIndex in changes.inserted {
            guard let section = new.sections[safe: newIndex], section.placeholders == 0 else { return nil }
            result.back += new.items[section.range].map(\.fileId)
            count += section.range.count
        }
        for oldIndex in changes.reloaded {
            guard let before = old.sections[safe: oldIndex], let newIndex = newIndexById[before.id],
                let after = new.sections[safe: newIndex], before.placeholders == 0, after.placeholders == 0
            else { return nil }
            let oldIds = old.items[before.range].map(\.fileId)
            let newIds = new.items[after.range].map(\.fileId)
            let oldSet = Set(oldIds)
            let newSet = Set(newIds)
            // What stays must stay in its order: a move is not a leave.
            guard oldIds.filter(newSet.contains) == newIds.filter(oldSet.contains) else { return nil }
            for (item, id) in oldIds.enumerated() where !newSet.contains(id) {
                result.deletedItems.append(IndexPath(item: item, section: oldIndex))
                result.gone.append(id)
            }
            for (item, id) in newIds.enumerated() where !oldSet.contains(id) {
                result.insertedItems.append(IndexPath(item: item, section: newIndex))
                result.back.append(id)
            }
            if before.kind != after.kind || before.date != after.date || before.startsMonth != after.startsMonth
                || before.year != after.year
            {
                result.headerChanges.insert(newIndex)
            }
            count += oldIds.count - oldSet.intersection(newSet).count + newIds.count - newSet.intersection(oldSet).count
        }
        guard count <= limit else { return nil }
        return result
    }
}

/// The screen's side of the action feedback: it says what the user just did, the platform grid plays it (SPEC §17.2).
@MainActor
final class GridActionMotion {
    private var expectations = GridActionExpectations()
    /// The grid's heart burst over the tiles on screen; set by the platform grid.
    var favorited: ([FileID]) -> Void = { _ in }

    var hasExpectations: Bool { !expectations.isEmpty }

    /// The user deleted (`collapse`) or archived / removed (`slide`) these tiles.
    func expectLeaving(_ ids: [FileID], style: GridLeaveStyle) {
        expectations.expectLeaving(ids, style: style, now: Self.now)
    }

    /// The style for a change of the grid (see `GridActionExpectations.style`).
    func style(gone: [FileID], back: [FileID]) -> GridLeaveStyle? {
        expectations.style(gone: gone, back: back, now: Self.now)
    }

    /// These tiles were just made favourites.
    func favorite(_ ids: [FileID]) { favorited(ids) }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - Video tiles

/// What a video tile's glass capsule shows at a tile width (SPEC §17.2): the duration, only the camera glyph on small
/// tiles, nothing on the smallest.
enum GridVideoPillLayout: Equatable {
    case hidden, icon, duration

    static func layout(tileWidth: Double) -> GridVideoPillLayout {
        if tileWidth >= 64 { return .duration }
        return tileWidth >= 34 ? .icon : .hidden
    }
}
