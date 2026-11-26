// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The parts of the preview cache that sizes compete in (SPEC §18.2): a 4096 px preview takes the room of a hundred
/// thumbnails, so large previews must not push out the thumbnails the grids need.
public enum CachePool: Int, Sendable, CaseIterable, Comparable {
    /// 64 and 256 px: grid tiles, covers, the Years and Months levels.
    case thumbnails
    /// 1024 px (and anything else up to 2048 px): the viewer, large tiles, cards.
    case screen
    /// 4096 px: the viewer zoomed in.
    case large

    public init(bucket: Int) {
        switch bucket {
        case 1...256: self = .thumbnails
        case 2049...: self = .large
        default: self = .screen
        }
    }

    public static func < (lhs: CachePool, rhs: CachePool) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the preview cache's limit is shared between the pools.
///
/// Large previews get 15 % of the limit and never more than `largeCap` (300 MB); that part is a hard cap. Thumbnails and
/// screen-size previews share the rest half and half: each may use room the other leaves free, and when the cache is
/// over its limit, the pool furthest over its share gives back first.
public struct CachePoolBudgets: Sendable, Equatable {
    public static let largeCap: Int64 = 300 * 1024 * 1024

    public var total: Int64
    public var thumbnails: Int64
    public var screen: Int64
    public var large: Int64

    public init(total: Int64) {
        let total = max(0, total)
        self.total = total
        large = min(Self.largeCap, total * 15 / 100)
        thumbnails = (total - large) / 2
        screen = total - large - thumbnails
    }

    public subscript(pool: CachePool) -> Int64 {
        switch pool {
        case .thumbnails: thumbnails
        case .screen: screen
        case .large: large
        }
    }
}

/// Which files of the preview cache go when it is over its limit (SPEC §18.2). Pure, so it is unit-tested; the cache
/// feeds it one entry per file of its folder.
public enum CacheEviction {
    public struct File: Sendable, Hashable {
        public var size: Int64
        /// When it was last used (the file's modification date).
        public var lastUsed: Date
        public var pool: CachePool
        /// `CacheImportance.tier` of its photo: lower goes first.
        public var tier: UInt8
        /// Never removed, but counts towards the limit (previews of offline albums).
        public var isKept: Bool
        /// Never removed and not counted (thumbnails of the whole library, when the user asked to keep them).
        public var isExempt: Bool

        public init(size: Int64, lastUsed: Date, pool: CachePool, tier: UInt8 = 0, isKept: Bool = false, isExempt: Bool = false) {
            self.size = size
            self.lastUsed = lastUsed
            self.pool = pool
            self.tier = tier
            self.isKept = isKept
            self.isExempt = isExempt
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Indexes into the files, in the order they go.
        public var removals: [Int]
        /// Bytes that count towards the limit after the removals.
        public var remaining: Int64
    }

    /// What to remove so that the cache keeps within `budgets`.
    ///
    /// 1. Large previews above their cap go, whatever the total.
    /// 2. While the total is over the limit, the pool furthest over its share gives one file; when no pool is over its
    ///    share (kept files take the room), the least important file of any pool goes.
    ///
    /// Within a pool the least important file goes first (`tier`), the least recently used among equals. Runs in
    /// O(n log n) for the sort; 100 000 files take a few tens of milliseconds.
    public static func plan(_ files: [File], budgets: CachePoolBudgets) -> Plan {
        var totals: [Int64] = Array(repeating: 0, count: CachePool.allCases.count)
        var queues: [[Int]] = Array(repeating: [], count: CachePool.allCases.count)
        var keys: [[UInt64]] = Array(repeating: [], count: CachePool.allCases.count)
        for (index, file) in files.enumerated() where !file.isExempt {
            totals[file.pool.rawValue] += file.size
            guard !file.isKept else { continue }
            keys[file.pool.rawValue].append(sortKey(tier: file.tier, lastUsed: file.lastUsed, index: index))
        }
        for pool in CachePool.allCases {
            // One integer per file sorts fast (also in debug builds): tier, then last use, then position.
            queues[pool.rawValue] = keys[pool.rawValue].sorted().map { Int($0 & indexMask) }
        }
        var next = Array(repeating: 0, count: CachePool.allCases.count)
        var removals: [Int] = []
        var total = totals.reduce(0, +)

        func remove(from pool: CachePool) {
            let index = queues[pool.rawValue][next[pool.rawValue]]
            next[pool.rawValue] += 1
            removals.append(index)
            totals[pool.rawValue] -= files[index].size
            total -= files[index].size
        }
        func hasMore(_ pool: CachePool) -> Bool { next[pool.rawValue] < queues[pool.rawValue].count }

        while totals[CachePool.large.rawValue] > budgets.large, hasMore(.large) { remove(from: .large) }
        while total > budgets.total {
            let over = CachePool.allCases.filter { hasMore($0) && totals[$0.rawValue] > budgets[$0] }
            if let pool = over.max(by: { totals[$0.rawValue] - budgets[$0] < totals[$1.rawValue] - budgets[$1] }) {
                remove(from: pool)
                continue
            }
            // Every pool is within its share and the cache is still too large: the least important file of all goes.
            let candidates = CachePool.allCases.filter(hasMore)
            guard
                let pool = candidates.min(by: {
                    nextKey(of: $0, queues: queues, next: next, files: files) < nextKey(of: $1, queues: queues, next: next, files: files)
                })
            else { break }
            remove(from: pool)
        }
        return Plan(removals: removals, remaining: total)
    }

    private static let indexBits: UInt64 = 29
    private static let indexMask: UInt64 = (1 << indexBits) - 1

    /// Tier (3 bits), last use in seconds since 2001 (32 bits), index (29 bits).
    static func sortKey(tier: UInt8, lastUsed: Date, index: Int) -> UInt64 {
        let seconds = UInt64(min(max(0, lastUsed.timeIntervalSinceReferenceDate), Double(UInt32.max)))
        return UInt64(min(tier, 7)) << 61 | seconds << indexBits | (UInt64(index) & indexMask)
    }

    private static func nextKey(of pool: CachePool, queues: [[Int]], next: [Int], files: [File]) -> UInt64 {
        let index = queues[pool.rawValue][next[pool.rawValue]]
        return sortKey(tier: files[index].tier, lastUsed: files[index].lastUsed, index: index)
    }
}

/// What the decoded previews in memory give back when the system runs short of memory (SPEC §18.2), instead of all of
/// them: what is on screen stays, so the grid does not go blank and the viewer does not flash.
///
/// - The viewer's photo keeps every size on a warning; on a critical warning its zoomed-in decode (above 1024 px) goes.
/// - Its neighbours keep decodes up to 1024 px on a warning, only tile-size ones on a critical warning.
/// - Protected photos (covers, key photos, memory covers) keep their tile-size decodes.
/// - Of the other tile-size decodes (`tileSize` px at most), the most recently used stay within a quarter of the memory
///   budget on a warning, a tenth on a critical one: these are the tiles on screen.
/// - Everything else goes: 4096 and 1024 decodes first of all.
public enum MemoryPressurePolicy {
    public enum Level: Sendable { case warning, critical }

    /// Decodes up to this long edge are grid tiles and covers.
    public static let tileSize = 512

    public struct Entry: Sendable, Hashable {
        public var fileId: FileID
        /// The long edge it was decoded to at most.
        public var decodedSize: Int
        /// Bytes it takes.
        public var cost: Int

        public init(fileId: FileID, decodedSize: Int, cost: Int) {
            self.fileId = fileId
            self.decodedSize = decodedSize
            self.cost = cost
        }
    }

    /// The photo the viewer shows and the ones next to it.
    public struct Focus: Sendable, Equatable {
        public var current: FileID?
        public var neighbours: Set<FileID>

        public init(current: FileID? = nil, neighbours: Set<FileID> = []) {
            self.current = current
            self.neighbours = neighbours
        }
    }

    /// For each entry (most recently used first), whether it stays.
    public static func survivors(_ entries: [Entry], level: Level, limit: Int, protected: Set<FileID>, focus: Focus) -> [Bool] {
        var tileBytes = 0
        let tileBudget = level == .warning ? limit / 4 : limit / 10
        return entries.map { entry in
            let isTile = entry.decodedSize <= tileSize
            if entry.fileId == focus.current {
                return level == .warning || entry.decodedSize <= 1024
            }
            if focus.neighbours.contains(entry.fileId) {
                return level == .warning ? entry.decodedSize <= 1024 : isTile
            }
            guard isTile else { return false }
            if protected.contains(entry.fileId) { return true }
            guard tileBytes + entry.cost <= tileBudget else { return false }
            tileBytes += entry.cost
            return true
        }
    }
}
