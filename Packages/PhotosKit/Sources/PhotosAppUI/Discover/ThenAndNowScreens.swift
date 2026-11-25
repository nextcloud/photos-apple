// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import CoreGraphics
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

// MARK: - Then and now (SPEC §15.6)

/// Wording of "Then and now".
enum ThenAndNowWording {
    static var title: String {
        String(
            localized: "Then and now", bundle: .module,
            comment: "Title of the feature that shows a place the user photographed in several years, side by side and as a time-lapse.")
    }

    /// Shown for a spot the server has no place name for.
    static var unnamedPlace: String {
        String(localized: "This place", bundle: .module, comment: "Then and now: name of a spot that has no place name.")
    }

    static func name(_ spot: ThenAndNowSpot) -> String { spot.placeName ?? unnamedPlace }

    static let systemImage = "clock.arrow.circlepath"

    /// "2014 · 2019 · 2025"
    static func years(_ spot: ThenAndNowSpot) -> String {
        ThenAndNow.yearList(spot).joined(separator: " · ")
    }

    static var playTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Play Time-Lapse", bundle: .module,
                comment: "Then and now: button that plays the photos of the years cross-fading into each other (Mac title case)."),
            other: LocalizedStringResource(
                "Play time-lapse", bundle: .module,
                comment: "Then and now: button that plays the photos of the years cross-fading into each other."))
    }

    static var exportTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Export Video…", bundle: .module, comment: "Then and now: button that saves the time-lapse as a video (Mac title case)."),
            other: LocalizedStringResource(
                "Export video…", bundle: .module, comment: "Then and now: button that saves the time-lapse as a video."))
    }

    static func accessibilityLabel(_ spot: ThenAndNowSpot) -> String {
        AccessibilityText.join([name(spot), years(spot), AccessibilityText.photos(spot.itemCount)])
    }
}

/// Finds the spots of the library once and keeps them for a few minutes, so that going back and forth between Places,
/// Memories and a spot does not cluster the library again.
@MainActor @Observable
final class ThenAndNowModel {
    private(set) var spots: [ThenAndNowSpot] = []
    private(set) var loaded = false

    private static var cache: [AccountID: (date: Date, spots: [ThenAndNowSpot])] = [:]
    static let cacheLifetime: TimeInterval = 300

    func load(_ services: AccountServices) async {
        let account = services.account.id
        if let cached = Self.cache[account], Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            spots = cached.spots
            loaded = true
            return
        }
        let library = services.library
        let found = await Task.detached(priority: .userInitiated) { () -> [ThenAndNowSpot] in
            guard let items = try? await library.locatedItems() else { return [] }
            return ThenAndNow.spots(items)
        }.value
        Self.cache[account] = (Date(), found)
        spots = found
        loaded = true
    }
}

/// Loads small previews for the view matching and the time-lapse, from the cache or the user's server.
struct SpotPreviews: Sendable {
    let items: [FileID: MediaItem]
    let images: ImagePipeline
    let connection: ServerConnection

    static func make(for ids: [FileID], services: AccountServices) async -> SpotPreviews {
        let items = (try? await services.library.fetchItems(ids)) ?? [:]
        return SpotPreviews(items: items, images: services.images, connection: services.connection)
    }

    /// Several previews, loaded at the same time, in the order of `ids`.
    func images(_ ids: [FileID], bucket: Int, maxPixelSize: Int? = nil) async -> [CGImage?] {
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, await image(id, bucket: bucket, maxPixelSize: maxPixelSize)) }
            }
            var result = [CGImage?](repeating: nil, count: ids.count)
            for await (index, image) in group { result[index] = image }
            return result
        }
    }

    func image(_ id: FileID, bucket: Int, maxPixelSize: Int? = nil) async -> CGImage? {
        guard let item = items[id] else { return nil }
        return await images.preview(
            ImagePipeline.Request(
                fileId: id, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: connection.originalURL(path: item.path), maxPixelSize: maxPixelSize))
    }
}

/// "Then and now" in Places and Memories: a row of spots (one per place) with "See all".
struct ThenAndNowRow: View {
    @Environment(SessionModel.self) private var session
    @State private var model = ThenAndNowModel()

    var body: some View {
        let shown: [ThenAndNowSpot] = ThenAndNow.distinctPlaces(model.spots, limit: 12)
        // A stack, not a group: an empty group has no view to run the task on.
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ThenAndNowWording.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if model.spots.count > shown.count {
                            NavigationLink {
                                ThenAndNowListScreen(spots: model.spots)
                            } label: {
                                Text("See all", bundle: .module, comment: "Link from a row of items to the list of all of them.")
                            }
                        }
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(shown) { spot in
                                NavigationLink {
                                    ThenAndNowScreen(spot: spot)
                                } label: {
                                    ThenAndNowCard(spot: spot).frame(width: 260)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task {
            guard let services = session.services else { return }
            await model.load(services)
        }
    }
}

/// All spots, the best first.
struct ThenAndNowListScreen: View {
    let spots: [ThenAndNowSpot]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 20) {
                ForEach(spots) { spot in
                    NavigationLink {
                        ThenAndNowScreen(spot: spot)
                    } label: {
                        ThenAndNowCard(spot: spot)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(ThenAndNowWording.title)
    }
}

/// The first and the last year of a spot side by side, with the place and its years below.
struct ThenAndNowCard: View {
    let spot: ThenAndNowSpot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                if let first = spot.years.first { half(first) }
                if let last = spot.years.last { half(last) }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14))
            Text(ThenAndNowWording.name(spot)).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Text(ThenAndNowWording.years(spot)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThenAndNowWording.accessibilityLabel(spot))
    }

    func half(_ year: ThenAndNowSpot.Year) -> some View {
        Color.clear
            .overlay { PreviewImage(fileId: year.cover, etag: "", bucket: 256) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(String(year.year)).font(.caption.bold()).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
    }
}

/// One spot: its years side by side (each opens its photos in the viewer), the time-lapse and its video.
struct ThenAndNowScreen: View {
    /// The photo it was opened from (the viewer's More menu): its year leads with it.
    var anchor: FileID?
    @State private var spot: ThenAndNowSpot
    @State private var matching = false
    /// Matched once: coming back from the viewer does not compare again.
    @State private var matched = false
    @State private var viewer: ViewerStart?
    @State private var playing: ThenAndNowSpot?
    @State private var exporter = TimeLapseExportModel()
    @Environment(SessionModel.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(spot: ThenAndNowSpot, anchor: FileID? = nil) {
        self.anchor = anchor
        _spot = State(initialValue: spot)
    }

    var title: String { ThenAndNowWording.name(spot) }

    /// Years visible side by side: two on a phone, up to four on a wide screen.
    var visibleColumns: Int {
        let wide = horizontalSizeClass != .compact
        return min(max(spot.years.count, 2), wide ? 4 : 2)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ThenAndNowWording.years(spot)).font(.title3.weight(.semibold)).monospacedDigit()
                    HStack(spacing: 6) {
                        Text(AccessibilityText.photos(spot.itemCount))
                        if matching {
                            Text(verbatim: "·")
                            ProgressView().controlSize(.mini)
                            Text(
                                "Finding the same view…", bundle: .module,
                                comment:
                                    "Then and now: shown while the photos of the years are compared on the device to find the ones that show the same view."
                            )
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(spot.years) { year in
                            yearColumn(year)
                                .containerRelativeFrame(.horizontal, count: visibleColumns, spacing: 12)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)

                actions.padding(.horizontal)

                NavigationLink {
                    ItemsScreen(title: title) { services in
                        let map = try await services.library.fetchItems(spot.allItems)
                        return spot.allItems.compactMap { map[$0] }
                    }
                } label: {
                    Label(
                        String(
                            localized: "All photos from here", bundle: .module,
                            comment: "Then and now: link to all photos of the spot from every year."), systemImage: "square.grid.2x2")
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await export() }
                } label: {
                    Label(ThenAndNowWording.exportTitle, systemImage: "square.and.arrow.up")
                }
                .disabled(exporter.isRunning)
                .help(ThenAndNowWording.exportTitle)
            }
        }
        .mediaViewer($viewer)
        .timeLapsePlayer($playing, title: title)
        .timeLapseExport(exporter)
        .task { await match() }
    }

    func yearColumn(_ year: ThenAndNowSpot.Year) -> some View {
        Button {
            viewer = ViewerStart(ids: year.items, startId: year.cover)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay { PreviewImage(fileId: year.cover, etag: "", bucket: 1024) }
                    .clipShape(.rect(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                Text(String(year.year)).font(.title2.bold()).monospacedDigit()
                Text(AccessibilityText.photos(year.items.count)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.join([String(year.year), AccessibilityText.photos(year.items.count)]))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            Text("Opens the photos of this year.", bundle: .module, comment: "Then and now: VoiceOver hint of a year's photo."))
    }

    var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(alignment: .leading, spacing: 12) { actionButtons }
        }
    }

    @ViewBuilder var actionButtons: some View {
        Button {
            playing = spot
        } label: {
            Label(ThenAndNowWording.playTitle, systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        Button {
            Task { await export() }
        } label: {
            if let progress = exporter.progress {
                Label {
                    Text("Making video…", bundle: .module, comment: "Then and now: shown while the time-lapse video is written.")
                } icon: {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                }
            } else {
                Label(ThenAndNowWording.exportTitle, systemImage: "film")
            }
        }
        .buttonStyle(.bordered)
        .disabled(exporter.isRunning)
    }

    /// Compares the photos of the years on the device so each year leads with the same view.
    func match() async {
        guard !matching, !matched, let services = session.services else { return }
        matching = true
        defer { matching = false }
        let previews = await SpotPreviews.make(for: spot.allItems, services: services)
        let anchorYear = anchor.flatMap { id in spot.years.first { $0.items.first == id }?.year }
        let aligned = await ViewMatcher.align(spot, anchorYear: anchorYear) { id in
            await previews.image(id, bucket: 256, maxPixelSize: 256)
        }
        guard !Task.isCancelled else { return }
        matched = true
        withAnimation(.smooth) { spot = aligned }
    }

    func export() async {
        guard let services = session.services else { return }
        await exporter.export(spot, title: title, services: services)
    }
}

// MARK: - From the viewer

/// "Then and now" opened from the viewer's More menu, on the place of the photo shown.
struct ThenAndNowStart: Identifiable, Hashable {
    var spot: ThenAndNowSpot
    var anchor: FileID
    var id: String { "\(spot.id)-\(anchor)" }
}

/// "Then and now" in the viewer's More menu, only for a photo with photos from other years within 100 m. The spot is
/// found from a small box of the coordinate index while the menu is built.
struct ThenAndNowMenuItem: View {
    let item: MediaItem
    @Binding var start: ThenAndNowStart?
    @Environment(SessionModel.self) private var session

    var body: some View {
        if item.latitude != nil, item.longitude != nil, let spot = try? session.services?.library.thenAndNowSpot(around: item.fileId) {
            Button {
                start = ThenAndNowStart(spot: spot, anchor: item.fileId)
            } label: {
                Label(ThenAndNowWording.title, systemImage: ThenAndNowWording.systemImage)
            }
        }
    }
}

extension View {
    /// Shows "Then and now" for the viewer's photo in a sheet with its own navigation.
    func thenAndNowSheet(_ start: Binding<ThenAndNowStart?>) -> some View {
        modifier(ThenAndNowSheet(start: start))
    }
}

private struct ThenAndNowSheet: ViewModifier {
    @Binding var start: ThenAndNowStart?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        content.sheet(item: $start) { (start: ThenAndNowStart) in
            NavigationStack {
                ThenAndNowScreen(spot: start.spot, anchor: start.anchor)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Done", bundle: .module)) { self.start = nil }
                        }
                    }
            }
            .environment(session)
            .sheetMinimumSize(width: 640, height: 560)
        }
    }
}

// MARK: - Time-lapse player

extension View {
    /// Plays a spot's time-lapse: full screen on iPhone and iPad, in a sheet on the Mac and Vision Pro.
    func timeLapsePlayer(_ spot: Binding<ThenAndNowSpot?>, title: String) -> some View {
        modifier(TimeLapsePresenter(spot: spot, title: title))
    }
}

private struct TimeLapsePresenter: ViewModifier {
    @Binding var spot: ThenAndNowSpot?
    let title: String
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $spot) { (spot: ThenAndNowSpot) in
                TimeLapsePlayer(spot: spot, title: title).environment(session)
            }
        #else
            content.sheet(item: $spot) { (spot: ThenAndNowSpot) in
                TimeLapsePlayer(spot: spot, title: title).environment(session)
                    .frame(minWidth: 720, idealWidth: 960, minHeight: 540, idealHeight: 720)
            }
        #endif
    }
}

/// The years of a spot cross-fading into each other with a slow zoom (a dissolve with Reduce Motion), the year large in
/// the corner; loops until closed, pauses with a tap or Space.
struct TimeLapsePlayer: View {
    let spot: ThenAndNowSpot
    let title: String
    @State private var images: [CGImage?] = []
    @State private var started = Date()
    /// Seconds played when paused; nil while playing.
    @State private var pausedAt: Double?
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var plan: TimeLapsePlan { .player(count: spot.years.count, reduceMotion: reduceMotion) }

    func elapsed(at date: Date) -> Double { pausedAt ?? date.timeIntervalSince(started) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if images.isEmpty {
                ProgressView().tint(.white)
            } else {
                TimelineView(.animation(paused: pausedAt != nil)) { context in
                    frame(plan.moment(at: elapsed(at: context.date)))
                }
                .ignoresSafeArea()
            }
        }
        .contentShape(.rect)
        .onTapGesture { togglePause() }
        .overlay(alignment: .topLeading) { closeButton }
        .overlay(alignment: .topTrailing) {
            if pausedAt != nil {
                Image(systemName: "pause.fill").font(.title2).foregroundStyle(.white).padding(20).shadow(radius: 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                "Time-lapse of \(title), \(ThenAndNowWording.years(spot))", bundle: .module,
                comment: "Then and now: VoiceOver label of the playing time-lapse. The arguments are the place and its years.")
        )
        .accessibilityAction(
            named: Text(pausedAt == nil ? String(localized: "Pause", bundle: .module) : String(localized: "Play", bundle: .module))
        ) {
            togglePause()
        }
        .onKeyPress(.space) {
            togglePause()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .task { await load() }
        #if os(iOS)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        #endif
    }

    var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .padding(10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: Circle())
        .padding(16)
        .keyboardShortcut(.cancelAction)
    }

    func frame(_ moment: TimeLapsePlan.Moment) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                picture(moment.from, scale: moment.fromScale, size: proxy.size)
                picture(moment.to, scale: moment.toScale, size: proxy.size).opacity(moment.from == moment.to ? 0 : moment.mix)
                caption(moment.captioned, size: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    @ViewBuilder func picture(_ index: Int, scale: Double, size: CGSize) -> some View {
        if images.indices.contains(index), let image = images[index] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .clipped()
        } else {
            Color.black
        }
    }

    func caption(_ index: Int, size: CGSize) -> some View {
        let year = spot.years.indices.contains(index) ? String(spot.years[index].year) : ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(year)
                .font(.system(size: max(44, min(size.width, size.height) * 0.12), weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.title3.weight(.semibold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 10)
        .padding(28)
        .animation(.smooth, value: year)
        .accessibilityHidden(true)
    }

    func togglePause() {
        if let pausedAt {
            started = Date().addingTimeInterval(-pausedAt)
            self.pausedAt = nil
        } else {
            pausedAt = Date().timeIntervalSince(started)
        }
    }

    func load() async {
        guard let services = session.services else { return }
        let previews = await SpotPreviews.make(for: spot.covers, services: services)
        let loaded = await previews.images(spot.covers, bucket: 1024)
        guard !Task.isCancelled else { return }
        images = loaded
        started = Date()
    }
}

// MARK: - Video export

extension View {
    /// The smallest size of a sheet on the Mac (a window there); elsewhere the system sizes sheets to the screen.
    @ViewBuilder func sheetMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
            frame(minWidth: width, minHeight: height)
        #else
            self
        #endif
    }
}

/// Writes a spot's time-lapse as a video and offers it to share or save.
@MainActor @Observable
final class TimeLapseExportModel {
    /// 0…1 while the video is made.
    var progress: Double?
    var result: ExportedVideo?
    var error: String?
    var isRunning: Bool { progress != nil }

    struct ExportedVideo: Identifiable {
        var url: URL
        var title: String
        var id: URL { url }
    }

    func export(_ spot: ThenAndNowSpot, title: String, services: AccountServices) async {
        guard progress == nil else { return }
        progress = 0
        defer { progress = nil }
        let previews = await SpotPreviews.make(for: spot.covers, services: services)
        // The 1024 px previews the screen already shows (cached, so the video is made at once; scaled to 1080p).
        let images = await previews.images(spot.covers, bucket: 1024)
        var frames: [TimeLapseVideo.Frame] = []
        for (year, image) in zip(spot.years, images) {
            if let image { frames.append(TimeLapseVideo.Frame(image: image, caption: String(year.year))) }
        }
        guard frames.count >= 2 else {
            error = String(
                localized: "The photos could not be loaded.", bundle: .module,
                comment: "Then and now: the time-lapse video could not be made because the photos did not load.")
            return
        }
        let name = Self.fileName(title: title, spot: spot)
        let url = FileManager.default.temporaryDirectory.appending(path: "then-and-now", directoryHint: .isDirectory).appending(path: name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await TimeLapseVideo.write(frames, to: url) { value in
                Task { @MainActor in self.progress = value }
            }
            result = ExportedVideo(url: url, title: title)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Lisbon 2014–2025.mp4", without characters file systems reject.
    static func fileName(title: String, spot: ThenAndNowSpot) -> String {
        let years = spot.years.count > 1 ? "\(spot.years.first!.year)–\(spot.years.last!.year)" : ""
        let base = "\(title) \(years)".trimmingCharacters(in: .whitespaces)
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return (cleaned.isEmpty ? "Then and now" : cleaned) + ".mp4"
    }
}

extension View {
    /// The finished video (to watch, share or save) and errors of `model`.
    func timeLapseExport(_ model: TimeLapseExportModel) -> some View {
        modifier(TimeLapseExportPresenter(model: model))
    }
}

private struct TimeLapseExportPresenter: ViewModifier {
    @Bindable var model: TimeLapseExportModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.result) { video in
                ExportedVideoSheet(video: video)
            }
            .alert(
                String(
                    localized: "The video could not be made", bundle: .module,
                    comment: "Then and now: title of the alert when the time-lapse video failed."),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(String(localized: "OK", bundle: .module)) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
}

/// The time-lapse video, playing, with Share.
private struct ExportedVideoSheet: View {
    let video: TimeLapseExportModel.ExportedVideo
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                ShareLink(item: video.url, preview: SharePreview(video.title)) {
                    Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle(video.title)
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 480, height: 420)
        .onAppear {
            let player = AVPlayer(url: video.url)
            player.isMuted = true
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}
