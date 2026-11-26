// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import OSLog
import Synchronization

/// How long the Library took to appear after the process started (SPEC §10, "cold launch → cached timeline visible";
/// SPEC §20.6).
///
/// The grid reports every tile that gets its first real picture (through `CacheMetrics.finish`); the first one and the
/// `firstScreenTiles`-th one are logged once per process with the time since the process started, as `notice` in the
/// subsystem `com.nextcloud.photos`, category `performance`, and as signpost events for Instruments. Read them with
/// `log show --predicate 'subsystem == "com.nextcloud.photos" AND category == "performance"'` (in the simulator through
/// `xcrun simctl spawn <device> log show …`); `scripts/measure-performance.sh` does that.
///
/// The process start comes from the kernel (`sysctl` `KERN_PROC_PID`), so the time includes what happens before
/// `main`. Two log lines per launch and a counter under an uncontended lock: cheap enough to stay on in release builds.
public final class LaunchMetrics: Sendable {
    public static let shared = LaunchMetrics(processStart: LaunchMetrics.processStartDate())

    /// Tiles with a picture after which the first screen counts as shown: about the first screen of an iPhone at the
    /// default zoom level (fewer than a Mac or iPad window shows, so there it is a little early).
    public static let firstScreenTiles = 24

    public enum Milestone: String, Sendable, Equatable {
        /// The first tile with a real picture (not only its BlurHash).
        case firstPicture = "first picture"
        /// `firstScreenTiles` tiles with real pictures.
        case firstScreen = "first screen"
    }

    /// Steps on the way to the first picture, logged once per process like the milestones ("Launch: <step> after N
    /// ms"), so a slow launch shows where the time went (docs/PERFORMANCE.md).
    public enum Step: String, Sendable, CaseIterable {
        /// The app's own code runs (the app delegate): what came before was the system and the dynamic loader.
        case appCode = "app code"
        /// The app model, its accounts and the active session exist.
        case appModel = "app model"
        /// The window's main view appeared: its first SwiftUI update is done, the pictures are not drawn yet.
        case mainView = "main view"
        /// The Library's grid received its first items from the store.
        case libraryData = "library data"
    }

    private struct State {
        var tiles = 0
        var firstPicture: Double?
        var firstScreen: Double?
        var steps: [Step: Double] = [:]
    }

    private let state = Mutex(State())
    private let processStart: Date?
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "performance")
    private static let signposter = OSSignposter(subsystem: "com.nextcloud.photos", category: "performance")

    public init(processStart: Date?) {
        self.processStart = processStart
    }

    /// A grid tile shows its first real picture. Returns the milestone this reached and its time in milliseconds since
    /// the process started, once per milestone and process.
    @discardableResult
    public func tileShown(now: Date = Date()) -> (milestone: Milestone, milliseconds: Double)? {
        guard let processStart else { return nil }
        let milliseconds = now.timeIntervalSince(processStart) * 1000
        let reached: Milestone? = state.withLock { state in
            state.tiles += 1
            switch state.tiles {
            case 1:
                state.firstPicture = milliseconds
                return .firstPicture
            case Self.firstScreenTiles:
                state.firstScreen = milliseconds
                return .firstScreen
            default:
                return nil
            }
        }
        guard let reached else { return nil }
        let rounded = Int(milliseconds.rounded())
        Self.logger.notice("Launch: \(reached.rawValue, privacy: .public) after \(rounded, privacy: .public) ms")
        if Self.signposter.isEnabled {
            Self.signposter.emitEvent("Launch milestone", "\(reached.rawValue, privacy: .public) \(rounded) ms")
        }
        return (reached, milliseconds)
    }

    /// A step on the way to the first picture was reached. Returns its time in milliseconds since the process started the
    /// first time, nil afterwards (and when the process start is unknown).
    @discardableResult
    public func reached(_ step: Step, now: Date = Date()) -> Double? {
        guard let processStart else { return nil }
        let milliseconds = now.timeIntervalSince(processStart) * 1000
        let isFirst = state.withLock { state in
            guard state.steps[step] == nil else { return false }
            state.steps[step] = milliseconds
            return true
        }
        guard isFirst else { return nil }
        let rounded = Int(milliseconds.rounded())
        Self.logger.notice("Launch: \(step.rawValue, privacy: .public) after \(rounded, privacy: .public) ms")
        if Self.signposter.isEnabled {
            Self.signposter.emitEvent("Launch step", "\(step.rawValue, privacy: .public) \(rounded) ms")
        }
        return milliseconds
    }

    /// The steps reached so far, in milliseconds since the process started.
    public var steps: [Step: Double] {
        state.withLock { $0.steps }
    }

    /// The milestones reached so far, in milliseconds since the process started.
    public var milestones: (firstPicture: Double?, firstScreen: Double?) {
        state.withLock { ($0.firstPicture, $0.firstScreen) }
    }

    /// When this process was started, according to the kernel; nil if it cannot be read.
    public static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
