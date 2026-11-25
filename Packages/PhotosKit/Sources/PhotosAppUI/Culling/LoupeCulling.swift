// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import ImageIO
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// Photos to go through in the culling view (SPEC §16.5.2).
public struct LoupeRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    var ids: [FileID]
    var startId: FileID

    init(ids: [FileID], startId: FileID) {
        id = UUID()
        self.ids = ids
        self.startId = startId
    }

    /// What a grid hands over: several selected photos are culled on their own; one selected photo (or none) starts the
    /// whole grid there.
    static func from(gridIds: [FileID], selected: Set<FileID>) -> LoupeRequest? {
        guard !gridIds.isEmpty else { return nil }
        if selected.count > 1 {
            let ordered = gridIds.filter { selected.contains($0) }
            if let first = ordered.first { return LoupeRequest(ids: ordered, startId: first) }
        }
        let start = selected.first.flatMap { id in gridIds.contains(id) ? id : nil } ?? gridIds[0]
        return LoupeRequest(ids: gridIds, startId: start)
    }

    #if DEBUG
        /// `PHOTOS_DEBUG_LOUPE=<index>` (debug builds): the culling view over the grid at launch, once.
        @MainActor private static var debugStartUsed = false

        @MainActor static func debugStart(ids: [FileID]) -> LoupeRequest? {
            guard !debugStartUsed, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOUPE"], let index = Int(raw),
                ids.indices.contains(index)
            else { return nil }
            debugStartUsed = true
            return LoupeRequest(ids: ids, startId: ids[index])
        }
    #endif
}

enum LoupeWording {
    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Culling View", bundle: .module,
                comment: "Image menu: full-screen loupe with filmstrip to go through photos and rate them (⌥⌘L)."),
            other: LocalizedStringResource(
                "Culling view", bundle: .module, comment: "Full-screen loupe with filmstrip to go through photos and rate them."))
    }

    static var peaking: String {
        String(localized: "Focus Peaking", bundle: .module, comment: "Culling view: highlights the sharpest edges (key F).")
    }

    static var clipping: String {
        String(
            localized: "Clipping Warnings", bundle: .module,
            comment: "Culling view: marks blown highlights in red and blocked shadows in blue (key J).")
    }

    static var histogram: String {
        String(localized: "Histogram", bundle: .module, comment: "Culling view: shows the photo's histogram (key H).")
    }

    static var actualSize: String {
        String(
            localized: "Zoom to 100 %", bundle: .module, comment: "Compare view: show the photos at their actual pixels (key Z).")
    }

    static var fit: String { String(localized: "Zoom to Fit", bundle: .module) }

    /// "12 of 340", the viewer's wording.
    static func position(_ index: Int, of count: Int) -> String {
        AccessibilityText.position(index: index, count: count)
    }
}

/// Toggles of the culling view, kept for the next time.
enum LoupeSettings {
    static let peakingKey = "loupe.peaking"
    static let clippingKey = "loupe.clipping"
    static let histogramKey = "loupe.histogram"
}

extension View {
    /// Shows the culling view: in a full-screen window of its own on the Mac (the main window stays as it is), as a
    /// full-screen cover on iPhone and iPad, pushed on Vision Pro.
    func loupeCulling(_ request: Binding<LoupeRequest?>) -> some View {
        modifier(LoupePresenter(request: request))
    }
}

private struct LoupePresenter: ViewModifier {
    @Binding var request: LoupeRequest?
    @Environment(SessionModel.self) private var session
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $request) { request in
                LoupeCullingView(request: request)
                    .environment(session)
            }
        #elseif os(macOS)
            content.onChange(of: request) { _, new in
                guard let new else { return }
                LoupeSessions.requests[new.id] = new
                openWindow(id: LoupeWindowValue.sceneId, value: LoupeWindowValue(token: new.id, account: session.account.id.rawValue))
                request = nil
            }
        #else
            content.navigationDestination(item: $request) { request in
                LoupeCullingView(request: request)
            }
        #endif
    }
}

#if os(macOS)
    import AppKit

    /// The culling view's window on the Mac. Not restored with the app: the photos it shows live in memory only.
    public struct LoupeWindowValue: Codable, Hashable, Sendable {
        public var token: UUID
        public var account: String
        public static let sceneId = "loupe"
    }

    /// The requests of open culling windows (the window's value only carries an id: a library can have 100 000 photos).
    @MainActor enum LoupeSessions {
        static var requests: [UUID: LoupeRequest] = [:]
    }

    /// The content of a culling window: full screen when it opens; Esc or Close ends it.
    public struct LoupeWindowView: View {
        @Binding var value: LoupeWindowValue?
        @Environment(AppModel.self) private var app
        @Environment(\.dismiss) private var dismiss

        public init(value: Binding<LoupeWindowValue?>) {
            _value = value
        }

        public var body: some View {
            Group {
                if let value, let request = LoupeSessions.requests[value.token], let session = app.session,
                    session.account.id.rawValue == value.account
                {
                    LoupeCullingView(request: request) { close() }
                        .environment(session)
                } else {
                    ContentUnavailableView(
                        String(localized: "Culling ended", bundle: .module, comment: "A culling window whose photos are gone."),
                        systemImage: "rectangle.on.rectangle.slash")
                }
            }
            .frame(minWidth: 800, minHeight: 560)
            .background(LoupeWindowConfigurator())
            .onDisappear {
                if let token = value?.token { LoupeSessions.requests[token] = nil }
            }
        }

        func close() {
            if let token = value?.token { LoupeSessions.requests[token] = nil }
            dismiss()
        }
    }

    /// Puts the window into full screen once, when it first appears.
    private struct LoupeWindowConfigurator: NSViewRepresentable {
        final class Probe: NSView {
            var done = false

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard !done, let window else { return }
                done = true
                window.title = LoupeWording.menuTitle
                window.backgroundColor = .black
                #if DEBUG
                    // Screenshots of the window itself (`screencapture -l`): no full screen space.
                    if ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOUPE_WINDOWED"] != nil { return }
                #endif
                DispatchQueue.main.async {
                    if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                }
            }
        }

        func makeNSView(context: Context) -> Probe { Probe() }
        func updateNSView(_ nsView: Probe, context: Context) {}
    }
#endif

/// Zoom of the culling view: fit, or 100 % around a point of the photo.
struct LoupeZoom: Equatable {
    /// Relative to "fit"; 1 is the whole photo.
    var scale: CGFloat = 1
    /// The point of the photo in the middle of the stage (fractions of its width and height).
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Zoomed only while the pointer or finger is held down.
    var isHeld = false

    var isZoomed: Bool { scale > 1.001 }

    /// The loupe magnifies at least this much: a photo with about as many pixels as the screen would otherwise not
    /// change at "100 %" (as in the compare view).
    static let minimumLoupe: CGFloat = 2
}

/// Full-screen culling (SPEC §16.5.2): the photo large, a filmstrip below, 100 % on a click or while held, focus
/// peaking, clipping warnings, histogram, and the culling keys (P X U 0–5) with auto-advance.
struct LoupeCullingView: View {
    let request: LoupeRequest
    /// Ends the culling view (the Mac's window); nil: `dismiss`.
    var close: (() -> Void)? = nil
    @State private var index = 0
    @State private var items: [FileID: MediaItem] = [:]
    @State private var marks: [FileID: CullingMark] = [:]
    @State private var culling = CullingModel()
    @State private var zoom = LoupeZoom()
    @State private var stageSize: CGSize = .zero
    @State private var facts: ExifFacts?
    @AppStorage(LoupeSettings.peakingKey) private var peaking = false
    @AppStorage(LoupeSettings.clippingKey) private var clipping = false
    @AppStorage(LoupeSettings.histogramKey) private var showsHistogram = true
    @FocusState private var hasFocus: Bool
    @Environment(SessionModel.self) private var session
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var ids: [FileID] { request.ids }
    var currentId: FileID? { ids.indices.contains(index) ? ids[index] : nil }
    var current: MediaItem? { currentId.flatMap { items[$0] } }
    var mark: CullingMark { currentId.flatMap { marks[$0] } ?? .none }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            LoupeStage(
                item: current, zoom: $zoom, peaking: peaking, clipping: clipping, showsHistogram: showsHistogram, facts: facts,
                step: step
            )
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                stageSize = $0
            }
            .cullingFeedback(culling)
            controls
            LoupeFilmstrip(ids: ids, index: $index, items: items, marks: marks)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        #if os(iOS)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear {
            hasFocus = true
            index = ids.firstIndex(of: request.startId) ?? 0
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape, .space, .home, .end]) { press in
            handle(press.key)
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU012345zZfFjJhH")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]), let key = press.characters.first else {
                return .ignored
            }
            return handle(character: key)
        }
        .focusedSceneValue(\.gridActions, actions)
        .task(id: index) { await loadAround(index) }
        .task(id: current?.fileId) {
            facts = nil
            guard let current else { return }
            facts = await session.exifFacts(for: current)
        }
        .task(id: session.services != nil) {
            guard let services = session.services else { return }
            do {
                for try await value in CullingStore(database: services.database).observeMarks() { marks = value }
            } catch {}
        }
        .onChange(of: index) { _, _ in
            if !zoom.isHeld { zoom = LoupeZoom() }
        }
        #if DEBUG
            // UI checks without the real keyboard: `PHOTOS_DEBUG_LOUPE_KEYS=f,j,3,p` gives these keys, one every two seconds.
            .task {
                guard let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_LOUPE_KEYS"] else { return }
                for key in raw.split(separator: ",") {
                    try? await Task.sleep(for: .seconds(2))
                    // Not before the photo is there: a key without a photo does nothing.
                    while current == nil && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
                    if let character = key.first { _ = handle(character: character) }
                }
            }
        #endif
    }

    // MARK: Bars

    var topBar: some View {
        HStack(spacing: 14) {
            Button {
                end()
            } label: {
                Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Close", bundle: .module))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: current?.name ?? " ").font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if let current {
                        Text(current.timestamp.formatted(date: .abbreviated, time: .standard))
                    }
                    Text(LoupeWording.position(index, of: ids.count)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !mark.isEmpty { CullingMarkPill(mark: mark) }
            Spacer(minLength: 8)
            toggle(LoupeWording.peaking, key: "F", systemImage: "scope", isOn: $peaking)
            toggle(LoupeWording.clipping, key: "J", systemImage: "exclamationmark.triangle", isOn: $clipping)
            toggle(LoupeWording.histogram, key: "H", systemImage: "chart.bar.xaxis", isOn: $showsHistogram)
            Button {
                toggleActualPixels(at: nil)
            } label: {
                Label(
                    zoom.isZoomed ? LoupeWording.fit : LoupeWording.actualSize,
                    systemImage: zoom.isZoomed ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .help(Text(verbatim: zoom.isZoomed ? LoupeWording.fit : "\(LoupeWording.actualSize) (Z)"))
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.primary)
    }

    func toggle(_ title: String, key: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(Text(verbatim: "\(title) (\(key))"))
    }

    /// Pick, reject and stars for pointer and touch (the keys do the same).
    var controls: some View {
        HStack(spacing: 18) {
            Button {
                step(-1)
            } label: {
                Label(String(localized: "Previous", bundle: .module), systemImage: "chevron.backward")
            }
            .disabled(index == 0)
            Divider().frame(height: 18)
            ForEach([CullingFlag.pick, .reject, .none], id: \.self) { flag in
                Button {
                    apply(.flag(flag))
                } label: {
                    Label(CullingWording.flagTitle(flag), systemImage: CullingWording.flagSymbol(flag))
                }
                .foregroundStyle(mark.flag == flag && flag != .none ? (flag == .pick ? Color.yellow : Color.red) : Color.primary)
                .help(Text(verbatim: "\(CullingWording.flagTitle(flag)) (\(flag == .pick ? "P" : flag == .reject ? "X" : "U"))"))
            }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                ForEach(1...CullingTags.maxRating, id: \.self) { stars in
                    Button {
                        apply(.rate(mark.rating == stars ? 0 : stars))
                    } label: {
                        Label(CullingWording.ratingTitle(stars), systemImage: stars <= mark.rating ? "star.fill" : "star")
                    }
                    .foregroundStyle(stars <= mark.rating ? Color.yellow : Color.secondary)
                    .help(Text(verbatim: "\(CullingWording.ratingTitle(stars)) (\(stars))"))
                }
            }
            Divider().frame(height: 18)
            Button {
                step(1)
            } label: {
                Label(String(localized: "Next", bundle: .module), systemImage: "chevron.forward")
            }
            .disabled(index >= ids.count - 1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.vertical, 8)
        .disabled(current == nil)
    }

    // MARK: Actions

    var actions: GridActions {
        let item = current
        var actions = GridActions(
            selectionCount: item == nil ? 0 : 1, allFavorite: item?.isFavorite ?? false,
            toggleFavorite: {
                guard let item else { return }
                let undoManager = undoManager
                Task { await session.perform(.favorite([item], value: !item.isFavorite), undoManager: undoManager) }
            },
            delete: {}, toggleInfo: {}, addToAlbum: {},
            zoomIn: zoom.isZoomed ? nil : { toggleActualPixels(at: nil) },
            zoomOut: zoom.isZoomed ? { zoom = LoupeZoom() } : nil)
        actions.zoomToFit = zoom.isZoomed ? { zoom = LoupeZoom() } : nil
        if item != nil, session.features.has(.systemtags) {
            actions.cull = { command in apply(command) }
        }
        return actions
    }

    func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .leftArrow, .upArrow: step(-1)
        case .rightArrow, .downArrow: step(1)
        case .home: index = 0
        case .end: index = max(ids.count - 1, 0)
        case .space: toggleActualPixels(at: nil)
        case .escape:
            if zoom.isZoomed { zoom = LoupeZoom() } else { end() }
        default: return .ignored
        }
        return .handled
    }

    func handle(character key: Character) -> KeyPress.Result {
        switch key {
        case "z", "Z": toggleActualPixels(at: nil)
        case "f", "F": peaking.toggle()
        case "j", "J": clipping.toggle()
        case "h", "H": showsHistogram.toggle()
        default:
            guard let command = CullingCommand(key: key), current != nil else { return .ignored }
            apply(command)
        }
        return .handled
    }

    func step(_ delta: Int) {
        guard !ids.isEmpty else { return }
        index = min(max(index + delta, 0), ids.count - 1)
    }

    func apply(_ command: CullingCommand) {
        guard let current, session.features.has(.systemtags) else { return }
        culling.apply(command, to: [current], session: session, undoManager: undoManager)
        guard CullingSettings.autoAdvance else { return }
        let from = index
        Task {
            // A moment later: the confirmation is seen on the photo it is about.
            try? await Task.sleep(for: .milliseconds(250))
            if index == from { index = LoupeGeometry.advanced(from: from, count: ids.count) }
        }
    }

    /// 100 % at a point of the stage (the middle when nil), or back to fit.
    func toggleActualPixels(at location: CGPoint?) {
        guard let current else { return }
        if zoom.isZoomed {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { zoom = LoupeZoom() }
            return
        }
        let pixels = LoupeStage.pixels(of: current)
        let target = LoupeGeometry.actualPixelsZoom(pixels: pixels, area: stageSize, displayScale: displayScale)
        let center = location.map { LoupeGeometry.photoPoint(at: $0, pixels: pixels, area: stageSize) } ?? CGPoint(x: 0.5, y: 0.5)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            zoom = LoupeZoom(scale: max(target, LoupeZoom.minimumLoupe), center: center)
        }
    }

    func end() {
        if let close { close() } else { dismiss() }
    }

    /// The photos around the current one, from the index; the next previews are fetched ahead so stepping is instant.
    func loadAround(_ index: Int) async {
        guard let services = session.services else { return }
        let window = LoupeGeometry.window(around: index, count: ids.count, radius: 40)
        let missing = ids[window].filter { items[$0] == nil }
        if !missing.isEmpty, let loaded = try? await services.library.fetchItems(Array(missing)) {
            items.merge(loaded) { _, new in new }
        }
        for ahead in [index + 1, index + 2, index - 1] where ids.indices.contains(ahead) {
            guard let item = items[ids[ahead]], item.kind == .image else { continue }
            let request = ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item))
            _ = await services.images.preview(request)
            if Task.isCancelled { return }
        }
    }
}

// MARK: - Stage

/// The photo, fitted or at 100 %, with the overlays and the histogram.
private struct LoupeStage: View {
    let item: MediaItem?
    @Binding var zoom: LoupeZoom
    let peaking: Bool
    let clipping: Bool
    let showsHistogram: Bool
    let facts: ExifFacts?
    let step: (Int) -> Void
    @State private var image: CGImage?
    @State private var shownId: FileID?
    @State private var loadedPixels = 0
    @State private var analysis: LoupeImages.Analysis?
    @State private var press: Press?
    @State private var holdTask: Task<Void, Never>?
    @Environment(SessionModel.self) private var session
    @Environment(\.displayScale) private var displayScale

    struct Press {
        var start: Date
        var startCenter: CGPoint
    }

    /// Longer than this is a hold (100 % while held); shorter is a click (100 % until the next click).
    static let holdDelay: Duration = .milliseconds(220)

    static func pixels(of item: MediaItem, image: CGImage? = nil) -> CGSize {
        if let width = item.width, let height = item.height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        if let image { return CGSize(width: image.width, height: image.height) }
        return CGSize(width: 3, height: 2)
    }

    struct AnalysisKey: Equatable {
        var fileId: FileID?
        var hasImage: Bool
        var clipping: Bool
        var peaking: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let area = proxy.size
            ZStack {
                if let item, let image, shownId == item.fileId {
                    photo(item: item, image: image, area: area)
                } else if item != nil {
                    ProgressView().controlSize(.small)
                }
                if showsHistogram, let analysis {
                    VStack {
                        HStack {
                            Spacer()
                            LoupeHistogramView(
                                histogram: analysis.histogram, facts: facts, clippedShare: clipping ? analysis.clippedShare : nil)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: area.width, height: area.height)
            .contentShape(.rect)
            .gesture(pressGesture(area: area))
            .task(id: neededPixels(area: area)) { await load(neededPixels(area: area)) }
        }
        .clipped()
        .task(id: AnalysisKey(fileId: shownId, hasImage: image != nil, clipping: clipping, peaking: peaking)) { await analyse() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            item.map {
                AccessibilityText.media(
                    isVideo: $0.kind == .video, isLivePhoto: $0.isLivePhoto, date: $0.timestamp, place: $0.place, isFavorite: $0.isFavorite)
            } ?? ""
        )
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: Text("Next", bundle: .module)) { step(1) }
        .accessibilityAction(named: Text("Previous", bundle: .module)) { step(-1) }
    }

    func photo(item: MediaItem, image: CGImage, area: CGSize) -> some View {
        let pixels = Self.pixels(of: item, image: image)
        let fit = LoupeGeometry.fitScale(pixels: pixels, area: area)
        let shown = CGSize(width: pixels.width * fit * zoom.scale, height: pixels.height * fit * zoom.scale)
        let center = LoupeGeometry.clampedCenter(zoom.center, shown: shown, area: area)
        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(zoom.scale * fit * displayScale >= 2 ? .none : .high)
            if clipping, let overlay = analysis?.clipping {
                Image(decorative: overlay, scale: 1).resizable().interpolation(.none).opacity(0.85)
            }
            if peaking, let overlay = analysis?.peaking {
                Image(decorative: overlay, scale: 1).resizable().interpolation(.none)
            }
        }
        .frame(width: shown.width, height: shown.height)
        .offset(x: shown.width * (0.5 - center.x), y: shown.height * (0.5 - center.y))
        .frame(width: area.width, height: area.height)
    }

    /// A click toggles 100 % at the point clicked; holding shows 100 % while held, following the pointer; a drag pans
    /// a zoomed photo; a swipe of an unzoomed one goes to the next or previous photo.
    func pressGesture(area: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let item else { return }
                let pixels = Self.pixels(of: item, image: image)
                if press == nil {
                    press = Press(start: Date(), startCenter: zoom.center)
                    if !zoom.isZoomed {
                        let location = value.startLocation
                        holdTask = Task {
                            try? await Task.sleep(for: Self.holdDelay)
                            guard !Task.isCancelled, press != nil else { return }
                            zoom = LoupeZoom(
                                scale: max(actualPixels(pixels: pixels, area: area), LoupeZoom.minimumLoupe),
                                center: LoupeGeometry.photoPoint(at: location, pixels: pixels, area: area), isHeld: true)
                        }
                    }
                    return
                }
                let moved = hypot(value.translation.width, value.translation.height)
                if zoom.isHeld {
                    // The held loupe follows the pointer: the point under it is the one shown.
                    zoom.center = LoupeGeometry.photoPoint(at: value.location, pixels: pixels, area: area)
                } else if zoom.isZoomed, moved > 3, let press {
                    let fit = LoupeGeometry.fitScale(pixels: pixels, area: area)
                    let shown = CGSize(width: pixels.width * fit * zoom.scale, height: pixels.height * fit * zoom.scale)
                    guard shown.width > 0, shown.height > 0 else { return }
                    let target = CGPoint(
                        x: press.startCenter.x - value.translation.width / shown.width,
                        y: press.startCenter.y - value.translation.height / shown.height)
                    zoom.center = LoupeGeometry.clampedCenter(target, shown: shown, area: area)
                } else if moved > 6 {
                    holdTask?.cancel()
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                defer { press = nil }
                if zoom.isHeld {
                    zoom = LoupeZoom()
                    return
                }
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 4 {
                    toggle(at: value.location, area: area)
                } else if !zoom.isZoomed, abs(value.translation.width) > 80,
                    abs(value.translation.width) > abs(value.translation.height) * 2
                {
                    step(value.translation.width < 0 ? 1 : -1)
                }
            }
    }

    func actualPixels(pixels: CGSize, area: CGSize) -> CGFloat {
        LoupeGeometry.actualPixelsZoom(pixels: pixels, area: area, displayScale: displayScale)
    }

    func toggle(at location: CGPoint, area: CGSize) {
        guard let item else { return }
        if zoom.isZoomed {
            withAnimation(.snappy(duration: 0.2)) { zoom = LoupeZoom() }
        } else {
            let pixels = Self.pixels(of: item, image: image)
            withAnimation(.snappy(duration: 0.2)) {
                zoom = LoupeZoom(
                    scale: max(actualPixels(pixels: pixels, area: area), LoupeZoom.minimumLoupe),
                    center: LoupeGeometry.photoPoint(at: location, pixels: pixels, area: area))
            }
        }
    }

    /// The preview size the zoom needs (1024, 4096), or the original (`Int.max`) for 100 % of a large photo.
    func neededPixels(area: CGSize) -> LoadKey {
        guard let item else { return LoadKey(fileId: nil, pixels: 0) }
        let pixels = Self.pixels(of: item)
        let fit = LoupeGeometry.fitScale(pixels: pixels, area: area)
        let needed = max(pixels.width, pixels.height) * fit * zoom.scale * displayScale
        let bucket = needed <= 4096 || item.kind == .video ? 4096 : Int.max
        return LoadKey(fileId: item.fileId, pixels: bucket)
    }

    struct LoadKey: Equatable {
        var fileId: FileID?
        var pixels: Int
    }

    func load(_ key: LoadKey) async {
        guard let item, let services = session.services, key.fileId == item.fileId else { return }
        if shownId != item.fileId {
            // A new photo: the best picture in memory at once (the filmstrip's or the prefetched preview), then sharper.
            shownId = item.fileId
            loadedPixels = 0
            analysis = nil
            image = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: 4096)
        }
        guard key.pixels > loadedPixels else { return }
        if key.pixels == Int.max, item.kind == .image {
            if let original = await LoupeOriginal.load(item, services: services), !Task.isCancelled, shownId == item.fileId {
                image = original
                loadedPixels = Int.max
            }
            return
        }
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: key.pixels, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
        if let loaded = await services.images.preview(request), !Task.isCancelled, shownId == item.fileId {
            image = loaded
            loadedPixels = key.pixels
        }
    }

    /// Histogram always; clipping and peaking when they are on. Off the main thread, on the preview (not the original:
    /// the overlays are computed at `LoupeImages.overlayPixels`).
    func analyse() async {
        guard let image, let id = shownId else { return }
        let wantsClipping = clipping
        let wantsPeaking = peaking
        let result = await Task.detached(priority: .userInitiated) {
            LoupeImages.analyse(image, clipping: wantsClipping, peaking: wantsPeaking)
        }.value
        guard !Task.isCancelled, id == shownId else { return }
        analysis = result
    }
}

/// The original of a photo decoded at full size (RAW developed by Image I/O), for 100 %.
enum LoupeOriginal {
    static func load(_ item: MediaItem, services: AccountServices) async -> CGImage? {
        guard
            let url = try? await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
        else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// The histogram (luminance and the three channels) with the exposure in one line below.
private struct LoupeHistogramView: View {
    let histogram: LoupeHistogram
    let facts: ExifFacts?
    /// Shown when the clipping warnings are on.
    let clippedShare: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                let scale = Double(histogram.scale)
                func path(_ counts: [Int]) -> Path {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (index, count) in counts.enumerated() {
                        let x = size.width * CGFloat(index) / 255
                        let y = size.height * (1 - CGFloat(min(Double(count) / scale, 1)))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    return path
                }
                context.fill(path(histogram.luminance), with: .color(.white.opacity(0.35)))
                context.blendMode = .plusLighter
                context.fill(path(histogram.red), with: .color(.red.opacity(0.55)))
                context.fill(path(histogram.green), with: .color(.green.opacity(0.55)))
                context.fill(path(histogram.blue), with: .color(.blue.opacity(0.6)))
            }
            .frame(width: 220, height: 90)
            .overlay(alignment: .topTrailing) {
                if histogram.luminance[255] > 0 || histogram.red[255] > 0 || histogram.green[255] > 0 || histogram.blue[255] > 0 {
                    Image(systemName: "triangle.fill").font(.system(size: 7)).foregroundStyle(.red).padding(2)
                }
            }
            .overlay(alignment: .topLeading) {
                if histogram.luminance[0] > 0 {
                    Image(systemName: "triangle.fill").font(.system(size: 7)).foregroundStyle(.blue).padding(2)
                }
            }
            if let exposure = Self.exposureLine(facts) {
                Text(verbatim: exposure).font(.caption.monospacedDigit()).lineLimit(1)
            }
            if let clippedShare, clippedShare > 0 {
                Text(
                    "\(clippedShare.formatted(.percent.precision(.fractionLength(0...1)))) clipped", bundle: .module,
                    comment: "Culling view: share of the photo with blown highlights or blocked shadows."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    /// "35 mm  ƒ/2.8  1/250 s  ISO 400", from what is known.
    static func exposureLine(_ facts: ExifFacts?) -> String? {
        guard let facts else { return nil }
        var parts: [String] = []
        if let focal = facts.focalLength { parts.append(InsightsWording.focalLength(focal)) }
        if let aperture = facts.aperture { parts.append(InsightsWording.aperture(aperture)) }
        if let exposure = facts.exposure { parts.append(InsightsWording.shutter(exposure)) }
        if let iso = facts.iso { parts.append(InsightsWording.iso(Double(iso))) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

// MARK: - Filmstrip

/// The photos in a row below the stage: the current one in the middle and outlined, marks on each, rejected dimmed.
private struct LoupeFilmstrip: View {
    let ids: [FileID]
    @Binding var index: Int
    let items: [FileID: MediaItem]
    let marks: [FileID: CullingMark]

    static let side: CGFloat = 64

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(ids.enumerated()), id: \.element) { position, id in
                        FilmstripThumb(id: id, item: items[id], mark: marks[id] ?? .none, isCurrent: position == index)
                            .onTapGesture { index = position }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { index = position }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: Self.side + 16)
            .background(Color.white.opacity(0.05))
            .onChange(of: index, initial: true) { _, value in
                guard ids.indices.contains(value) else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(ids[value], anchor: .center) }
            }
        }
    }
}

private struct FilmstripThumb: View {
    let id: FileID
    let item: MediaItem?
    let mark: CullingMark
    let isCurrent: Bool
    @Environment(SessionModel.self) private var session
    @State private var loaded: MediaItem?

    var shown: MediaItem? { item ?? loaded }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let shown {
                PreviewImage(item: shown, bucket: 256)
            } else {
                Color.white.opacity(0.08)
            }
            if !mark.isEmpty {
                HStack(spacing: 2) {
                    if mark.flag != .none {
                        Image(systemName: CullingWording.flagSymbol(mark.flag))
                            .foregroundStyle(mark.flag == .pick ? Color.yellow : Color.white)
                    }
                    if mark.rating > 0 {
                        Text(verbatim: "\(mark.rating)★").foregroundStyle(.yellow)
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 3))
                .padding(3)
            }
        }
        .frame(width: LoupeFilmstrip.side, height: LoupeFilmstrip.side)
        .clipShape(.rect(cornerRadius: 4))
        .opacity(mark.flag == .reject ? 0.4 : 1)
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(isCurrent ? Design.accent : .clear, lineWidth: 3)
        }
        .scaleEffect(isCurrent ? 1 : 0.92)
        .animation(.snappy(duration: 0.15), value: isCurrent)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: shown?.name ?? ""))
        .accessibilityValue(CullingWording.description(of: mark))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .task(id: id) {
            guard item == nil, loaded == nil, let library = session.services?.library else { return }
            loaded = try? await library.fetchItems([id])[id]
        }
    }
}
