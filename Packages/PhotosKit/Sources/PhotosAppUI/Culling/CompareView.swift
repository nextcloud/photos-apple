// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import ImageIO
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// Photos to compare side by side (SPEC §15.2).
struct CompareRequest: Identifiable, Hashable {
    let id = UUID()
    var ids: [FileID]
}

#if DEBUG
    extension CompareRequest {
        /// `PHOTOS_DEBUG_COMPARE=<count>` (debug builds): the compare view with the first photos, at launch, once.
        @MainActor private static var debugStartUsed = false

        @MainActor static func debugStart(ids: [FileID]) -> CompareRequest? {
            guard !debugStartUsed, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_COMPARE"], let count = Int(raw),
                ids.count >= count, count >= 2
            else { return nil }
            debugStartUsed = true
            return CompareRequest(ids: Array(ids.prefix(min(count, CompareLayout.maxPhotos))))
        }
    }
#endif

/// Where the photos of the compare view go, and the synchronised zoom they share.
enum CompareLayout {
    /// 2-up and 4-up, as in Lightroom's Survey view: more would make each photo too small to judge.
    static let maxPhotos = 4

    /// Columns and rows for `count` photos in an area of this shape: two side by side in a wide area, one above the
    /// other in a tall one; three and four in a 2 × 2 grid.
    static func grid(count: Int, size: CGSize) -> (columns: Int, rows: Int) {
        switch count {
        case ...1: (1, 1)
        case 2: size.width >= size.height ? (2, 1) : (1, 2)
        default: (2, 2)
        }
    }

    /// The scale at which a picture of `pixels` fills `area` (points per pixel), keeping its shape.
    static func fitScale(pixels: CGSize, area: CGSize) -> CGFloat {
        guard pixels.width > 0, pixels.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(area.width / pixels.width, area.height / pixels.height)
    }

    /// The zoom (relative to "fit") that shows one pixel of the photo on one pixel of the screen: 100 %.
    static func actualPixelsZoom(pixels: CGSize, area: CGSize, displayScale: CGFloat) -> CGFloat {
        let fit = fitScale(pixels: pixels, area: area)
        return max(1, 1 / (displayScale * fit))
    }

    /// The centre (fractions of the picture) kept inside the picture, so no zoomed picture is panned off its pane.
    static func clampedCenter(_ center: CGPoint, shown: CGSize, area: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, shownLength: CGFloat, areaLength: CGFloat) -> CGFloat {
            guard shownLength > areaLength, shownLength > 0 else { return 0.5 }
            let half = areaLength / 2 / shownLength
            return min(max(value, half), 1 - half)
        }
        return CGPoint(
            x: clamp(center.x, shownLength: shown.width, areaLength: area.width),
            y: clamp(center.y, shownLength: shown.height, areaLength: area.height))
    }

    /// Pixels the photo must have for this zoom to be sharp on screen; a preview smaller than that is replaced by the
    /// original.
    static func pixelsNeeded(zoom: CGFloat, fitScale: CGFloat, pixels: CGSize, displayScale: CGFloat) -> CGFloat {
        max(pixels.width, pixels.height) * fitScale * zoom * displayScale
    }
}

/// Zoom and pan shared by all photos of the compare view: zoom into one and all follow, to check focus side by side.
struct CompareZoom: Equatable {
    /// 1 shows each photo whole.
    var zoom: CGFloat = 1
    /// The point of each photo in the middle of its pane, as fractions of its width and height.
    var center = CGPoint(x: 0.5, y: 0.5)

    static let maximum: CGFloat = 16

    var isZoomed: Bool { zoom > 1.001 }
}

extension View {
    /// Shows the compare view the way the platform shows the viewer: pushed on the Mac and Vision Pro, a full-screen
    /// cover on iPhone and iPad.
    func compareView(_ request: Binding<CompareRequest?>) -> some View {
        modifier(ComparePresenter(request: request))
    }
}

private struct ComparePresenter: ViewModifier {
    @Binding var request: CompareRequest?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $request) { request in
                NavigationStack { CompareView(ids: request.ids) }
                    .environment(session)
            }
        #else
            content.navigationDestination(item: $request) { request in
                CompareView(ids: request.ids)
            }
        #endif
    }
}

/// 2-up and 4-up comparison with synchronised zoom and pan (SPEC §15.2). Arrow keys move between the photos, Z zooms
/// to 100 % and back, P X U 0–5 rate the photo with the focus, Return keeps it as the winner and rejects the others.
struct CompareView: View {
    let ids: [FileID]
    @State private var items: [MediaItem] = []
    @State private var focused = 0
    @State private var zoom = CompareZoom()
    /// The zoom when a pinch began.
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGPoint?
    @State private var marks: [FileID: CullingMark] = [:]
    @State private var culling = CullingModel()
    @State private var confirmWinner = false
    @State private var paneSize: CGSize = .zero
    @FocusState private var hasFocus: Bool
    @Environment(SessionModel.self) private var session
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let layout = CompareLayout.grid(count: max(items.count, 1), size: proxy.size)
            let spacing: CGFloat = 2
            let pane = CGSize(
                width: (proxy.size.width - spacing * CGFloat(layout.columns - 1)) / CGFloat(layout.columns),
                height: (proxy.size.height - spacing * CGFloat(layout.rows - 1)) / CGFloat(layout.rows))
            VStack(spacing: spacing) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            if index < items.count {
                                ComparePane(
                                    item: items[index], mark: marks[items[index].fileId] ?? .none, isFocused: index == focused,
                                    zoom: zoom, size: pane
                                )
                                .frame(width: pane.width, height: pane.height)
                                .contentShape(.rect)
                                .onTapGesture(count: 2) { toggleActualPixels(index: index) }
                                .onTapGesture { focused = index }
                                .gesture(panGesture(pane: pane, item: items[index]))
                            } else {
                                Color.clear.frame(width: pane.width, height: pane.height)
                            }
                        }
                    }
                }
            }
            .onAppear { paneSize = pane }
            .onChange(of: pane) { _, size in paneSize = size }
        }
        .background(Color.black.ignoresSafeArea())
        .simultaneousGesture(magnifyGesture)
        .cullingFeedback(culling)
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in
            handle(press.key)
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU012345zZ")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]), let key = press.characters.first else {
                return .ignored
            }
            if key == "z" || key == "Z" {
                toggleActualPixels(index: focused)
                return .handled
            }
            guard let command = CullingCommand(key: key), let item = items[safe: focused] else { return .ignored }
            culling.apply(command, to: [item], session: session, undoManager: undoManager)
            return .handled
        }
        .navigationTitle(
            String(localized: "Compare \(items.count) Photos", bundle: .module, comment: "Title of the compare view. Plural variations.")
        )
        .toolbar { toolbar }
        .focusedSceneValue(\.gridActions, actions)
        .confirmationDialog(
            String(
                localized: "Keep this photo and reject the other \(max(items.count - 1, 0))?", bundle: .module,
                comment: "Compare view: confirmation of Keep This One. Plural variations."),
            isPresented: $confirmWinner, titleVisibility: .visible
        ) {
            Button(String(localized: "Keep and Reject Others", bundle: .module, comment: "Compare view: confirms choosing the winner.")) {
                chooseWinner()
            }
        } message: {
            Text(
                "The photo gets the Pick flag, the others the Rejected flag. Nothing is deleted.", bundle: .module,
                comment: "Compare view: what choosing a winner does.")
        }
        .task { await load() }
        .task(id: session.services != nil) {
            guard let services = session.services else { return }
            do {
                for try await value in CullingStore(database: services.database).observeMarks() { marks = value }
            } catch {}
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
                }
            }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                toggleActualPixels(index: focused)
            } label: {
                Label(
                    zoom.isZoomed ? String(localized: "Zoom to Fit", bundle: .module) : actualSizeTitle,
                    systemImage: zoom.isZoomed ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
            }
            .help(zoom.isZoomed ? String(localized: "Zoom to Fit", bundle: .module) : actualSizeTitle)
            Button {
                confirmWinner = true
            } label: {
                Label(keepTitle, systemImage: "checkmark.seal")
            }
            .help(keepTitle)
            .disabled(items.count < 2 || !session.features.has(.systemtags))
        }
    }

    var actualSizeTitle: String {
        String(localized: "Zoom to 100 %", bundle: .module, comment: "Compare view: show the photos at their actual pixels (key Z).")
    }

    var keepTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Keep This One", bundle: .module, comment: "Compare view: the photo with the focus wins (Return)."),
            other: LocalizedStringResource(
                "Keep this one", bundle: .module, comment: "Compare view: the photo with the focus wins (Return)."))
    }

    /// Zoom In / Out / to Fit and rating from the menu bar.
    var actions: GridActions {
        let item = items[safe: focused]
        var actions = GridActions(
            selectionCount: item == nil ? 0 : 1, allFavorite: item?.isFavorite ?? false,
            toggleFavorite: {
                guard let item else { return }
                let undoManager = undoManager
                Task { await session.perform(.favorite([item], value: !item.isFavorite), undoManager: undoManager) }
            },
            delete: {}, toggleInfo: {}, addToAlbum: {},
            zoomIn: zoom.zoom < CompareZoom.maximum ? { setZoom(zoom.zoom * 1.5) } : nil,
            zoomOut: zoom.isZoomed ? { setZoom(zoom.zoom / 1.5) } : nil)
        actions.zoomToFit = zoom.isZoomed ? { setZoom(1) } : nil
        if let item, session.features.has(.systemtags) {
            actions.cull = { command in culling.apply(command, to: [item], session: session, undoManager: undoManager) }
        }
        return actions
    }

    func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        let layout = CompareLayout.grid(count: items.count, size: paneSize)
        switch key {
        case .leftArrow: focused = max(focused - 1, 0)
        case .rightArrow: focused = min(focused + 1, items.count - 1)
        case .upArrow: if focused - layout.columns >= 0 { focused -= layout.columns }
        case .downArrow: if focused + layout.columns < items.count { focused += layout.columns }
        case .return:
            guard items.count > 1, session.features.has(.systemtags) else { return .ignored }
            confirmWinner = true
        case .escape: dismiss()
        default: return .ignored
        }
        return .handled
    }

    func setZoom(_ value: CGFloat) {
        withAnimation(reduceMotion ? nil : .snappy) {
            zoom.zoom = min(max(value, 1), CompareZoom.maximum)
            if !zoom.isZoomed { zoom.center = CGPoint(x: 0.5, y: 0.5) }
        }
    }

    /// Z or a double click: 100 % (at the point clicked, else where the zoom is), or back to the whole photo.
    func toggleActualPixels(index: Int) {
        guard let item = items[safe: index] else { return }
        focused = index
        if zoom.isZoomed {
            setZoom(1)
        } else {
            let target = CompareLayout.actualPixelsZoom(pixels: ComparePane.pixels(of: item), area: paneSize, displayScale: displayScale)
            setZoom(max(target, 2))
        }
    }

    var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom.zoom
                pinchStart = start
                zoom.zoom = min(max(start * value.magnification, 1), CompareZoom.maximum)
            }
            .onEnded { _ in
                pinchStart = nil
                if !zoom.isZoomed { setZoom(1) }
            }
    }

    /// Dragging a zoomed photo moves all of them: the same spot stays in the middle of every pane.
    func panGesture(pane: CGSize, item: MediaItem) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let start = dragStart ?? zoom.center
                dragStart = start
                let pixels = ComparePane.pixels(of: item)
                let fit = CompareLayout.fitScale(pixels: pixels, area: pane)
                let shown = CGSize(width: pixels.width * fit * zoom.zoom, height: pixels.height * fit * zoom.zoom)
                guard shown.width > 0, shown.height > 0 else { return }
                let moved = CGPoint(
                    x: start.x - value.translation.width / shown.width, y: start.y - value.translation.height / shown.height)
                zoom.center = CompareLayout.clampedCenter(moved, shown: shown, area: pane)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Return: the photo with the focus is picked, the others rejected (undoable).
    func chooseWinner() {
        guard let winner = items[safe: focused] else { return }
        let others = items.filter { $0.fileId != winner.fileId }
        culling.apply(.flag(.pick), to: [winner], session: session, undoManager: undoManager)
        culling.apply(.flag(.reject), to: others, session: session, undoManager: undoManager)
    }

    func load() async {
        guard let library = session.services?.library, let map = try? await library.fetchItems(ids) else { return }
        items = ids.compactMap { map[$0] }
    }
}

/// One photo of the compare view, zoomed and panned like the others.
private struct ComparePane: View {
    let item: MediaItem
    let mark: CullingMark
    let isFocused: Bool
    let zoom: CompareZoom
    let size: CGSize
    @State private var image: CGImage?
    /// The resolution loaded: preview buckets, then the original (`Int.max`).
    @State private var loadedPixels = 0
    @Environment(SessionModel.self) private var session
    @Environment(\.displayScale) private var displayScale

    /// The photo's size in pixels: the server's, else the picture loaded so far.
    static func pixels(of item: MediaItem, image: CGImage? = nil) -> CGSize {
        if let width = item.width, let height = item.height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        if let image { return CGSize(width: image.width, height: image.height) }
        return CGSize(width: 1, height: 1)
    }

    var pixels: CGSize { Self.pixels(of: item, image: image) }

    /// What the zoom needs: a preview bucket, or the original.
    var neededPixels: Int {
        let fit = CompareLayout.fitScale(pixels: pixels, area: size)
        let needed = CompareLayout.pixelsNeeded(zoom: zoom.zoom, fitScale: fit, pixels: pixels, displayScale: displayScale)
        if needed <= 1024 { return 1024 }
        if needed <= 4096 || item.kind == .video { return 4096 }
        return Int.max
    }

    var body: some View {
        let fit = CompareLayout.fitScale(pixels: pixels, area: size)
        let shown = CGSize(width: pixels.width * fit * zoom.zoom, height: pixels.height * fit * zoom.zoom)
        let center = CompareLayout.clampedCenter(zoom.center, shown: shown, area: size)
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(zoom.zoom * fit * displayScale >= 2 ? .none : .high)
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.width * (0.5 - center.x), y: shown.height * (0.5 - center.y))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(alignment: .bottom) { caption }
        .overlay {
            Rectangle()
                .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AccessibilityText.media(
                isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, place: item.place,
                isFavorite: item.isFavorite)
        )
        .accessibilityValue(CullingWording.description(of: mark))
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .task(id: neededPixels) { await load(neededPixels) }
    }

    var caption: some View {
        HStack(spacing: 8) {
            Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
            Text(item.timestamp.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            if !mark.isEmpty { CullingMarkPill(mark: mark) }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    /// The preview of the size wanted, or the original for actual pixels; never back to a smaller one.
    func load(_ wanted: Int) async {
        guard wanted > loadedPixels, let services = session.services else { return }
        if image == nil, let cached = services.images.cache.bestMemoryImage(fileId: item.fileId, etag: item.etag, upTo: 4096) {
            image = cached
        }
        if wanted == Int.max, item.kind == .image {
            if let original = await Self.original(item, services: services), !Task.isCancelled {
                image = original
                loadedPixels = Int.max
            }
            return
        }
        let request = ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: wanted, hasPreview: item.hasPreview, mimeType: item.mimeType,
            originalURL: services.originalURL(for: item))
        if let loaded = await services.images.preview(request), !Task.isCancelled {
            image = loaded
            loadedPixels = wanted
        }
    }

    /// The original decoded at full size with its orientation applied (RAW files too: Image I/O develops them).
    static func original(_ item: MediaItem, services: AccountServices) async -> CGImage? {
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
