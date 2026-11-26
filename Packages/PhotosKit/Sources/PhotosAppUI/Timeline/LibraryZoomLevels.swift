// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import OSLog
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

// The Library's zoom levels (SPEC §15.5): Years › Months › Days › All Photos, as in Apple Photos. A pinch moves along one
// ladder, the content following the fingers; a tap on a year or month zooms into it. Years, months and days are cards
// drawn by SwiftUI over the grid; All Photos is the platform grid underneath, which keeps its scroll position.

/// Where the grid should put a photo when a zoom arrives in it from the days.
struct GridPlacement: Equatable {
    let id = UUID()
    var fileId: FileID
    /// The photo's top edge in the grid, as a fraction of the grid's height (0: at the top).
    var fraction: Double
}

/// Which level the Library shows, the summary it is drawn from and the moves between the levels.
@MainActor
@Observable
final class LibraryZoomModel {
    /// The level shown; remembered on this device.
    private(set) var level: LibraryZoomLevel
    var summary = LibrarySummary.empty
    /// The bucket each summary level shows at its top when it appears.
    var focus: [LibraryZoomLevel: Int] = [:]
    /// The bucket each summary level shows at its top now (kept up to date by the level's scroll view).
    var visible: [LibraryZoomLevel: Int] = [:]
    /// A photo the grid should scroll to after a zoom into it.
    var gridPlacement: GridPlacement?
    /// Where the last zoom started (the transition grows from there) and whether it zoomed in.
    private(set) var anchor: UnitPoint = .center
    private(set) var zoomedIn = true
    /// Counts the levels snapped to (haptics).
    private(set) var snaps = 0
    /// The grid step a zoom from the days goes back to.
    var lastGridStep = GridColumns.default
    /// The photo at the top of the grid (set by the grid's screen).
    @ObservationIgnored var gridTopItem: @MainActor () -> FileID? = { nil }
    /// Changes the grid's zoom step (set by the timeline screen).
    @ObservationIgnored var setGridStep: @MainActor (Int) -> Void = { _ in }
    /// Moment titles of the days (SPEC §16.1) and what a tap on one opens (set by the timeline screen).
    var moments = MomentHeaders.none
    @ObservationIgnored var openMoment: @MainActor (String) -> Void = { _ in }
    /// When the last pinch on a summary level ended; taps right after it are the fingers lifting, not taps.
    @ObservationIgnored var pinchEnded: ContinuousClock.Instant?
    var acceptsTaps: Bool { pinchEnded.map { ContinuousClock.now - $0 > .milliseconds(500) } ?? true }
    // The morph between the levels (SPEC §17.5).
    @ObservationIgnored let photoFrames = ZoomPhotoFrames()
    /// The photos travelling from one level to the next; nil when no level change is under way.
    private(set) var morph: ZoomMorph?
    /// Photos whose travelling copy stands in for them: hidden on both levels until it lands.
    private(set) var hidden: Set<FileID> = []
    /// A grid tile's frame in the zoom overlay's coordinate space, nil when it is not on screen (set by the grid).
    @ObservationIgnored var gridTileFrame: @MainActor (FileID) -> CGRect? = { _ in nil }
    /// The area the levels are shown in, in the zoom overlay's coordinate space.
    @ObservationIgnored var viewport: CGRect = .zero
    /// A photo's picture if it is decoded in memory (set by the overlay from the account's image cache).
    @ObservationIgnored var decodedImage: @MainActor (GridMedia) -> CGImage? = { _ in nil }
    /// The scale and anchor of the pinch that ends in a level change: its flights start where the fingers left the photos.
    @ObservationIgnored var releasedPinch: (scale: Double, anchor: CGPoint)?
    /// The photo of the card or tile a zoom starts from, and the one of the card or tile it arrives at.
    @ObservationIgnored private var heroSource: GridMedia?
    @ObservationIgnored private var heroDestination: GridMedia?
    @ObservationIgnored private var morphTask: Task<Void, Never>?
    @ObservationIgnored private var builtRevision = -1
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    let ladder = LibraryZoomLadder(gridSteps: GridColumns.options)
    static let logger = Logger(subsystem: "com.nextcloud.photos", category: "zoom")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        level = LibraryZoomLevel(rawValue: defaults.string(forKey: LibraryZoomLevel.storageKey) ?? "") ?? .all
    }

    // MARK: Summary

    /// Builds the summary of the grid's items off the main actor, once per revision of the feed; a burst of revisions (a
    /// running sync) is built once at its end. The key photos use the aesthetics scores this device worked out.
    func update(items: [GridMedia], revision: Int, services: AccountServices?) {
        guard revision != builtRevision else { return }
        builtRevision = revision
        building?.cancel()
        let first = summary.items.isEmpty
        building = Task { [weak self] in
            if !first { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            let database = services?.database
            let built = await Task.detached(priority: .userInitiated) { () -> LibrarySummary in
                let quality = (database.flatMap { try? SimilarityStore(database: $0).qualities() }) ?? [:]
                return LibrarySummary(items: items, quality: quality)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.summary = built
            // SPEC §18.2: key photos rank higher for the caches.
            if let services { Task.detached(priority: .utility) { await services.noteKeyPhotos(of: built) } }
        }
    }

    // MARK: Moves

    func stop(for level: LibraryZoomLevel, gridStep: Int) -> LibraryZoomStop {
        switch level {
        case .years: .years
        case .months: .months
        case .days: .days
        case .all: .grid(step: gridStep)
        }
    }

    /// A pinch or a tap on a summary level: `steps` rungs in (positive) or out, towards `bucket` (the one under the fingers
    /// or tapped). Into the grid, `photo` (a tapped photo of a day) or the bucket's first photo is put where the fingers are.
    func move(
        from level: LibraryZoomLevel, by steps: Int, bucket: LibrarySummary.Bucket?, photo: FileID? = nil, at point: UnitPoint = .center
    ) {
        guard steps != 0, level != .all else { return }
        let target = ladder.moved(stop(for: level, gridStep: lastGridStep), by: steps)
        Self.logger.debug("zoom from \(level.rawValue, privacy: .public) by \(steps) to \(target.level.rawValue, privacy: .public)")
        anchor = point
        zoomedIn = steps > 0
        heroSource = photo.flatMap { photoFrames.items[$0] } ?? bucket?.key
        if case .grid = target {
            let first = bucket.map { summary.items[$0.range.lowerBound] }
            heroDestination = photo.flatMap { photoFrames.items[$0] } ?? first
            enterGrid(at: photo ?? first?.fileId, fraction: point.y)
            return
        }
        if let bucket, let matching = summary.bucket(target.level, matching: bucket) {
            focus[target.level] = matching.id
            heroDestination = matching.key
        }
        set(target.level)
    }

    /// A pinch out of the grid past its densest step: the days, at the day of `fileId` (the photo under the fingers).
    func leaveGrid(from fileId: FileID?, at point: UnitPoint, currentStep: Int) {
        lastGridStep = currentStep == ladder.densestGrid.map(Self.step(of:)) ? GridColumns.default : currentStep
        anchor = point
        zoomedIn = false
        let index = fileId.flatMap { summary.index(of: $0) }
        let day = index.flatMap { summary.bucket(.days, containing: $0) }
        focus[.days] = day?.id
        heroSource = index.map { summary.items[$0] }
        heroDestination = day?.key
        set(.days)
    }

    /// The picker, a menu command or a key: straight to `level`, at what is on screen now.
    func select(_ target: LibraryZoomLevel, currentStep: Int) {
        guard target != level else { return }
        let order = LibraryZoomLevel.allCases
        zoomedIn = (order.firstIndex(of: target) ?? 0) > (order.firstIndex(of: level) ?? 0)
        anchor = .center
        // What is on screen: the bucket at the top of the level shown, or the photo at the top of the grid.
        let topIndex: Int? =
            level == .all
            ? gridTopItem().flatMap { summary.index(of: $0) }
            : visible[level].flatMap { id in summary.buckets(level).first { $0.id == id }?.range.lowerBound }
        if level == .all {
            lastGridStep = currentStep == ladder.densestGrid.map(Self.step(of:)) ? GridColumns.default : currentStep
        }
        if target == .all {
            enterGrid(at: topIndex.map { summary.items[$0].fileId }, fraction: 0)
            return
        }
        focus[target] = topIndex.flatMap { summary.bucket(target, containing: $0)?.id }
        set(target)
    }

    /// ⌘+ and ⌘− (View menu) on a summary level; from the grid only ⌘− at its densest step comes here.
    func step(zoomIn: Bool, currentStep: Int) {
        switch level {
        case .all:
            guard !zoomIn else { return }
            select(.days, currentStep: currentStep)
        default:
            let visibleBucket = visible[level].flatMap { id in summary.buckets(level).first { $0.id == id } }
            move(from: level, by: zoomIn ? 1 : -1, bucket: visibleBucket ?? summary.buckets(level).first, at: .top)
        }
    }

    private func enterGrid(at fileId: FileID?, fraction: Double) {
        setGridStep(lastGridStep)
        if let fileId { gridPlacement = GridPlacement(fileId: fileId, fraction: min(max(fraction - 0.1, 0), 0.8)) }
        set(.all)
    }

    private func set(_ target: LibraryZoomLevel) {
        let hero = (heroSource, heroDestination)
        let pinch = releasedPinch
        heroSource = nil
        heroDestination = nil
        releasedPinch = nil
        guard target != level else { return }
        let from = level
        // Where the photos are on the level that is left, as the user sees them now.
        var source = from == .all ? [:] : photoFrames.frames(on: from)
        if let pinch {
            source = source.mapValues { LibraryZoomMorph.scaled($0, by: pinch.scale, around: pinch.anchor) }
        }
        endMorph()
        withAnimation(Self.animation) { level = target }
        snaps += 1
        defaults.set(target.rawValue, forKey: LibraryZoomLevel.storageKey)
        guard LibraryZoomMorph.style(reduceMotion: LibraryZoomHaptics.reduceMotion) == .flights else { return }
        morphTask = Task { [weak self] in
            // The new level is laid out (and the grid has scrolled to its photo) a frame or two later.
            try? await Task.sleep(for: .milliseconds(target == .all ? 50 : 32))
            guard !Task.isCancelled, let self else { return }
            self.launchMorph(from: from, to: target, source: source, hero: hero)
        }
    }

    // MARK: Morph (SPEC §17.5)

    /// Sends the photos on screen on both levels on their way: from where they were on `from` to where they are on `to`.
    private func launchMorph(
        from: LibraryZoomLevel, to target: LibraryZoomLevel, source: [FileID: CGRect], hero: (GridMedia?, GridMedia?)
    ) {
        var source = source
        var destination: [FileID: CGRect]
        var items = photoFrames.items
        for item in [hero.0, hero.1].compactMap(\.self) where items[item.fileId] == nil { items[item.fileId] = item }
        if target == .all {
            // Into the grid: the summary's photos (and the hero) where their tiles are now.
            let ids = Set(source.keys).union([hero.1?.fileId].compactMap(\.self))
            destination = Dictionary(uniqueKeysWithValues: ids.compactMap { id in gridTileFrame(id).map { (id, $0) } })
        } else {
            destination = photoFrames.frames(on: target)
        }
        if from == .all {
            // Out of the grid: the tiles of the photos the new level shows.
            let ids = Set(destination.keys).union([hero.0?.fileId].compactMap(\.self))
            source = Dictionary(uniqueKeysWithValues: ids.compactMap { id in gridTileFrame(id).map { (id, $0) } })
        }
        let heroPair: (source: FileID, destination: FileID)? = {
            guard let start = hero.0?.fileId, let end = hero.1?.fileId else { return nil }
            return (start, end)
        }()
        let plan = LibraryZoomMorph.flights(
            from: source, to: destination, hero: heroPair, viewport: viewport,
            anchor: CGPoint(x: viewport.minX + anchor.x * viewport.width, y: viewport.minY + anchor.y * viewport.height))
        let fromRadius = LibraryZoomMorph.cornerRadius(on: from)
        let toRadius = LibraryZoomMorph.cornerRadius(on: target)
        let flights: [ZoomFlight] = plan.enumerated().compactMap { index, flight in
            guard let start = items[flight.source], let end = items[flight.destination] else { return nil }
            return ZoomFlight(
                id: index, source: start, destination: end, from: flight.from, to: flight.to, fromRadius: fromRadius,
                toRadius: toRadius, image: decodedImage(start), destinationImage: flight.crossFades ? decodedImage(end) : nil)
        }
        guard !flights.isEmpty else { return }
        Self.logger.debug("morph \(from.rawValue, privacy: .public) → \(target.rawValue, privacy: .public): \(flights.count) photos")
        let holes: [CGRect] = from == .all ? flights.map(\.from) : target == .all ? flights.map(\.to) : []
        hidden = Set(flights.flatMap { [$0.source.fileId, $0.destination.fileId] })
        morph = ZoomMorph(flights: flights, gridHoles: holes)
    }

    /// Waits until the photos of the last level change are on their way (tests).
    func morphLaunched() async {
        await morphTask?.value
    }

    /// The flights landed: the levels' own photos take their place.
    func finishMorph(_ id: UUID) {
        guard morph?.id == id else { return }
        morph = nil
        hidden = []
    }

    private func endMorph() {
        morphTask?.cancel()
        morphTask = nil
        if morph != nil { morph = nil }
        if !hidden.isEmpty { hidden = [] }
    }

    static func step(of stop: LibraryZoomStop) -> Int {
        if case .grid(let step) = stop { return step }
        return GridColumns.default
    }

    static var animation: Animation? {
        LibraryZoomHaptics.reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.38)
    }
}

extension EnvironmentValues {
    /// The Library's zoom levels, for the grid of the timeline screen that offers them.
    @Entry var libraryZoom: LibraryZoomModel? = nil
}

/// The haptics of the zoom levels and the timeline (SPEC §15.5).
@MainActor
enum LibraryZoomHaptics {
    static var reduceMotion: Bool {
        #if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #elseif canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
        #else
            false
        #endif
    }

    /// A level change by a trackpad pinch on the Mac: the trackpad's "level change" feedback where it has a Taptic Engine
    /// (the system leaves it out when the user turned force click feedback off). Nothing elsewhere: iPhone and iPad play
    /// their tick through `sensoryFeedback`.
    static func trackpadLevelChange() {
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    /// A year passed while scrubbing on the Mac (alignment feedback, as when a dragged object snaps to a guide).
    static func trackpadAlignment() {
        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
}

// MARK: - Overlay

extension View {
    /// The zoom levels over the Library's grid: the years, months or days when one of them is chosen, and the picker.
    func libraryZoomLevels(_ model: LibraryZoomModel, feed: GridFeed, isSelecting: Bool) -> some View {
        modifier(LibraryZoomOverlay(model: model, feed: feed, isSelecting: isSelecting))
    }
}

struct LibraryZoomOverlay: ViewModifier {
    @Bindable var model: LibraryZoomModel
    let feed: GridFeed
    var isSelecting: Bool
    @Environment(SessionModel.self) private var session
    /// The floating picker's height, so the grid's notices stand above it (they showed through its glass).
    @State private var pickerHeight: CGFloat = 0

    var showsPicker: Bool { !isSelecting && feed.model.hasTiles }

    func body(content: Content) -> some View {
        content
            .environment(\.libraryZoom, model)
            #if !os(macOS)
                .environment(\.floatingBottomInset, showsPicker && pickerHeight > 0 ? pickerHeight + 12 + 8 : 0)
            #endif
            #if os(visionOS)
                // The cards have the window's glass behind them, not an opaque page: the grid must not show through.
                .opacity(model.level == .all ? 1 : 0)
            #endif
            // Covered by years, months or days, the grid is out of reach: VoiceOver and taps went to its tiles under the
            // cards (a day's photo could not be tapped where a tile lay beneath it).
            .accessibilityHidden(model.level != .all)
            .allowsHitTesting(model.level == .all)
            .overlay {
                if let morph = model.morph, !morph.gridHoles.isEmpty {
                    ZoomGridHoles(holes: morph.gridHoles, color: LibrarySummaryView.background)
                }
            }
            .overlay {
                if model.level != .all, feed.model.hasTiles {
                    LibrarySummaryView(model: model, level: model.level)
                        .id(model.level)
                        .transition(transition)
                }
            }
            .overlay {
                if let morph = model.morph {
                    ZoomFlightsLayer(morph: morph) { model.finishMorph($0) }
                        .id(morph.id)
                }
            }
            .coordinateSpace(.named(LibraryZoomSpace.name))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .local)
            } action: { frame in
                model.viewport = frame
            }
            .onAppear {
                model.decodedImage = { [session] item in
                    guard let images = session.services?.images else { return nil }
                    let etag = images.displayedEtag(fileId: item.fileId, etag: item.etag)
                    return images.cache.bestMemoryImage(fileId: item.fileId, etag: etag, upTo: 1024)
                }
            }
            #if !os(macOS)
                .overlay(alignment: .bottom) {
                    if showsPicker {
                        LibraryZoomPicker(model: model, gridStep: feed.zoomStep)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            pickerHeight = height
                        }
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
            #endif
            .photosHaptic(.impact(weight: .light), trigger: model.snaps)
            .task(id: feed.update.revision) {
                model.update(items: feed.items, revision: feed.update.revision, services: session.services)
            }
            // Photos the Library shows are indexed for "Show Similar" and key photos, a little at a time.
            .task(id: session.account.id) {
                guard let services = session.services else { return }
                await SimilarIndexing.trickle(services)
            }
            // And described for VoiceOver and search, while charging (SPEC §16.2).
            .task(id: session.account.id) {
                guard let services = session.services else { return }
                await PhotoDescriptions.trickle(services)
            }
    }

    /// Zooming in, the new level grows out of where the fingers were and the old one grows past them; out, both shrink.
    /// Gently: the photos the two levels share travel themselves (`ZoomFlightsLayer`). Reduce Motion: a cross-fade.
    var transition: AnyTransition {
        guard LibraryZoomMorph.style(reduceMotion: LibraryZoomHaptics.reduceMotion) == .flights else { return .opacity }
        let anchor = model.anchor
        let inward = model.zoomedIn
        return .asymmetric(
            insertion: .scale(scale: inward ? 0.94 : 1.06, anchor: anchor).combined(with: .opacity),
            removal: .scale(scale: inward ? 1.06 : 0.94, anchor: anchor).combined(with: .opacity))
    }
}

/// Years · Months · Days · All Photos.
struct LibraryZoomPicker: View {
    @Bindable var model: LibraryZoomModel
    var gridStep: Int

    var body: some View {
        // As wide as its titles, unless longer translations would make it wider than the screen: then as wide as the
        // screen, the titles shortened (SPEC §20.3; seen with doubled texts on the iPhone).
        ViewThatFits(in: .horizontal) {
            picker.fixedSize()
            picker
        }
        #if os(iOS)
            // Liquid Glass, floating over the photos (SPEC §17.5); solid with Reduce Transparency, as the system does it.
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        #elseif os(visionOS)
            .padding(4)
            .background(.regularMaterial, in: .capsule)
        #endif
    }

    var picker: some View {
        Picker(
            selection: Binding(get: { model.level }, set: { model.select($0, currentStep: gridStep) })
        ) {
            ForEach(LibraryZoomLevel.allCases, id: \.self) { level in
                Text(Self.title(level)).tag(level)
            }
        } label: {
            Text("Zoom level", bundle: .module, comment: "Accessibility label of the Years/Months/Days/All Photos picker.")
        }
        .pickerStyle(.segmented)
    }

    static func title(_ level: LibraryZoomLevel) -> String {
        switch level {
        case .years: String(localized: "Years", bundle: .module, comment: "Library zoom level: one card per year.")
        case .months: String(localized: "Months", bundle: .module, comment: "Library zoom level: one card per month.")
        case .days: String(localized: "Days", bundle: .module, comment: "Library zoom level: a few photos of every day.")
        case .all: String(localized: "All Photos", bundle: .module, comment: "Library zoom level: the grid of all photos.")
        }
    }
}

// MARK: - Years, months and days

/// Frames of the cards on screen, in the level's coordinate space: which one is under the fingers when a pinch starts.
/// A reference that nobody observes: cards report their frames while scrolling without redrawing the level.
@MainActor
final class SummaryCardFrames {
    var frames: [Int: CGRect] = [:]

    func card(at point: CGPoint) -> Int? {
        frames.first { $0.value.contains(point) }?.key
            ?? frames.min { distance($0.value, point) < distance($1.value, point) }?.key
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        abs(rect.midY - point.y) + abs(rect.midX - point.x) / 4
    }
}

/// The cards of one summary level, with the pinch that leaves it.
struct LibrarySummaryView: View {
    @Bindable var model: LibraryZoomModel
    let level: LibraryZoomLevel
    @State private var scrolledId: Int?
    @State private var frames = SummaryCardFrames()
    @State private var pinch: Double = 1
    @State private var pinchAnchor: UnitPoint = .center
    @State private var pinchStart: CGPoint?
    @State private var size: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var sizeClass

    nonisolated static let space = "librarySummary"

    init(model: LibraryZoomModel, level: LibraryZoomLevel) {
        self.model = model
        self.level = level
        _scrolledId = State(initialValue: model.focus[level])
    }

    var buckets: [LibrarySummary.Bucket] { model.summary.buckets(level) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(buckets) { bucket in
                    card(bucket)
                        .id(bucket.id)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.space))
                        } action: { frame in
                            frames.frames[bucket.id] = frame
                        }
                        .onDisappear { frames.frames[bucket.id] = nil }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            // Room for the level picker over the bottom edge.
            .padding(.bottom, 56)
        }
        .scrollPosition(id: $scrolledId, anchor: .top)
        .environment(\.zoomPhotoReporter, ZoomPhotoReporter(model: model, level: level))
        .accessibilityIdentifier("librarySummary")
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            size = $0
        }
        .background(Self.background)
        .scaleEffect(displayScale, anchor: pinchAnchor)
        .opacity(1 - LibraryZoomGesture.progress(scale: pinch) * 0.25)
        .simultaneousGesture(magnify)
        .onChange(of: scrolledId, initial: true) { _, id in model.visible[level] = id }
        .overlay {
            if buckets.isEmpty { LibrarySummarySkeleton(level: level) }
        }
        .accessibilityAction(named: Text("Zoom Out", bundle: .module)) { zoom(by: -1, bucket: topBucket, at: .top) }
    }

    static var background: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(visionOS)
            Color.clear
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    var topBucket: LibrarySummary.Bucket? {
        scrolledId.flatMap { id in buckets.first { $0.id == id } } ?? buckets.first
    }

    var isWide: Bool { sizeClass != .compact || size.width > 600 }

    var spacing: CGFloat { level == .months ? 10 : 18 }
    var horizontalPadding: CGFloat { isWide ? 20 : 12 }

    var columns: [GridItem] {
        switch level {
        case .years: [GridItem(.adaptive(minimum: isWide ? 320 : 300), spacing: spacing, alignment: .top)]
        case .months: [GridItem(.adaptive(minimum: isWide ? 220 : 150), spacing: spacing, alignment: .top)]
        default: [GridItem(.adaptive(minimum: isWide ? 360 : 300), spacing: spacing, alignment: .top)]
        }
    }

    @ViewBuilder func card(_ bucket: LibrarySummary.Bucket) -> some View {
        switch level {
        case .years:
            SummaryCard(bucket: bucket, title: DayLabel.yearLabel(for: bucket.date), aspect: 4 / 3, large: true) {
                tap(bucket, at: anchor(of: bucket))
            }
        case .months:
            SummaryCard(bucket: bucket, title: DayLabel.monthYearLabel(for: bucket.date), aspect: 1, large: false) {
                tap(bucket, at: anchor(of: bucket))
            }
        default:
            DayMosaic(bucket: bucket, moment: model.moments[bucket.id], openMoment: model.openMoment) { photo in
                tap(bucket, photo: photo, at: anchor(of: bucket))
            }
        }
    }

    func anchor(of bucket: LibrarySummary.Bucket) -> UnitPoint {
        guard let frame = frames.frames[bucket.id], size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: frame.midX / size.width, y: min(max(frame.minY / size.height, 0), 1))
    }

    /// A tap on a card zooms into it, unless it is the end of a pinch: the lifted fingers would tap a card of the level
    /// the pinch just arrived at.
    func tap(_ bucket: LibrarySummary.Bucket, photo: FileID? = nil, at point: UnitPoint) {
        guard pinchStart == nil, model.acceptsTaps else { return }
        zoom(by: 1, bucket: bucket, photo: photo, at: point)
    }

    func zoom(by steps: Int, bucket: LibrarySummary.Bucket?, photo: FileID? = nil, at point: UnitPoint) {
        model.move(from: level, by: steps, bucket: bucket, photo: photo, at: point)
    }

    var displayScale: Double { displayScale(of: pinch) }

    func displayScale(of scale: Double) -> Double {
        LibraryZoomGesture.displayScale(scale, canZoomIn: true, canZoomOut: level != .years)
    }

    /// Follows the fingers; on release settles on the level the pinch was heading for, with its speed.
    var magnify: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchStart == nil {
                    pinchStart = value.startLocation
                    pinchAnchor = value.startAnchor
                }
                pinch = Double(value.magnification)
            }
            .onEnded { value in
                let projected = LibraryZoomGesture.projectedScale(scale: Double(value.magnification), velocity: Double(value.velocity))
                let steps = LibraryZoomGesture.steps(projectedScale: projected)
                LibraryZoomModel.logger.debug(
                    "pinch ended: scale \(Double(value.magnification)), velocity \(Double(value.velocity)), steps \(steps)")
                let start = pinchStart ?? value.startLocation
                let bucket = frames.card(at: start).flatMap { id in buckets.first { $0.id == id } } ?? topBucket
                pinchStart = nil
                model.pinchEnded = .now
                withAnimation(.smooth(duration: 0.3)) { pinch = 1 }
                guard steps != 0, steps > 0 || level != .years else { return }
                LibraryZoomHaptics.trackpadLevelChange()
                // The photos travel on from where the fingers left them (the level is scaled around the pinch).
                model.releasedPinch = (
                    displayScale(of: Double(value.magnification)),
                    CGPoint(x: pinchAnchor.x * size.width, y: pinchAnchor.y * size.height)
                )
                zoom(by: steps, bucket: bucket, at: value.startAnchor)
            }
    }
}

/// A year or a month: its key photo with the date over it.
struct SummaryCard: View {
    let bucket: LibrarySummary.Bucket
    let title: String
    let aspect: CGFloat
    let large: Bool
    let open: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: open) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { SummaryPhoto(item: bucket.key, bucket: large ? 1024 : 256) }
                .overlay(alignment: .bottomLeading) { caption.zoomMorphCaption(of: bucket.key.fileId) }
                .clipShape(.rect(cornerRadius: large ? 14 : 10))
                .contentShape(.rect(cornerRadius: large ? 14 : 10))
        }
        .buttonStyle(.plain)
        #if os(visionOS)
            .hoverEffect()
        #endif
        .accessibilityLabel(Text(verbatim: "\(title), \(AccessibilityText.photos(bucket.count))"))
        .accessibilityHint(Text("Zooms in", bundle: .module, comment: "VoiceOver hint of a year or month card in the Library."))
    }

    var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(large ? Typography.yearTitle : Typography.overlayTitle)
            Text(AccessibilityText.photos(bucket.count))
                .font(large ? Typography.count : Typography.smallCount)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(large ? 16 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.black.opacity(OverlayLegibility.scrimOpacity(base: 0.55, increased: increased)), .clear],
                startPoint: .bottom, endPoint: .top
            )
            .padding(.top, -30)
        }
    }

    var increased: Bool { contrast == .increased || reduceTransparency }
}

/// A day: its date, how many photos it has, and its best photos (up to three, the last one saying how many more).
struct DayMosaic: View {
    let bucket: LibrarySummary.Bucket
    /// The moment this day starts (SPEC §16.1): its title above the day opens it.
    var moment: MomentHeaders.Entry? = nil
    var openMoment: (String) -> Void = { _ in }
    /// A photo (or the day, nil) was tapped.
    let open: (FileID?) -> Void

    var shown: [GridMedia] { Array(bucket.highlights.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let moment {
                Button {
                    openMoment(moment.momentId)
                } label: {
                    HStack(spacing: 4) {
                        Text(moment.title).font(.title3.weight(.bold)).lineLimit(1)
                        Image(systemName: "chevron.forward").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.bottom, -4)
                .accessibilityHint(Text("Opens the moment", bundle: .module))
            }
            Button {
                open(nil)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    // Bold date, light count (SPEC §17.5).
                    Text(DayLabel.label(for: bucket.date)).font(Typography.dayTitle)
                    Spacer()
                    Text(AccessibilityText.photos(bucket.count)).font(Typography.count).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            mosaic
                .clipShape(.rect(cornerRadius: 12))
        }
    }

    @ViewBuilder var mosaic: some View {
        let gap: CGFloat = 3
        switch shown.count {
        case 0:
            EmptyView()
        case 1:
            tile(shown[0], more: 0).aspectRatio(16 / 10, contentMode: .fit)
        case 2:
            HStack(spacing: gap) {
                tile(shown[0], more: 0)
                tile(shown[1], more: 0)
            }
            .aspectRatio(2, contentMode: .fit)
        default:
            Color.clear
                .aspectRatio(3 / 2, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let side: CGFloat = (proxy.size.height - gap) / 2
                        HStack(spacing: gap) {
                            tile(shown[0], more: 0)
                                .frame(width: max(proxy.size.width - side - gap, 0), height: proxy.size.height)
                            VStack(spacing: gap) {
                                tile(shown[1], more: 0).frame(width: side, height: side)
                                tile(shown[2], more: bucket.count - shown.count).frame(width: side, height: side)
                            }
                        }
                    }
                }
        }
    }

    func tile(_ item: GridMedia, more: Int) -> some View {
        Button {
            open(item.fileId)
        } label: {
            Color.clear
                .overlay { SummaryPhoto(item: item, bucket: 1024) }
                .overlay {
                    if more > 0 {
                        ZStack {
                            Color.black.opacity(0.35)
                            Text(verbatim: "+\(more.formatted())").font(Typography.figure).foregroundStyle(.white)
                        }
                        .zoomMorphCaption(of: item.fileId)
                        .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video {
                        Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                    }
                }
                .clipped()
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(GridTile.accessibilityLabel(for: item)))
    }
}

/// The picture of a grid item in a card, with its BlurHash until the preview is there.
struct SummaryPhoto: View {
    let item: GridMedia
    let bucket: Int

    var body: some View {
        PreviewImage(
            fileId: item.fileId, etag: item.etag, bucket: bucket, blurhash: item.blurhash, hasPreview: item.hasPreview,
            mimeType: item.mimeType, path: item.directory.hasPrefix("/") ? Self.path(item) : nil
        )
        .zoomMorphPhoto(item)
    }

    static func path(_ item: GridMedia) -> String {
        item.directory == "/" ? "/\(item.name)" : "\(item.directory)/\(item.name)"
    }
}

/// Card shapes while the summary is built (the first moment after a launch on a large library).
struct LibrarySummarySkeleton: View {
    let level: LibraryZoomLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    if level == .days { RoundedRectangle(cornerRadius: 4).frame(width: 140, height: 16) }
                    RoundedRectangle(cornerRadius: 14).aspectRatio(level == .years ? 4 / 3 : 3 / 2, contentMode: .fit)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.quaternary)
        .skeletonPulse()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Carries out the zoom model's placements in a grid (the photo a zoom from the days arrives at) and tells the model
    /// which photo is at the top of the grid.
    func libraryZoomPlacement(_ model: LibraryZoomModel?, locator: GridTileLocator) -> some View {
        onChange(of: model?.gridPlacement, initial: true) { _, placement in
            guard let model, let placement else { return }
            model.gridPlacement = nil
            locator.place(placement.fileId, placement.fraction)
        }
        .onAppear {
            guard let model else { return }
            model.gridTopItem = { locator.topItem() }
        }
    }
}
