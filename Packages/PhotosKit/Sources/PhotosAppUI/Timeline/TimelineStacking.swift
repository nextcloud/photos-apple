// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// The library's display options that only concern this device.
enum TimelineDisplay {
    /// Copies of one shot (HEIC + JPEG, RAW + JPEG) are one tile in the timeline (`CopyStacks`). On by default.
    static let stackCopiesKey = "stackCopies"
    /// The memories strip at the top of the library. On by default.
    static let showsMemoriesKey = "showsMemoriesStrip"
}

/// Puts the copies of one shot behind one tile of the timeline (SPEC TL-6, `CopyStacks`).
enum TimelineStacking {
    /// The timeline with every stack shown as one tile, at the place of its newest copy. The tile is the copy
    /// `CopyStacks` shows first, with `GridMedia.stack` listing all copies.
    static func collapse(_ items: [GridMedia]) -> [GridMedia] {
        let stacks: [[Int]] = CopyStacks.stacks(items)
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

/// The library's options of this device, in Settings.
struct TimelineDisplaySection: View {
    @AppStorage(TimelineDisplay.stackCopiesKey) private var stackCopies = true
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true

    var body: some View {
        Section {
            Toggle(String(localized: "Show memories", bundle: .module), isOn: $showsMemories)
            Toggle(String(localized: "Stack copies of a photo", bundle: .module), isOn: $stackCopies)
        } header: {
            Text("On this device", bundle: .module)
        } footer: {
            Text(
                "A photo saved as HEIC and JPEG, or as RAW and JPEG, is shown once, with a stack badge. Open it to see every copy.",
                bundle: .module)
        }
    }
}
