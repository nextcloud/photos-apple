// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// The library's display options that only concern this device.
enum TimelineDisplay {
    /// Copies of one shot (HEIC + JPEG, RAW + JPEG) and bursts the camera marked are one tile in the timeline
    /// (`TimelineStacks`). On by default.
    static let stackCopiesKey = "stackCopies"
    /// The memories strip at the top of the library. On by default.
    static let showsMemoriesKey = "showsMemoriesStrip"
}

/// Puts the copies of one shot, and the frames of a burst, behind one tile of the timeline (SPEC TL-6,
/// `TimelineStacks`).
enum TimelineStacking {
    /// The timeline with every stack shown as one tile, at the place of its newest member. The tile is the member
    /// `TimelineStacks` shows first, with `GridMedia.stack` listing all members.
    static func collapse(_ items: [GridMedia]) -> [GridMedia] {
        let stacks: [[Int]] = TimelineStacks.stacks(items)
        guard !stacks.isEmpty else { return items }
        var hidden = Set<Int>()
        var tiles: [Int: GridMedia] = [:]
        for stack in stacks {
            guard let first = stack.min(), let leaderIndex = stack.first else { continue }
            var leader = items[leaderIndex]
            leader.stack = stack.map { items[$0].fileId }
            tiles[first] = leader
            for index in stack where index != first { hidden.insert(index) }
        }
        var result: [GridMedia] = []
        result.reserveCapacity(items.count - hidden.count)
        for index in items.indices where !hidden.contains(index) {
            result.append(tiles[index] ?? items[index])
        }
        return result
    }

    /// The stacks of a grid by the id of the tile that stands for each: what the viewer needs to open one.
    static func stacks(in items: [GridMedia]) -> [FileID: [FileID]] {
        var result: [FileID: [FileID]] = [:]
        for item in items where item.stack.count > 1 { result[item.fileId] = item.stack }
        return result
    }

    /// A grid query whose results are stacked, off the main actor.
    static func stacked(_ upstream: @escaping @Sendable () -> GridStream) -> @Sendable () -> GridStream {
        {
            let (stream, continuation) = GridStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await items in upstream() {
                        try Task.checkCancellation()
                        continuation.yield(collapse(items))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }
}

/// Actions on stacked tiles (SPEC TL-6): as in Apple Photos, where the RAW and JPEG of a shot are one photo and a
/// burst is one item, deleting, favouriting, archiving, adding to an album, tagging or redating a tile does it to
/// everything stacked behind it, so no copy is left behind as a tile of its own. What works on one file (open, info,
/// edit, share, export) stays with the copy the tile shows.
enum StackedSelection {
    /// `tiles` with the members of their stacks, in order and each once: a tile's own id first, then the rest of its
    /// stack. `stack` gives the members of a tile (empty when it is not a stack).
    static func members(of tiles: [FileID], stack: (FileID) -> [FileID]) -> [FileID] {
        var seen = Set<FileID>()
        seen.reserveCapacity(tiles.count)
        var result: [FileID] = []
        result.reserveCapacity(tiles.count)
        for tile in tiles {
            if seen.insert(tile).inserted { result.append(tile) }
            for member in stack(tile) where seen.insert(member).inserted { result.append(member) }
        }
        return result
    }

    /// How many of `items` are not among the selected `tiles`, i.e. stacked behind them (the confirmation says so).
    static func hiddenCount(_ items: [FileID], tiles: [FileID]) -> Int {
        let shown = Set(tiles)
        return items.reduce(0) { $0 + (shown.contains($1) ? 0 : 1) }
    }
}

/// The library's options of this device, in Settings.
struct TimelineDisplaySection: View {
    @AppStorage(TimelineDisplay.stackCopiesKey) private var stackCopies = true
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true
    @AppStorage(TileStyle.squareTilesKey) private var squareTiles = true
    @AppStorage(MemoriesStyle.key) private var memoriesStyle = MemoriesStyle.stories
    @AppStorage(TimelineDisplay.showsMomentsKey) private var showsMoments = true

    var body: some View {
        Section {
            Toggle(String(localized: "Show memories", bundle: .module), isOn: $showsMemories)
            if showsMemories {
                Picker(
                    String(localized: "Memories", bundle: .module, comment: "Settings: how memories are shown at the top of the library."),
                    selection: $memoriesStyle
                ) {
                    ForEach(MemoriesStyle.allCases) { style in Text(style.title).tag(style) }
                }
            }
            Toggle(
                String(
                    localized: "Name moments", bundle: .module,
                    comment: "Settings: moment titles such as Sunday in Lisbon on the library's days."),
                isOn: $showsMoments)
            Toggle(String(localized: "Square tiles", bundle: .module), isOn: $squareTiles)
            Toggle(String(localized: "Stack copies of a photo", bundle: .module), isOn: $stackCopies)
        } header: {
            Text("On this device", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "A photo saved as HEIC and JPEG, or as RAW and JPEG, is shown once, with a stack badge, and so is a burst that the camera named as one. Open it to see every photo.",
                    bundle: .module)
                Text(
                    "Moments name days away and days with the people you named, such as “Sunday in Lisbon”, from what this device knows about your photos.",
                    bundle: .module, comment: "Settings footer, after the explanation of stacks.")
            }
        }
    }
}
