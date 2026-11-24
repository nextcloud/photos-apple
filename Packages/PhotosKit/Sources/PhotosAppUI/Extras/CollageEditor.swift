// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// What a collage or card starts with (SPEC §15.8.3).
struct CollageRequest: Identifiable {
    let id = UUID()
    var items: [MediaItem]
    var title = ""
    var subtitle = ""

    /// A memory as a card: its best photos, its title and dates.
    @MainActor static func memory(_ memory: Memory, session: SessionModel) async -> CollageRequest? {
        guard let services = session.services, let map = try? await services.library.fetchItems(memory.items) else { return nil }
        let items = memory.items.compactMap { map[$0] }
        let picked = CollagePicker.pick(items)
        guard !picked.isEmpty else { return nil }
        return CollageRequest(items: picked, title: memory.title, subtitle: Memories.dateLine(for: memory) ?? "")
    }

    /// An album's best photos with its title.
    @MainActor static func album(_ album: Album, session: SessionModel) async -> CollageRequest? {
        guard let services = session.services, let entries = try? services.collections.albumItems(albumId: album.id),
            let map = try? await services.library.fetchItems(entries.map(\.fileId))
        else { return nil }
        let picked = CollagePicker.pick(entries.compactMap { map[$0.fileId] })
        guard !picked.isEmpty else { return nil }
        return CollageRequest(items: picked, title: album.title)
    }

    /// A selection: the photos in the order they were chosen, up to what a collage holds.
    static func selection(_ items: [MediaItem]) -> CollageRequest? {
        let photos = items.filter { $0.kind == .image }.prefix(CollageStyle.grid.maxPhotos)
        return photos.isEmpty ? nil : CollageRequest(items: Array(photos))
    }

    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Create Collage…", bundle: .module, comment: "Menu item: makes a collage of the photos."),
            other: LocalizedStringResource("Create collage", bundle: .module, comment: "Menu item: makes a collage of the photos."))
    }

    static var cardTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Create Card…", bundle: .module, comment: "Memory menu item: makes a card of the memory."),
            other: LocalizedStringResource("Create card", bundle: .module, comment: "Memory menu item: makes a card of the memory."))
    }
}

/// The shape of the collage.
enum CollageFormat: String, CaseIterable, Identifiable {
    case square, portrait, landscape, story
    var id: String { rawValue }

    /// Width / height.
    var aspect: CGFloat {
        switch self {
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .landscape: 3.0 / 2.0
        case .story: 9.0 / 16.0
        }
    }

    /// The page of the PDF, in points: a print size of the same shape (8 × 8 in, 8 × 10 in, 9 × 6 in, 4.5 × 8 in).
    var printSize: CGSize {
        switch self {
        case .square: CGSize(width: 576, height: 576)
        case .portrait: CGSize(width: 576, height: 720)
        case .landscape: CGSize(width: 648, height: 432)
        case .story: CGSize(width: 324, height: 576)
        }
    }

    var title: String {
        switch self {
        case .square: String(localized: "Square", bundle: .module, comment: "Collage format.")
        case .portrait: String(localized: "Portrait", bundle: .module, comment: "Collage format.")
        case .landscape: String(localized: "Landscape", bundle: .module, comment: "Collage format.")
        case .story: String(localized: "Story", bundle: .module, comment: "Collage format: tall 9:16, as for stories.")
        }
    }

    var systemImage: String {
        switch self {
        case .square: "square"
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        case .story: "iphone"
        }
    }
}

/// Colours and type of a collage.
enum CollageTheme: String, CaseIterable, Identifiable {
    case classic, night, paper, ocean
    var id: String { rawValue }

    var background: AnyShapeStyle {
        switch self {
        case .classic: AnyShapeStyle(Color.white)
        case .night: AnyShapeStyle(Color(red: 0.07, green: 0.07, blue: 0.08))
        case .paper: AnyShapeStyle(Color(red: 0.96, green: 0.93, blue: 0.87))
        case .ocean:
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 0, green: 0.51, blue: 0.79), Color(red: 0.11, green: 0.69, blue: 1)], startPoint: .topLeading,
                    endPoint: .bottomTrailing))
        }
    }

    /// A single colour standing for the theme (the picker's swatch).
    var swatch: Color {
        switch self {
        case .classic: .white
        case .night: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .paper: Color(red: 0.96, green: 0.93, blue: 0.87)
        case .ocean: Color(red: 0, green: 0.51, blue: 0.79)
        }
    }

    var text: Color {
        switch self {
        case .classic: Color(white: 0.12)
        case .night, .ocean: .white
        case .paper: Color(red: 0.35, green: 0.25, blue: 0.18)
        }
    }

    var design: Font.Design {
        switch self {
        case .classic: .default
        case .night: .rounded
        case .paper: .serif
        case .ocean: .default
        }
    }

    var cornerRadius: CGFloat { self == .night || self == .ocean ? 10 : 2 }

    var title: String {
        switch self {
        case .classic: String(localized: "Classic", bundle: .module, comment: "Collage theme: white.")
        case .night: String(localized: "Night", bundle: .module, comment: "Collage theme: black.")
        case .paper: String(localized: "Paper", bundle: .module, comment: "Collage theme: warm paper with a serif title.")
        case .ocean: String(localized: "Ocean", bundle: .module, comment: "Collage theme: Nextcloud blue.")
        }
    }
}

/// A collage being made: its photos in order, its look, the loaded pictures and their focus.
@MainActor @Observable final class CollageModel {
    var items: [MediaItem]
    var style: CollageStyle = .mosaic
    var theme: CollageTheme = .classic
    var format: CollageFormat = .square
    var title: String
    var subtitle: String
    var seed: UInt64 = 1
    /// The photo picked to be swapped with the next one tapped.
    var swapping: FileID?
    var images: [FileID: CGImage] = [:]
    var focus: [FileID: CGRect] = [:]
    /// Logical size of the canvas's long edge; everything is laid out at this size and scaled.
    static let logicalSide: CGFloat = 1000

    init(_ request: CollageRequest) {
        items = request.items
        title = request.title
        subtitle = request.subtitle
        // A memory's card with a big first photo and its title; a selection as a mosaic.
        if !request.title.isEmpty { style = .magazine }
    }

    var canvasSize: CGSize {
        format.aspect >= 1
            ? CGSize(width: Self.logicalSide, height: Self.logicalSide / format.aspect)
            : CGSize(width: Self.logicalSide * format.aspect, height: Self.logicalSide)
    }

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty || !subtitle.isEmpty }

    var layout: CollageLayout {
        let photos = items.map { item in
            CollagePhoto(
                id: item.fileId, aspect: images[item.fileId].map { Double($0.width) / Double(max(1, $0.height)) } ?? item.aspectRatio,
                focus: focus[item.fileId] ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CollageLayouts.layout(style, photos: photos, canvas: canvasSize, hasTitle: hasTitle, seed: seed)
    }

    /// Loads the pictures (1024 px for the screen, or 4096 px for an export) and finds what each must keep in view.
    func load(services: AccountServices, bucket: Int = 1024) async {
        await withTaskGroup(of: (FileID, CGImage?).self) { group in
            for item in items where bucket > 1024 || images[item.fileId] == nil {
                group.addTask {
                    let request = ImagePipeline.Request(
                        fileId: item.fileId, etag: item.etag, bucket: bucket, hasPreview: item.hasPreview, mimeType: item.mimeType)
                    return (item.fileId, await services.images.preview(request))
                }
            }
            for await (fileId, image) in group {
                guard let image else { continue }
                images[fileId] = image
                if focus[fileId] == nil {
                    focus[fileId] = await Task.detached(priority: .userInitiated) { FocusFinder.focus(in: image) }.value
                }
            }
        }
    }

    /// Taps on photos: the first picks one, the second swaps the two, the same one again lets go.
    func tap(_ fileId: FileID) {
        if let first = swapping {
            if first != fileId { items = items.swapped(first, fileId) }
            swapping = nil
        } else {
            swapping = fileId
        }
    }

    func remove(_ fileId: FileID) {
        guard items.count > 1 else { return }
        items.removeAll { $0.fileId == fileId }
        if swapping == fileId { swapping = nil }
    }

    func shuffle() {
        guard items.count > 1 else { return }
        var generator = SystemRandomNumberGenerator()
        let first = items[0]
        repeat { items.shuffle(using: &generator) } while items.count > 2 && items[0].fileId == first.fileId
        seed = UInt64.random(in: 1...UInt64.max, using: &generator)
    }

    // MARK: Export

    /// The collage as an image `side` pixels on its long edge.
    func renderImage(side: CGFloat = 3000) -> CGImage? {
        let renderer = ImageRenderer(content: canvas())
        renderer.scale = side / Self.logicalSide
        renderer.isOpaque = true
        return renderer.cgImage
    }

    func jpegData() -> Data? { renderImage().flatMap { ImageDecoding.jpegData($0, quality: 0.9) } }

    /// The collage as a one-page PDF of its print size, with the pictures at full resolution.
    func pdfData() -> Data? {
        let page = format.printSize
        let renderer = ImageRenderer(
            content: canvas().scaleEffect(page.width / canvasSize.width, anchor: .topLeading).frame(
                width: page.width, height: page.height, alignment: .topLeading))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            return nil
        }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// - Parameter onTap: on screen, what a tap on a photo does; nil in an export.
    func canvas(onTap: ((FileID) -> Void)? = nil) -> CollageCanvas {
        CollageCanvas(
            layout: layout, items: items, images: images, theme: theme, title: title, subtitle: subtitle,
            swapping: onTap == nil ? nil : swapping, onTap: onTap)
    }

    /// "Collage 2026-11-24 at 15.04.12.jpg".
    nonisolated static func fileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        return String(
            localized: "Collage \(stamp).jpg", bundle: .module, comment: "File name of a saved collage; the argument is date and time.")
    }
}

extension [MediaItem] {
    fileprivate func swapped(_ a: FileID, _ b: FileID) -> [MediaItem] {
        let order = CollagePicker.swapped(map(\.fileId), a, b)
        let byId = Dictionary(map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byId[$0] }
    }
}

/// Draws a collage at its logical size. The same view is on screen (scaled to fit) and in the exported image and PDF.
struct CollageCanvas: View {
    let layout: CollageLayout
    let items: [MediaItem]
    let images: [FileID: CGImage]
    let theme: CollageTheme
    let title: String
    let subtitle: String
    var swapping: FileID?
    var onTap: ((FileID) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // White prints on white paper disappear: Classic lays them on a light grey table.
            if theme == .classic && layout.cells.contains(where: \.isPrint) {
                Rectangle().fill(Color(white: 0.92))
            } else {
                Rectangle().fill(theme.background)
            }
            ForEach(layout.cells, id: \.index) { cell in
                if cell.index < items.count {
                    cellView(cell, item: items[cell.index])
                }
            }
            if let frame = layout.titleFrame { titleView(in: frame) }
        }
        .frame(width: layout.canvas.width, height: layout.canvas.height)
        .clipped()
    }

    @ViewBuilder func cellView(_ cell: CollageCell, item: MediaItem) -> some View {
        let picture = CroppedPicture(image: images[item.fileId], crop: cell.crop, size: cell.photoFrame.size)
        Group {
            if cell.isPrint {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.white)
                    picture.offset(x: cell.photoFrame.minX - cell.frame.minX, y: cell.photoFrame.minY - cell.frame.minY)
                }
                .frame(width: cell.frame.width, height: cell.frame.height)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            } else {
                picture.clipShape(.rect(cornerRadius: theme.cornerRadius))
            }
        }
        .overlay {
            if swapping == item.fileId {
                RoundedRectangle(cornerRadius: theme.cornerRadius + 2).strokeBorder(.tint, lineWidth: 6)
            }
        }
        .rotationEffect(.degrees(cell.rotation))
        .offset(x: cell.frame.minX, y: cell.frame.minY)
        .contentShape(Rectangle())
        .onTapGesture { onTap?(item.fileId) }
        .accessibilityElement()
        .accessibilityLabel(
            Text(
                AccessibilityText.media(
                    isVideo: false, isLivePhoto: item.isLivePhoto, date: item.timestamp, place: item.place, isFavorite: item.isFavorite,
                    caption: item.caption))
        )
        .accessibilityAddTraits(swapping == item.fileId ? [.isImage, .isSelected] : .isImage)
    }

    func titleView(in frame: CGRect) -> some View {
        let over = layout.titleOverPhoto
        return VStack(alignment: over ? .leading : .center, spacing: frame.height * 0.06) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: frame.height * (subtitle.isEmpty ? 0.42 : 0.34), weight: .bold, design: theme.design))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: frame.height * 0.2, weight: .medium, design: theme.design))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(over ? Color.white : theme.text)
        .padding(.horizontal, frame.width * 0.04)
        .frame(width: frame.width, height: frame.height, alignment: over ? .bottomLeading : .center)
        .padding(.bottom, over ? frame.height * 0.12 : 0)
        .background {
            if over {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .clipShape(.rect(bottomLeadingRadius: theme.cornerRadius, bottomTrailingRadius: theme.cornerRadius))
            }
        }
        .offset(x: frame.minX, y: frame.minY)
        .allowsHitTesting(false)
    }
}

/// The part `crop` of a picture, filling `size`.
struct CroppedPicture: View {
    let image: CGImage?
    let crop: CGRect
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.gray.opacity(0.2)
            if let image {
                let width = size.width / max(crop.width, 0.0001)
                let height = size.height / max(crop.height, 0.0001)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: width, height: height)
                    .offset(x: -crop.minX * width, y: -crop.minY * height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

/// The finished collage for the share sheet, rendered when a destination asks for it.
struct CollageExport: Transferable {
    let jpeg: @Sendable @MainActor () async -> Data?
    let pdf: @Sendable @MainActor () async -> Data?

    struct RenderFailed: Error {}

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { export in
            guard let data = await export.jpeg() else { throw RenderFailed() }
            return data
        }
        .suggestedFileName(CollageModel.fileName())
        DataRepresentation(exportedContentType: .pdf) { export in
            guard let data = await export.pdf() else { throw RenderFailed() }
            return data
        }
    }
}

/// Collage and card editor (SPEC §15.8.3): layouts that keep faces in view, a title, themes and formats; tap two photos to
/// swap them. Shares the image or a print-size PDF, or saves the collage to Nextcloud as a new photo.
struct CollageEditor: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: CollageModel
    @State private var saving = false
    @State private var message: String?

    init(request: CollageRequest) {
        _model = State(initialValue: CollageModel(request))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                controls
            }
            .padding()
            .navigationTitle(String(localized: "Collage", bundle: .module, comment: "Title of the collage editor."))
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        #if os(macOS)
            .frame(minWidth: 680, minHeight: 720)
        #endif
        .task {
            guard let services = session.services else { return }
            await model.load(services: services)
        }
        .alert(
            message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {}
    }

    var preview: some View {
        GeometryReader { proxy in
            let canvas = model.canvasSize
            let scale = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
            model.canvas(onTap: { fileId in
                withAnimation(reduceMotion ? .default : .spring(response: 0.35, dampingFraction: 0.8)) { model.tap(fileId) }
            })
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: 4))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85), value: model.layout)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Collage", bundle: .module))
        }
        .overlay(alignment: .bottom) {
            if model.swapping != nil {
                Text("Tap another photo to swap them.", bundle: .module, comment: "Collage editor hint after picking a photo.")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    var controls: some View {
        VStack(spacing: 12) {
            Picker(String(localized: "Layout", bundle: .module, comment: "Collage layout picker."), selection: $model.style) {
                ForEach(CollageStyle.allCases, id: \.self) { style in
                    Text(Self.styleTitle(style)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                TextField(String(localized: "Title", bundle: .module), text: $model.title)
                    .textFieldStyle(.roundedBorder)
                ForEach(CollageTheme.allCases) { theme in
                    Button {
                        withAnimation { model.theme = theme }
                    } label: {
                        Circle()
                            .fill(theme.swatch)
                            .overlay(
                                Circle().strokeBorder(
                                    model.theme == theme ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                    lineWidth: model.theme == theme ? 3 : 1)
                            )
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.title)
                    .accessibilityAddTraits(model.theme == theme ? .isSelected : [])
                    .help(theme.title)
                }
            }
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker(String(localized: "Format", bundle: .module, comment: "Collage format picker."), selection: $model.format) {
                    ForEach(CollageFormat.allCases) { format in
                        Label(format.title, systemImage: format.systemImage).tag(format)
                    }
                }
                Button {
                    withAnimation { model.shuffle() }
                } label: {
                    Label(
                        String(localized: "Shuffle", bundle: .module, comment: "Collage: put the photos in a new order."),
                        systemImage: "shuffle")
                }
                if let swapping = model.swapping, model.items.count > 1 {
                    Button(role: .destructive) {
                        withAnimation { model.remove(swapping) }
                    } label: {
                        Label(
                            String(localized: "Remove Photo", bundle: .module, comment: "Collage: leave the picked photo out."),
                            systemImage: "minus.circle")
                    }
                }
            } label: {
                Label(String(localized: "Options", bundle: .module), systemImage: "ellipsis.circle")
            }
            ShareLink(
                item: export,
                preview: SharePreview(model.title.isEmpty ? String(localized: "Collage", bundle: .module) : model.title)
            ) {
                Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
            }
            Button {
                save()
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        String(localized: "Save to Nextcloud", bundle: .module, comment: "Saves the collage as a new photo."),
                        systemImage: "icloud.and.arrow.up")
                }
            }
            .disabled(saving || model.images.isEmpty)
        }
    }

    /// The image or PDF, rendered with the full-resolution pictures when a share destination asks for it.
    var export: CollageExport {
        let model = model
        let services = session.services
        return CollageExport(
            jpeg: {
                if let services { await model.load(services: services, bucket: 4096) }
                return model.jpegData()
            },
            pdf: {
                if let services { await model.load(services: services, bucket: 4096) }
                return model.pdfData()
            })
    }

    func save() {
        guard let services = session.services else { return }
        saving = true
        Task {
            defer { saving = false }
            await model.load(services: services, bucket: 4096)
            guard let data = model.jpegData() else { return }
            do {
                let path = try await session.saveImageToLibrary(data, fileName: CollageModel.fileName())
                message = String(
                    localized: "Saved to \((path as NSString).deletingLastPathComponent) in your Nextcloud.", bundle: .module,
                    comment: "After saving a collage; the argument is the folder.")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    static func styleTitle(_ style: CollageStyle) -> String {
        switch style {
        case .grid: String(localized: "Grid", bundle: .module, comment: "Collage layout.")
        case .mosaic: String(localized: "Mosaic", bundle: .module, comment: "Collage layout.")
        case .polaroid: String(localized: "Prints", bundle: .module, comment: "Collage layout: instant photo prints.")
        case .magazine: String(localized: "Magazine", bundle: .module, comment: "Collage layout: one large photo and small ones.")
        }
    }
}

extension View {
    /// Presents the collage editor for a request.
    func collageEditor(_ request: Binding<CollageRequest?>) -> some View {
        sheet(item: request) { request in CollageEditor(request: request) }
    }
}
