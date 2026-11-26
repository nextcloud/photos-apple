// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization

/// What the viewer loads ahead of the photo shown (SPEC §18.1.2): the 1024 px previews of the two pages on each side,
/// the direction of paging first, and — on an inexpensive network — the 4096 px preview of the photo shown once it has
/// been looked at for a moment, so that zooming in finds it on disk.
public enum ViewerPrefetchPlan {
    /// How many pages on each side are loaded ahead.
    public static let reach = 2
    /// The bucket of the neighbours: what the viewer shows first.
    public static let neighbourBucket = 1024
    /// The bucket loaded for zooming, and how long a photo is shown before it is.
    public static let detailBucket = 4096
    public static let detailDelay: Duration = .seconds(3)
    /// The large preview loaded ahead is decoded no larger than this; zooming decodes it again from disk.
    public static let detailDecodeSize = 1024

    /// The indices of the pages to load ahead, most wanted first: the next `reach` pages in the direction of paging,
    /// then the ones behind. Pages outside `0..<count` are left out.
    public static func neighbours(of index: Int, count: Int, direction: Int, reach: Int = reach) -> [Int] {
        guard reach > 0 else { return [] }
        let ahead = direction < 0 ? -1 : 1
        let forward = (1...reach).map { index + ahead * $0 }
        let backward = (1...reach).map { index - ahead * $0 }
        return (forward + backward).filter { (0..<count).contains($0) }
    }

    /// The direction of paging from the page shown before (+1 when the viewer has just opened).
    public static func direction(from previous: Int?, to index: Int) -> Int {
        guard let previous, previous != index else { return 1 }
        return index > previous ? 1 : -1
    }

    /// Whether the large preview of the photo shown is loaded ahead: not on cellular or a personal hotspot, not in Low
    /// Data Mode and not in Low Power Mode.
    public static func loadsDetail(isExpensive: Bool, isConstrained: Bool, isLowPower: Bool) -> Bool {
        !isExpensive && !isConstrained && !isLowPower
    }

    /// The same for the network the device is on now.
    public static var loadsDetailNow: Bool {
        let network = NetworkCost.shared.current
        return loadsDetail(
            isExpensive: network.isExpensive, isConstrained: network.isConstrained,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Whether the current network costs the user (cellular, hotspot, Low Data Mode), followed from the first use on.
public final class NetworkCost: Sendable {
    public static let shared = NetworkCost()

    public struct State: Sendable, Equatable {
        public var isExpensive = false
        public var isConstrained = false
    }

    private let state = Mutex(State())
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.withLock { $0 = State(isExpensive: path.isExpensive, isConstrained: path.isConstrained) }
        }
        monitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.networkcost", qos: .utility))
    }

    deinit { monitor.cancel() }

    public var current: State { state.withLock { $0 } }
}
