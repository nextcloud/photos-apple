// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel

/// A section of the grid: a range of the flat item list. Titles are formatted by the UI, and only for visible headers.
public struct GridSection: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// One section without a header (albums, places, search results).
        case flat
        case day, month, year
    }

    /// `YYYYMMDD`, `YYYYMM` or `YYYY` in the local calendar; 0 for the flat section.
    public var id: Int
    public var kind: Kind
    public var date: Date
    /// Day sections: the newest day of its month, whose header also carries the month title.
    public var startsMonth: Bool
    public var year: Int?
    /// Range into `GridModel.items`.
    public var range: Range<Int>

    public init(id: Int, kind: Kind, date: Date, startsMonth: Bool, year: Int?, range: Range<Int>) {
        self.id = id
        self.kind = kind
        self.date = date
        self.startsMonth = startsMonth
        self.year = year
        self.range = range
    }
}

/// How a grid cuts its items into sections.
public enum GridSectioning: Sendable, Hashable {
    case flat
    case timeline(TimelineGranularity)
}

/// What the platform grids show: the items of a query (newest first), their sections and an index by file id.
///
/// A value type that is built off the main actor (`GridModel.init` is the expensive part) and handed to the
/// collection view as a whole; the collection view data sources only read ranges from it.
public struct GridModel: Sendable {
    public private(set) var items: [GridMedia]
    public private(set) var sections: [GridSection]
    public private(set) var sectioning: GridSectioning
    private var indexById: [FileID: Int]

    public static let empty = GridModel(items: [], sectioning: .flat)

    public init(items: [GridMedia], sectioning: GridSectioning, calendar: Calendar = .current) {
        self.items = items
        self.sectioning = sectioning
        sections = Self.makeSections(items, sectioning: sectioning, calendar: calendar)
        var index: [FileID: Int] = [:]
        index.reserveCapacity(items.count)
        for (position, item) in items.enumerated() where index[item.fileId] == nil { index[item.fileId] = position }
        indexById = index
    }

    /// The same items cut differently (zoom changed the granularity): only the sections are rebuilt.
    public func resectioned(_ sectioning: GridSectioning, calendar: Calendar = .current) -> GridModel {
        guard sectioning != self.sectioning else { return self }
        var copy = self
        copy.sectioning = sectioning
        copy.sections = Self.makeSections(items, sectioning: sectioning, calendar: calendar)
        return copy
    }

    static func makeSections(_ items: [GridMedia], sectioning: GridSectioning, calendar: Calendar) -> [GridSection] {
        switch sectioning {
        case .flat:
            guard !items.isEmpty, let first = items.first else { return [] }
            return [GridSection(id: 0, kind: .flat, date: first.timestamp, startsMonth: false, year: nil, range: 0..<items.count)]
        case .timeline(let granularity):
            let months = TimelineSections.group(items, calendar: calendar) { $0.timestamp }
            return TimelineSections.sections(of: months, granularity: granularity).map { section in
                let kind: GridSection.Kind =
                    switch section.granularity {
                    case .day: .day
                    case .month: .month
                    case .year: .year
                    }
                return GridSection(
                    id: section.id, kind: kind, date: section.date, startsMonth: section.startsMonth, year: section.year,
                    range: section.range)
            }
        }
    }

    // MARK: Lookup

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var hasHeaders: Bool { sectioning != .flat }

    /// File ids in display order (viewer context).
    public var ids: [FileID] { items.map(\.fileId) }

    public subscript(id: FileID) -> GridMedia? {
        indexById[id].map { items[$0] }
    }

    public func item(section: Int, item: Int) -> GridMedia? {
        guard sections.indices.contains(section) else { return nil }
        let range = sections[section].range
        let index = range.lowerBound + item
        return item >= 0 && index < range.upperBound ? items[index] : nil
    }

    public func numberOfItems(inSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].range.count : 0
    }

    /// Position of a flat index as (section, item).
    public func position(ofIndex index: Int) -> (section: Int, item: Int)? {
        guard items.indices.contains(index), !sections.isEmpty else { return nil }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sections[mid].range.upperBound <= index { low = mid + 1 } else { high = mid }
        }
        let range = sections[low].range
        return range.contains(index) ? (low, index - range.lowerBound) : nil
    }

    public func position(of id: FileID) -> (section: Int, item: Int)? {
        indexById[id].flatMap(position(ofIndex:))
    }

    public func flatIndex(section: Int, item: Int) -> Int? {
        guard sections.indices.contains(section) else { return nil }
        let index = sections[section].range.lowerBound + item
        return sections[section].range.contains(index) ? index : nil
    }

    /// Sections that start a year, newest first (year index, scrubber ticks).
    public var yearStarts: [(year: Int, section: Int)] {
        var result: [(Int, Int)] = []
        for (index, section) in sections.enumerated() {
            guard let year = section.year, result.last?.0 != year else { continue }
            result.append((year, index))
        }
        return result
    }

    // MARK: Changes

    /// What a collection view has to do to get from one model to the next.
    public enum Change: Sendable, Equatable {
        case none
        /// Same items in the same sections; these changed their content (favourite, etag…): reconfigure them.
        case content(Set<FileID>)
        /// Some sections came, went or hold other items; all others are as before. A collection view applies this as a
        /// batch update of those sections instead of reloading everything (an upload adds a photo to today's section).
        case sections(SectionChanges)
        /// Too much changed, or the sectioning did: reload.
        case structure
    }

    /// The sections that differ between two models with the same sectioning.
    public struct SectionChanges: Sendable, Equatable {
        /// Sections of the old model that are gone (old indexes).
        public var deleted: IndexSet
        /// Sections of the new model that are new (new indexes).
        public var inserted: IndexSet
        /// Sections of both whose items or header changed (old indexes, as a batch update wants them).
        public var reloaded: IndexSet
        /// Items whose content changed in sections that are otherwise the same.
        public var content: Set<FileID>

        public init(deleted: IndexSet = [], inserted: IndexSet = [], reloaded: IndexSet = [], content: Set<FileID> = []) {
            self.deleted = deleted
            self.inserted = inserted
            self.reloaded = reloaded
            self.content = content
        }

        public var sectionCount: Int { deleted.count + inserted.count + reloaded.count }
    }

    /// Above this many changed sections a reload is not slower than the batch update and easier on the view.
    static func maxSectionChanges(sections: Int) -> Int { max(64, sections / 8) }

    public func change(from old: GridModel) -> Change {
        if old.items.count == items.count, old.sections == sections {
            var changed: Set<FileID> = []
            var same = true
            for index in items.indices {
                let before = old.items[index]
                let after = items[index]
                if before.fileId != after.fileId {
                    same = false
                    break
                }
                if before != after { changed.insert(after.fileId) }
            }
            if same { return changed.isEmpty ? .none : .content(changed) }
        }
        return sectionChange(from: old)
    }

    /// Compares the sections by id. Both lists are in display order, so their ids go strictly down (dates, newest first)
    /// and one merge pass finds what came, went or changed.
    func sectionChange(from old: GridModel) -> Change {
        guard old.sectioning == sectioning, !old.sections.isEmpty, !sections.isEmpty, Self.idsDescend(old.sections),
            Self.idsDescend(sections)
        else { return .structure }
        var changes = SectionChanges()
        let limit = Self.maxSectionChanges(sections: sections.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.sections.count || newIndex < sections.count {
            if oldIndex < old.sections.count, newIndex < sections.count, old.sections[oldIndex].id == sections[newIndex].id {
                let before = old.sections[oldIndex]
                let after = sections[newIndex]
                if before.kind != after.kind || before.date != after.date || before.startsMonth != after.startsMonth
                    || before.year != after.year || before.range.count != after.range.count
                {
                    changes.reloaded.insert(oldIndex)
                } else {
                    var reload = false
                    var content: [FileID] = []
                    for offset in 0..<after.range.count {
                        let previous = old.items[before.range.lowerBound + offset]
                        let next = items[after.range.lowerBound + offset]
                        if previous.fileId != next.fileId {
                            reload = true
                            break
                        }
                        if previous != next { content.append(next.fileId) }
                    }
                    if reload { changes.reloaded.insert(oldIndex) } else { changes.content.formUnion(content) }
                }
                oldIndex += 1
                newIndex += 1
            } else if newIndex >= sections.count || (oldIndex < old.sections.count && old.sections[oldIndex].id > sections[newIndex].id) {
                changes.deleted.insert(oldIndex)
                oldIndex += 1
            } else {
                changes.inserted.insert(newIndex)
                newIndex += 1
            }
            if changes.sectionCount > limit { return .structure }
        }
        if changes.sectionCount == 0 { return changes.content.isEmpty ? .none : .content(changes.content) }
        return .sections(changes)
    }

    static func idsDescend(_ sections: [GridSection]) -> Bool {
        zip(sections, sections.dropFirst()).allSatisfy { $0.id > $1.id }
    }
}
