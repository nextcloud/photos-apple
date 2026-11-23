// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Lightweight input for stacking (timeline items, newest first).
public struct StackInput: Hashable, Sendable {
    public var fileId: FileID
    public var name: String
    public var directory: String
    public var timestamp: Date
    public var mimeType: String
    public var isVideo: Bool

    public init(fileId: FileID, name: String, directory: String, timestamp: Date, mimeType: String, isVideo: Bool) {
        self.fileId = fileId
        self.name = name
        self.directory = directory
        self.timestamp = timestamp
        self.mimeType = mimeType
        self.isVideo = isVideo
    }
}

/// A stack: the leader is shown, members are hidden behind it (SPEC TL-6).
public struct Stack: Hashable, Sendable {
    public var leader: FileID
    public var members: [FileID]
}

/// Shot variants and bursts (web: src/utils/shotVariants.ts, burstClustering.ts).
public enum Stacks {
    public static let burstGap: TimeInterval = 3
    public static let burstMinimum = 2

    /// Normalised shot name: lower-cased, NFC, edit suffixes stripped, `IMG_E1234` → `img_1234`.
    public static func shotName(_ fileName: String) -> String {
        var base = ((fileName as NSString).deletingPathExtension as String).precomposedStringWithCanonicalMapping.lowercased()
        if let match = base.wholeMatch(of: /([a-z]{3})_e(\d+)/) { base = "\(match.1)_\(match.2)" }
        var changed = true
        while changed {
            changed = false
            for pattern in [#"\s*\(edited\)$"#, #"[-_ ](edited|bearbeitet|modifié|editado|modificato|bewerkt)$"#, #"~\d+$"#] {
                if let range = base.range(of: pattern, options: .regularExpression) {
                    base.removeSubrange(range)
                    changed = true
                }
            }
        }
        return base
    }

    static func isEdited(_ fileName: String) -> Bool {
        let base = ((fileName as NSString).deletingPathExtension as String).lowercased()
        return shotName(fileName) != base.precomposedStringWithCanonicalMapping || base.wholeMatch(of: /[a-z]{3}_e\d+/) != nil
    }

    /// Leader rank, lower is better: video +4, edited… (non-edited +2 means edited is preferred), non-JPEG +1.
    static func rank(_ item: StackInput) -> Int {
        var rank = 0
        if item.isVideo { rank += 4 }
        if !isEdited(item.name) { rank += 2 }
        if item.mimeType != "image/jpeg" { rank += 1 }
        return rank
    }

    /// Groups shot variants by folder + shot name, then bursts (≤ 3 s apart, ≥ 2) over the leaders.
    public static func stacks(_ items: [StackInput]) -> [Stack] {
        // 1. Variants
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            groups[item.directory + "/" + shotName(item.name), default: []].append(index)
        }
        var leaderOf: [Int: Int] = [:]
        var variants: [Int: [Int]] = [:]
        for indices in groups.values where indices.count > 1 {
            let leader = indices.min { (rank(items[$0]), $0) < (rank(items[$1]), $1) }!
            variants[leader] = indices
            for index in indices { leaderOf[index] = leader }
        }
        let leaders = items.indices.filter { leaderOf[$0] == nil || leaderOf[$0] == $0 }
        // 2. Bursts over leaders (newest first input: compare with the previous member).
        var result: [Stack] = []
        var run: [Int] = []
        func flushRun() {
            if run.count >= burstMinimum {
                let members = run.flatMap { variants[$0] ?? [$0] }
                result.append(Stack(leader: items[run[0]].fileId, members: members.map { items[$0].fileId }))
            } else {
                for leader in run where (variants[leader]?.count ?? 0) > 1 {
                    result.append(Stack(leader: items[leader].fileId, members: variants[leader]!.map { items[$0].fileId }))
                }
            }
            run = []
        }
        for index in leaders {
            if let previous = run.last, !items[index].isVideo, !items[previous].isVideo,
                abs(items[previous].timestamp.timeIntervalSince(items[index].timestamp)) <= burstGap
            {
                run.append(index)
            } else {
                flushRun()
                run = [index]
            }
        }
        flushRun()
        return result
    }
}

/// Exact duplicates by size + capture time + dimensions (SPEC §7.15; web: duplicates.ts).
public enum Duplicates {
    public struct Group: Hashable, Sendable, Identifiable {
        public var id: String
        public var items: [FileID]
        public var wastedBytes: Int64
    }

    public static func groups(_ items: [MediaItem]) -> [Group] {
        var buckets: [String: [MediaItem]] = [:]
        for item in items where item.size > 0 {
            guard let captured = item.capturedAt, let width = item.width, let height = item.height else { continue }
            buckets["\(item.size)-\(Int64(captured.timeIntervalSince1970))-\(width)x\(height)", default: []].append(item)
        }
        return buckets.compactMap { key, members in
            guard members.count >= 2 else { return nil }
            let sorted = members.sorted { $0.path < $1.path }
            return Group(id: key, items: sorted.map(\.fileId), wastedBytes: sorted.dropFirst().reduce(0) { $0 + $1.size })
        }
        .sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// Why a copy is the one suggested to keep.
    public enum KeepReason: Hashable, Sendable {
        /// The only copy marked as favourite.
        case favorite
        /// The other copies are shared with the user or cannot be deleted by them; this is the user's own file.
        case ownFile
        /// The copy that has been on the server the longest.
        case oldest
        /// No difference found: the first by path.
        case firstByPath
    }

    public struct Keeper: Hashable, Sendable {
        public var fileId: FileID
        public var reason: KeepReason
    }

    /// The copy suggested to keep (SPEC §7.15 "keep the best"): the favourite, else the user's own file, else the copy
    /// that has been on the server the longest, else the first by path. The user can pick another one.
    public static func keeper(of copies: [MediaItem]) -> Keeper? {
        guard let first = copies.min(by: { $0.path < $1.path }) else { return nil }
        let favorites = copies.filter(\.isFavorite)
        if favorites.count == 1, copies.count > 1 { return Keeper(fileId: favorites[0].fileId, reason: .favorite) }
        let pool = favorites.isEmpty ? copies : favorites
        let own = pool.filter { $0.isOwnStorage && $0.permissions.canDelete }
        if own.count == 1, pool.count > 1 { return Keeper(fileId: own[0].fileId, reason: .ownFile) }
        let candidates = (own.isEmpty ? pool : own).sorted { $0.path < $1.path }
        let dates = candidates.map { $0.uploadedAt ?? $0.modifiedAt }
        if let oldest = dates.min(), dates.filter({ $0 == oldest }).count == 1, let index = dates.firstIndex(of: oldest) {
            return Keeper(fileId: candidates[index].fileId, reason: .oldest)
        }
        return Keeper(fileId: candidates.first?.fileId ?? first.fileId, reason: .firstByPath)
    }
}
