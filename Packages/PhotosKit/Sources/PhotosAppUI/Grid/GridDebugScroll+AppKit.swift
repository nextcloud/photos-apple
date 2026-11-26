// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS) && DEBUG
    import AppKit
    import OSLog
    import PhotosMedia
    import QuartzCore

    /// Scrolling measured without the real trackpad (SPEC §20.6, `scripts/measure-performance.sh`):
    /// `PHOTOS_DEBUG_GRID_SCROLL=<points per second>[,<seconds>]` scrolls the Library grid of this process down at that
    /// speed for that long (default 8 s) and back up, one step per frame of the window's display link, 5 s after the
    /// grid first has items. The frame pacing (`FramePacing`) goes to `Library/Caches/scroll-metrics.json` and the log
    /// (category `performance`); the cache metrics of the run to `cache-metrics.json` next to it. Speed 0 does not
    /// scroll and does not reset the cache metrics: it only writes them after twice that many seconds (for the viewer
    /// opened with `PHOTOS_DEBUG_VIEWER`). The window must be visible for the pacing to mean anything: a covered window's
    /// display link is throttled; the report says which it was (`windowVisible`).
    @MainActor
    final class GridDebugScroll: NSObject {
        private static var used = false
        /// The run in progress (the display link does not keep its target alive on its own terms).
        private static var current: GridDebugScroll?
        private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "performance")

        private weak var grid: NSScrollView?
        private let speed: Double
        private let seconds: Double
        private var pacing = FramePacing()
        private var link: CADisplayLink?
        private var last: CFTimeInterval?
        private var elapsed: Double = 0
        /// A covered window gets fewer frames from its display link: the pacing then says little (no real input or
        /// activation is used to bring it to the front).
        private var windowWasVisible = false

        private init(grid: NSScrollView, speed: Double, seconds: Double) {
            self.grid = grid
            self.speed = speed
            self.seconds = seconds
        }

        static func runOnce(in grid: NSScrollView) {
            guard !used, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_GRID_SCROLL"], !raw.isEmpty else { return }
            used = true
            let values = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard let speed = values.first, speed >= 0 else { return }
            let run = GridDebugScroll(grid: grid, speed: speed, seconds: values.count > 1 ? values[1] : 8)
            current = run
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { run.start() }
        }

        private func start() {
            guard let grid else { return }
            // Speed 0: only the cache metrics, on a timer (a display link does not run while the window is covered).
            guard speed > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 2) { self.finish() }
                return
            }
            CacheMetrics.shared.reset()
            windowWasVisible = grid.window?.occlusionState.contains(.visible) ?? false
            let link = grid.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let grid, let document = grid.documentView else { return finish() }
            let interval = last.map { link.timestamp - $0 } ?? link.duration
            if last != nil { pacing.frame(interval: interval, nominal: link.duration) }
            last = link.timestamp
            elapsed += interval
            // Down for `seconds`, then up for as long; the grid is flipped (y grows downwards).
            let direction: Double = elapsed < seconds ? 1 : -1
            let clip = grid.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            let y = min(maxY, max(0, clip.bounds.origin.y + direction * speed * interval))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            grid.reflectScrolledClipView(clip)
            if elapsed >= seconds * 2 { finish() }
        }

        private func finish() {
            link?.invalidate()
            link = nil
            let caches = URL.cachesDirectory
            let report: [String: Double] = [
                "speedPointsPerSecond": speed, "seconds": pacing.seconds, "frames": Double(pacing.frames),
                "framesPerSecond": pacing.framesPerSecond, "nominalMilliseconds": pacing.nominalMilliseconds,
                "hitches": Double(pacing.hitches), "hitchMilliseconds": pacing.hitchMilliseconds,
                "hitchTimeRatio": pacing.hitchTimeRatio, "longestFrameMilliseconds": pacing.longestFrameMilliseconds,
                "windowVisible": windowWasVisible ? 1 : 0,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: caches.appending(path: "scroll-metrics.json"), options: .atomic)
            }
            CacheMetrics.shared.write(to: caches.appending(path: "cache-metrics.json"))
            let ratio = (pacing.hitchTimeRatio * 100).rounded() / 100
            let fps = pacing.framesPerSecond.rounded()
            let frames = pacing.frames
            let hitches = pacing.hitches
            let visible = windowWasVisible ? "visible" : "covered"
            Self.logger.notice(
                "Scroll: \(frames, privacy: .public) frames, \(fps, privacy: .public) fps, \(hitches, privacy: .public) hitches, \(ratio, privacy: .public) ms/s, window \(visible, privacy: .public)"
            )
            Self.current = nil
        }
    }
#endif
