// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Charts
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// A bar of Insights that was tapped: the photos behind it.
struct InsightsSelection: Identifiable, Hashable {
    var filter: InsightsFilter
    var title: String
    var id: InsightsFilter { filter }
}

/// The photographer's statistics (SPEC §16.5.1): cameras, lenses, focal lengths, apertures, ISO, shutter speeds, time
/// of day and the keeper rate of each lens. Every bar opens its photos.
struct InsightsScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var indexing = ExifIndexing.shared
    @State private var snapshot: SessionModel.InsightsSnapshot?
    @State private var selection: InsightsSelection?
    @State private var lastLoad = Date.distantPast
    @State private var reload: Task<Void, Never>?

    var body: some View {
        content
            .navigationTitle(String(localized: AppDestination.insights.title))
            .navigationDestination(item: $selection) { selected in
                InsightsResultsScreen(selection: selected)
            }
            .task {
                await load()
                indexing.start(session: session)
            }
            // New camera data comes in batches; the numbers follow at most every few seconds.
            .onChange(of: indexing.revision) { _, _ in scheduleReload() }
            // After a sync: new photos are counted and their camera data read.
            .onChange(of: session.syncStatus.isWorking) { _, working in
                guard !working else { return }
                Task {
                    await load()
                    indexing.start(session: session)
                }
            }
            .onDisappear { reload?.cancel() }
    }

    @ViewBuilder var content: some View {
        if let snapshot, !(snapshot.total == 0 && session.syncStatus.isWorking) {
            if snapshot.total == 0 {
                ContentUnavailableView(
                    String(localized: "No photos yet", bundle: .module, comment: "Insights: the library has no photos."),
                    systemImage: AppDestination.insights.systemImage,
                    description: Text(
                        "Insights shows which cameras, lenses and settings you use once your library has photos.", bundle: .module,
                        comment: "Insights: empty library."))
            } else if snapshot.summary.isEmpty && !indexing.isRunning && snapshot.analysed >= snapshot.total {
                ContentUnavailableView(
                    String(localized: "No camera data", bundle: .module, comment: "Insights: none of the photos has EXIF data."),
                    systemImage: "camera.metering.unknown",
                    description: Text(
                        "Your photos have no camera information, as is usual for screenshots and pictures saved from messages.",
                        bundle: .module, comment: "Insights: why there is nothing to show."))
            } else {
                dashboard(snapshot)
            }
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func dashboard(_ snapshot: SessionModel.InsightsSnapshot) -> some View {
        let summary = snapshot.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InsightsHeader(snapshot: snapshot, isReading: indexing.isRunning, error: indexing.lastError)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    if !summary.cameras.isEmpty {
                        RankedCard(
                            title: InsightsWording.cameras, systemImage: "camera", bars: summary.cameras,
                            open: { name in open(.camera(name), title: name) })
                    }
                    if !summary.lenses.isEmpty {
                        RankedCard(
                            title: InsightsWording.lenses, systemImage: "camera.aperture", bars: summary.lenses,
                            open: { name in open(.lens(name), title: name) })
                    }
                    if !summary.focalLengths.isEmpty {
                        HistogramCard(
                            title: InsightsWording.focalLengths, systemImage: "scope", axis: InsightsWording.focalLengths,
                            footnote: InsightsWording.focalFootnote,
                            bars: summary.focalLengths.map { bar in
                                HistogramBar(label: InsightsWording.focalLength(bar.key), count: bar.count, filter: .focalLength(bar.key))
                            }, open: open)
                    }
                    if !summary.apertures.isEmpty {
                        HistogramCard(
                            title: InsightsWording.apertures, systemImage: "camera.aperture", axis: InsightsWording.apertures,
                            bars: summary.apertures.map { bar in
                                HistogramBar(label: InsightsWording.aperture(bar.key), count: bar.count, filter: .aperture(bar.key))
                            }, open: open)
                    }
                    if !summary.isos.isEmpty {
                        HistogramCard(
                            title: InsightsWording.isos, systemImage: "sun.max", axis: InsightsWording.isos,
                            bars: summary.isos.map { bar in
                                HistogramBar(label: InsightsWording.iso(bar.key), count: bar.count, filter: .iso(bar.key))
                            }, open: open)
                    }
                    if !summary.shutterSpeeds.isEmpty {
                        HistogramCard(
                            title: InsightsWording.shutterSpeeds, systemImage: "timer", axis: InsightsWording.shutterSpeeds,
                            bars: summary.shutterSpeeds.map { bar in
                                HistogramBar(label: InsightsWording.shutter(bar.key), count: bar.count, filter: .shutter(bar.key))
                            }, open: open)
                    }
                    if summary.hours.contains(where: { $0 > 0 }) {
                        HistogramCard(
                            title: InsightsWording.timeOfDay, systemImage: "clock", axis: InsightsWording.timeOfDay,
                            bars: summary.hours.enumerated().map { hour, count in
                                HistogramBar(label: InsightsWording.hour(hour), count: count, filter: .hour(hour))
                            },
                            axisLabels: [0, 6, 12, 18].map { InsightsWording.hour($0) }, open: open)
                    }
                    KeeperCard(summary: summary) { rate in open(rate.filter, title: InsightsWording.keepersTitle(rate)) }
                }
            }
            .padding()
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
        }
    }

    func open(_ filter: InsightsFilter, title: String) {
        selection = InsightsSelection(filter: filter, title: title)
    }

    func load() async {
        lastLoad = Date()
        if let value = try? await session.insights() { snapshot = value }
    }

    func scheduleReload() {
        guard reload == nil else { return }
        let wait = max(0, 3 - Date().timeIntervalSince(lastLoad))
        reload = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await load()
            reload = nil
        }
    }
}

/// How far reading the camera data has come.
private struct InsightsHeader: View {
    let snapshot: SessionModel.InsightsSnapshot
    let isReading: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "\(snapshot.summary.withCameraData) photos with camera data", bundle: .module,
                    comment: "Insights header. Plural variations in the catalog."
                )
                .font(.title3.weight(.semibold))
                Spacer()
                if snapshot.summary.reviewed > 0 {
                    Text(
                        "\(snapshot.summary.keepers) keepers", bundle: .module,
                        comment: "Insights header: photos picked or rated 3 stars or more. Plural variations in the catalog."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            if isReading || snapshot.analysed < snapshot.total {
                ProgressView(value: Double(snapshot.analysed), total: Double(max(snapshot.total, 1))) {
                    Text(
                        "Reading camera data: \(snapshot.analysed) of \(snapshot.total) photos", bundle: .module,
                        comment: "Insights: progress of reading the photos' EXIF from the server."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if let error, !isReading {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
            }
            Text(
                "From the camera information in your photos, read from your server and counted on this device.", bundle: .module,
                comment: "Insights: where the numbers come from."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// Cameras or lenses, most used first, as bars with their counts.
private struct RankedCard: View {
    let title: String
    let systemImage: String
    let bars: [InsightsBar<String>]
    let open: (String) -> Void
    @State private var showsAll = false

    static let shortList = 6

    var body: some View {
        let shown = showsAll ? bars : Array(bars.prefix(Self.shortList))
        let top = max(bars.first?.count ?? 1, 1)
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { bar in
                    Button {
                        open(bar.key)
                    } label: {
                        RankedRow(title: bar.key, count: bar.count, fraction: Double(bar.count) / Double(top))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: bar.key))
                    .accessibilityValue(InsightsWording.photoCount(bar.count))
                    .accessibilityHint(InsightsWording.openHint)
                }
                if bars.count > Self.shortList {
                    Button(showsAll ? InsightsWording.showLess : InsightsWording.showAll(bars.count)) {
                        withAnimation(.snappy) { showsAll.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct RankedRow: View {
    let title: String
    let count: Int
    let fraction: Double
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(verbatim: title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Design.accent.opacity(hovering ? 0.28 : 0.16))
                    .frame(width: max(proxy.size.width * fraction, 4))
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// One bar of a histogram card.
struct HistogramBar: Identifiable, Hashable {
    var label: String
    var count: Int
    var filter: InsightsFilter
    var id: String { label }
}

/// A distribution as a bar chart; a click or tap on a bar opens its photos.
private struct HistogramCard: View {
    let title: String
    let systemImage: String
    let axis: String
    var footnote: String? = nil
    let bars: [HistogramBar]
    /// The labels the x axis shows (all when nil).
    var axisLabels: [String]? = nil
    let open: (InsightsFilter, String) -> Void
    @State private var hovered: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                chart
                    .frame(height: 170)
                    .accessibilityRepresentation {
                        // VoiceOver and Full Keyboard Access: the bars as buttons.
                        ForEach(bars.filter { $0.count > 0 }) { bar in
                            Button {
                                open(bar.filter, bar.label)
                            } label: {
                                Text(verbatim: "\(bar.label): \(InsightsWording.photoCount(bar.count))")
                            }
                        }
                    }
                if let footnote {
                    Text(footnote).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    var chart: some View {
        Chart(bars) { bar in
            BarMark(x: .value(axis, bar.label), y: .value(InsightsWording.photosAxis, bar.count))
                .foregroundStyle(Design.accent.opacity(hovered == nil || hovered == bar.label ? 1 : 0.45).gradient)
                .cornerRadius(3)
                .annotation(position: .top, spacing: 2) {
                    if hovered == bar.label {
                        Text(bar.count, format: .number).font(.caption2.weight(.semibold)).monospacedDigit()
                    }
                }
        }
        .chartXAxis {
            if let axisLabels {
                // Categorical axes label every bar; only these are written (the others stay empty).
                AxisMarks { value in
                    AxisValueLabel {
                        let label = value.as(String.self) ?? ""
                        Text(verbatim: axisLabels.contains(label) ? label : "")
                    }
                }
            } else {
                AxisMarks { _ in
                    AxisValueLabel(collisionResolution: .greedy)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { location in
                        if let bar = bar(at: location, proxy: proxy, geometry: geometry), bar.count > 0 { open(bar.filter, bar.label) }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bar(at: location, proxy: proxy, geometry: geometry)?.label
                        case .ended: hovered = nil
                        }
                    }
            }
        }
    }

    func bar(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> HistogramBar? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = location.x - geometry[plot].origin.x
        guard let label: String = proxy.value(atX: x) else { return nil }
        return bars.first { $0.label == label }
    }
}

/// How many photos of each lens were kept (picked, or three stars or more).
private struct KeeperCard: View {
    let summary: InsightsSummary
    let open: (KeeperRate) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if summary.keeperRates.isEmpty {
                    Text(
                        "Pick photos (P) or rate them with stars (1–5) to see which lens gives you the most keepers.", bundle: .module,
                        comment: "Insights: the keeper rate needs ratings or flags first."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(summary.keeperRates.prefix(8)) { rate in
                        Button {
                            open(rate)
                        } label: {
                            KeeperRow(rate: rate)
                        }
                        .buttonStyle(.plain)
                        .disabled(rate.keepers == 0)
                    }
                    Text(
                        "Keepers are photos you picked or gave three stars or more.", bundle: .module,
                        comment: "Insights: what counts as a keeper."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        } label: {
            Label(InsightsWording.keeperRate, systemImage: "star.leadinghalf.filled")
        }
    }
}

private struct KeeperRow: View {
    let rate: KeeperRate

    var body: some View {
        HStack(spacing: 10) {
            Gauge(value: rate.rate) {
                EmptyView()
            } currentValueLabel: {
                Text(rate.rate, format: .percent.precision(.fractionLength(0)))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Design.accent)
            .scaleEffect(0.62)
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: rate.lens ?? rate.camera ?? "").lineLimit(1).truncationMode(.middle)
                Text(InsightsWording.keeperDetail(rate)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if rate.keepers > 0 {
                Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: rate.lens ?? rate.camera ?? ""))
        .accessibilityValue(
            Text(
                "\(rate.rate.formatted(.percent.precision(.fractionLength(0)))), \(InsightsWording.keeperDetail(rate))", bundle: .module,
                comment: "VoiceOver: keeper rate of a lens, then e.g. 12 of 40 photos kept."))
    }
}

/// The photos behind a bar.
struct InsightsResultsScreen: View {
    let selection: InsightsSelection
    @Environment(SessionModel.self) private var session

    var body: some View {
        ItemsScreen(title: selection.title, emptyMessage: InsightsWording.noMatches) { [session] _ in
            try await session.insightsItems(selection.filter)
        }
    }
}

/// Words and numbers of Insights. Photographic notation (ƒ/2.8, 1/250 s, ISO 400) with the locale's digits.
enum InsightsWording {
    static var cameras: String { String(localized: "Cameras", bundle: .module, comment: "Insights card title.") }
    static var lenses: String { String(localized: "Lenses", bundle: .module, comment: "Insights card title.") }
    static var focalLengths: String { String(localized: "Focal Lengths", bundle: .module, comment: "Insights card title.") }
    static var apertures: String { String(localized: "Apertures", bundle: .module, comment: "Insights card title.") }
    static var isos: String { String(localized: "ISO", bundle: .module, comment: "Insights card title: sensor sensitivity.") }
    static var shutterSpeeds: String { String(localized: "Shutter Speeds", bundle: .module, comment: "Insights card title.") }
    static var timeOfDay: String { String(localized: "Time of Day", bundle: .module, comment: "Insights card title.") }
    static var keeperRate: String {
        String(localized: "Keeper Rate by Lens", bundle: .module, comment: "Insights card title: share of photos kept per lens.")
    }
    static var photosAxis: String { String(localized: "Photos", bundle: .module, comment: "Insights chart axis: number of photos.") }
    static var focalFootnote: String {
        String(
            localized: "35 mm equivalent where the camera records it (phones, compacts).", bundle: .module,
            comment: "Insights: focal lengths of phones are shown as their full-frame equivalent.")
    }
    static var openHint: String {
        String(localized: "Shows these photos", bundle: .module, comment: "VoiceOver hint of a bar in Insights.")
    }
    static var showLess: String { String(localized: "Show Less", bundle: .module, comment: "Insights: collapse a long list.") }
    static var noMatches: String {
        String(localized: "No photos match.", bundle: .module, comment: "Insights: a bar's photos are gone meanwhile.")
    }

    static func showAll(_ count: Int) -> String {
        String(localized: "Show All \(count)", bundle: .module, comment: "Insights: expand a list of cameras or lenses.")
    }

    static func photoCount(_ count: Int) -> String {
        String(localized: "\(count) photos", bundle: .module, comment: "Insights: number of photos of a bar. Plural variations.")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func focalLength(_ millimetres: Double) -> String {
        String(localized: "\(number(millimetres)) mm", bundle: .module, comment: "A focal length, e.g. 35 mm.")
    }

    static func aperture(_ fNumber: Double) -> String {
        "ƒ/\(number(fNumber))"
    }

    static func iso(_ value: Double) -> String {
        "ISO \(Int(value).formatted(.number.grouping(.never)))"
    }

    /// "1/250 s", "1/2 s", "2 s", "30 s".
    static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(localized: "\(number(seconds)) s", bundle: .module, comment: "A shutter speed of a second or longer, e.g. 2 s.")
        }
        let denominator = Int((1 / seconds).rounded()).formatted(.number.grouping(.never))
        return String(localized: "1/\(denominator) s", bundle: .module, comment: "A shutter speed shorter than a second, e.g. 1/250 s.")
    }

    /// "9 AM", "09:00", as the locale says hours.
    static func hour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
        return date.formatted(.dateTime.hour())
    }

    static func keeperDetail(_ rate: KeeperRate) -> String {
        String(
            localized: "\(rate.keepers) of \(rate.total) kept", bundle: .module,
            comment: "Insights: keepers of a lens out of its photos, e.g. 12 of 40 kept.")
    }

    static func keepersTitle(_ rate: KeeperRate) -> String {
        String(
            localized: "Keepers: \(rate.lens ?? rate.camera ?? "")", bundle: .module,
            comment: "Title of the screen with the keepers of one lens or camera.")
    }
}
