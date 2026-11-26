// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosMedia
import SwiftUI

/// Settings › Server › Cache performance (SPEC §18.1.3): where previews came from, how long pictures took to appear and
/// how much each cache holds. Numbers since launch (or the last reset), for support and for measuring cache changes.
struct CacheDiagnosticsView: View {
    @Environment(SessionModel.self) private var session
    @State private var snapshot: CacheMetrics.Snapshot = CacheMetrics.shared.snapshot()
    @State private var usage: CacheUsage?

    /// Where the snapshot is written while this screen is open (read back by the measurements in the simulator).
    static var snapshotFile: URL {
        URL.cachesDirectory.appending(path: "cache-metrics.json")
    }

    var body: some View {
        Form {
            sources
            hitRates
            times
            storage
            Section {
                Button(String(localized: "Reset counters", bundle: .module, comment: "Settings › Cache performance: button.")) {
                    CacheMetrics.shared.reset()
                    snapshot = CacheMetrics.shared.snapshot()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Self.title)
        .task {
            // Live while open; the directory scan is slower, so less often.
            var rounds = 0
            while !Task.isCancelled {
                snapshot = CacheMetrics.shared.snapshot()
                Self.writeSnapshot()
                if rounds % 5 == 0 { await scanUsage() }
                rounds += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static var title: String {
        String(
            localized: "Cache performance", bundle: .module,
            comment: "Link in Settings › Server and title of the screen with cache hit rates, loading times and cache sizes.")
    }

    static func writeSnapshot() {
        let file = snapshotFile
        Task.detached(priority: .utility) { CacheMetrics.shared.write(to: file) }
    }

    // MARK: Sections

    var sources: some View {
        Section {
            let total: Int = snapshot.layers.reduce(0) { $0 + $1.demandTotal }
            ForEach(snapshot.layers, id: \.layer) { layer in
                LabeledContent(Self.name(of: layer.layer), value: Self.countAndShare(layer.demandTotal, of: total))
            }
        } header: {
            Text("Where previews came from", bundle: .module, comment: "Settings › Cache performance: section title.")
        } footer: {
            let prefetched: Int = snapshot.layers.reduce(0) { $0 + $1.prefetch.reduce(0, +) }
            Text(
                "Previews that were waited for, since \(snapshot.since.formatted(date: .omitted, time: .shortened)). Loaded ahead of time: \(prefetched).",
                bundle: .module,
                comment: "Settings › Cache performance: footer of the sources. The first value is a time, the second a number of previews.")
        }
    }

    var hitRates: some View {
        Section {
            LabeledContent(
                String(localized: "All sizes", bundle: .module, comment: "Settings › Cache performance: hit rate of all preview sizes."),
                value: Self.percent(snapshot.hitRate))
            ForEach(CacheMetrics.buckets, id: \.self) { bucket in
                LabeledContent(Self.sizeName(bucket), value: Self.percent(snapshot.hitRate(bucket: bucket)))
            }
        } header: {
            Text("Served from the device", bundle: .module, comment: "Settings › Cache performance: section title of the hit rates.")
        }
    }

    var times: some View {
        Section {
            ForEach(CacheMetrics.Timing.allCases, id: \.self) { timing in
                LabeledContent(Self.name(of: timing), value: Self.times(snapshot.times(timing)))
            }
        } header: {
            Text("Time to show", bundle: .module, comment: "Settings › Cache performance: section title of the loading times.")
        } footer: {
            Text(
                "Median and 95th percentile. Goals: a cached photo in the viewer in under 150 ms, an uncached one in under 600 ms.",
                bundle: .module, comment: "Settings › Cache performance: footer of the loading times.")
        }
    }

    var storage: some View {
        Section {
            if let usage {
                ForEach(Array(CacheMetrics.buckets.enumerated()), id: \.offset) { index, bucket in
                    LabeledContent(Self.sizeName(bucket), value: Self.files(usage.previewFiles[index], bytes: usage.previewBytes[index]))
                }
                LabeledContent(
                    String(localized: "Smart offline", bundle: .module),
                    value: Self.files(usage.smartOfflineFiles, bytes: usage.smartOfflineBytes))
                LabeledContent(
                    String(localized: "Offline albums", bundle: .module),
                    value: Formatters.bytes(usage.offlineBytes))
                LabeledContent(
                    String(
                        localized: "Originals cache", bundle: .module,
                        comment: "Settings › Cache performance: storage of originals downloaded for viewing or sharing."),
                    value: Formatters.bytes(usage.originalBytes))
            } else {
                ProgressView()
            }
            if let images = session.services?.images {
                LabeledContent(
                    String(
                        localized: "Memory for previews", bundle: .module,
                        comment: "Settings › Cache performance: how much memory decoded previews may use."),
                    value: Formatters.bytes(Int64(images.cache.memoryLimitBytes)))
            }
        } header: {
            Text("Stored on this device", bundle: .module, comment: "Settings › Cache performance: section title of the cache sizes.")
        }
    }

    func scanUsage() async {
        guard let services = session.services else { return }
        let layout = services.layout
        let id = services.account.id
        usage = await Task.detached(priority: .utility) {
            CacheUsage.scan(
                previews: layout.previews(id), smartOffline: layout.accountDirectory(id).appending(path: "SmartOffline"),
                offline: layout.offline(id), originals: layout.originals(id))
        }.value
    }

    // MARK: Wording

    static func name(of layer: CacheLayer) -> String {
        switch layer {
        case .memory: String(localized: "Memory", bundle: .module, comment: "Settings › Cache performance: previews decoded in memory.")
        case .disk: String(localized: "Preview cache", bundle: .module)
        case .smartOffline: String(localized: "Smart offline", bundle: .module)
        case .offline:
            String(
                localized: "Offline albums", bundle: .module,
                comment: "Settings › Cache performance: previews from offline albums, and their storage.")
        case .network:
            String(localized: "Downloaded", bundle: .module, comment: "Settings › Cache performance: previews loaded from the server.")
        case .failed:
            String(localized: "Not loaded", bundle: .module, comment: "Settings › Cache performance: previews that could not be loaded.")
        }
    }

    static func name(of timing: CacheMetrics.Timing) -> String {
        switch timing {
        case .tile:
            String(localized: "Grid tiles", bundle: .module, comment: "Settings › Cache performance: time until a tile shows its picture.")
        case .viewerFirst:
            String(
                localized: "Viewer, first picture", bundle: .module,
                comment: "Settings › Cache performance: time until a photo in the viewer shows any picture.")
        case .viewerFull:
            String(
                localized: "Viewer, sharp picture", bundle: .module,
                comment: "Settings › Cache performance: time until a photo in the viewer shows its full-size preview.")
        }
    }

    static func sizeName(_ bucket: Int) -> String {
        String(localized: "\(bucket) px", bundle: .module, comment: "Settings › Cache performance: a preview size in pixels.")
    }

    static func countAndShare(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return count.formatted() }
        return String(
            localized: "\(count) (\(percent(Double(count) / Double(total))))", bundle: .module,
            comment: "Settings › Cache performance: a number of previews and its share, e.g. “120 (40 %)”.")
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func times(_ times: CacheMetrics.Snapshot.Times?) -> String {
        guard let times, let p50 = times.p50, let p95 = times.p95 else { return "–" }
        return String(
            localized: "\(Int(p50.rounded())) ms · \(Int(p95.rounded())) ms (\(times.count))", bundle: .module,
            comment: "Settings › Cache performance: median and 95th percentile in milliseconds, then the number of samples.")
    }

    static func files(_ count: Int, bytes: Int64) -> String {
        // The wording of Settings › Storage (offline albums).
        String(localized: "\(count) files · \(Formatters.bytes(bytes))", bundle: .module)
    }
}
