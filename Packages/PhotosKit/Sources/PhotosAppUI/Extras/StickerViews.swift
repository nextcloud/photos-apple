// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if os(iOS)
    // Swift 5 module without concurrency annotations: `ImageAnalysis` is made by the analyzer and then only used on the main
    // actor.
    @preconcurrency import VisionKit
#endif

/// A sticker for the share sheet: a transparent PNG.
struct StickerTransfer: Transferable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName(String(localized: "Sticker", bundle: .module, comment: "File name of a shared sticker.") + ".png")
    }
}

enum StickerWording {
    static func styleTitle(_ style: StickerStyle) -> String {
        switch style {
        case .original: String(localized: "Cut-out", bundle: .module, comment: "Sticker style: only the subject.")
        case .outline: String(localized: "Outline", bundle: .module, comment: "Sticker style: white border.")
        case .shadow: String(localized: "Shadow", bundle: .module, comment: "Sticker style: soft drop shadow.")
        case .comic: String(localized: "Comic", bundle: .module, comment: "Sticker style: drawn like a comic.")
        }
    }

    static func failure(_ error: any Error) -> String {
        switch error as? StickerMaker.Failure {
        case .noSubject?:
            String(
                localized: "No person, pet or object stands out in this photo.", bundle: .module,
                comment: "Make Sticker found nothing to cut out.")
        case .unavailable?:
            String(
                localized: "Stickers aren't available here: subjects can't be lifted from photos on this system.", bundle: .module,
                comment: "Make Sticker: subject lifting is not available (e.g. in the simulator).")
        case nil:
            error.localizedDescription
        }
    }

    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Make Sticker…", bundle: .module, comment: "Viewer menu item on the Mac."),
            other: LocalizedStringResource("Make sticker", bundle: .module, comment: "Viewer menu item on iPhone, iPad and Vision Pro."))
    }

    static var packTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Make Sticker Pack…", bundle: .module, comment: "Person menu item on the Mac."),
            other: LocalizedStringResource(
                "Make sticker pack", bundle: .module, comment: "Person menu item on iPhone, iPad and Vision Pro."))
    }
}

/// Copies a sticker to the pasteboard as a transparent PNG.
enum StickerPasteboard {
    @MainActor static func copy(_ png: Data) {
        #if canImport(UIKit)
            UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        #endif
    }
}

/// A lifted subject and the styles made from it.
@MainActor @Observable final class StickerModel {
    enum Phase: Equatable {
        case lifting
        case ready
        case failed(String)
    }

    var phase: Phase = .lifting
    var style: StickerStyle = .outline
    /// The styled stickers, made one after the other once the subject is lifted.
    var styled: [StickerStyle: CGImage] = [:]
    var saved = false

    var current: CGImage? { styled[style] }
    var png: Data? { current.flatMap(StickerMaker.pngData) }

    func make(from item: MediaItem, services: AccountServices, face: CGRect? = nil) async {
        phase = .lifting
        // The largest preview there is; the original's resolution adds nothing to a sticker.
        var image = await services.images.preview(ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 4096))
        if image == nil {
            image = await services.images.preview(ImagePipeline.Request(fileId: item.fileId, etag: item.etag, bucket: 1024))
        }
        guard let image else {
            phase = .failed(String(localized: "The photo could not be loaded.", bundle: .module))
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[StickerStyle: CGImage], StickerMaker.Failure> in
            do {
                let cutout = try StickerMaker.lift(image, face: face)
                var styled: [StickerStyle: CGImage] = [:]
                for style in StickerStyle.allCases { styled[style] = StickerMaker.styled(cutout, style: style) }
                return .success(styled)
            } catch let failure as StickerMaker.Failure {
                return .failure(failure)
            } catch {
                return .failure(.noSubject)
            }
        }.value
        switch result {
        case .success(let styled):
            self.styled = styled
            phase = .ready
        case .failure(let failure):
            phase = .failed(StickerWording.failure(failure))
        }
    }
}

/// "Make Sticker" (SPEC §15.8.2): lifts the person, pet or object of a photo, offers the styles, and shares, copies or keeps
/// the sticker in the sticker book. On iPhone and iPad, touching and holding the sticker shows the system's menu with
/// "Add Sticker" (VisionKit).
struct StickerSheet: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = StickerModel()
    @State private var appeared = false
    @State private var copied = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.phase == .ready {
                    stylePicker
                    actions
                    systemStickerHint
                }
            }
            .padding()
            .navigationTitle(String(localized: "Sticker", bundle: .module, comment: "Title of the Make Sticker sheet."))
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 600)
        #endif
        .photosHaptic(.success, trigger: model.phase == .ready)
        .photosHaptic(.impact(weight: .light), trigger: copied)
        .task {
            guard let services = session.services else { return }
            await model.make(from: item, services: services)
            withAnimation(reduceMotion ? .default : .spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
        }
    }

    @ViewBuilder var stage: some View {
        switch model.phase {
        case .lifting:
            ZStack {
                PreviewImage(item: item, bucket: 1024, contentMode: .fit)
                    .opacity(0.35)
                    .blur(radius: reduceMotion ? 0 : 6)
                ProgressView(String(localized: "Lifting the subject…", bundle: .module, comment: "While Make Sticker works."))
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "No sticker", bundle: .module, comment: "Make Sticker failed."), systemImage: "face.dashed")
            } description: {
                Text(message)
            }
        case .ready:
            if let image = model.current {
                StickerImageView(image: image)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .rotationEffect(.degrees(appeared ? 0 : -8))
                    .shadow(color: .black.opacity(0.15), radius: appeared ? 12 : 0, y: appeared ? 6 : 0)
                    .accessibilityLabel(Text("Sticker", bundle: .module))
                    .accessibilityAddTraits(.isImage)
            }
        }
    }

    var stylePicker: some View {
        HStack(spacing: 12) {
            ForEach(StickerStyle.allCases, id: \.self) { style in
                Button {
                    withAnimation(.snappy) { model.style = style }
                } label: {
                    VStack(spacing: 6) {
                        if let image = model.styled[style] {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 56, height: 56)
                        }
                        Text(StickerWording.styleTitle(style)).font(.caption)
                    }
                    .padding(8)
                    .background(
                        model.style == style ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.style == style ? .isSelected : [])
            }
        }
    }

    /// With titles where they fit (iPad, Mac), as icons on a narrow iPhone.
    var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionButtons.labelStyle(.titleAndIcon)
            actionButtons.labelStyle(.iconOnly)
        }
    }

    var actionButtons: some View {
        HStack(spacing: 12) {
            if let png = model.png, let image = model.current {
                ShareLink(
                    item: StickerTransfer(png: png),
                    preview: SharePreview(String(localized: "Sticker", bundle: .module), image: Image(decorative: image, scale: 1))
                ) {
                    Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                }
                Button {
                    StickerPasteboard.copy(png)
                    copied += 1
                } label: {
                    Label(String(localized: "Copy", bundle: .module), systemImage: "doc.on.doc")
                }
                Button {
                    save(png, image: image)
                } label: {
                    Label(
                        model.saved
                            ? String(localized: "In Sticker Book", bundle: .module, comment: "The sticker was added to the sticker book.")
                            : String(
                                localized: "Add to Sticker Book", bundle: .module, comment: "Keeps the sticker in the app's sticker book."),
                        systemImage: model.saved ? "checkmark" : "book.closed")
                }
                .disabled(model.saved)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    /// Under the actions on iPhone and iPad: the system's menu on the sticker has "Add Sticker".
    @ViewBuilder var systemStickerHint: some View {
        #if os(iOS)
            Text(
                "Touch and hold the sticker to add it to your stickers.", bundle: .module,
                comment: "Hint under the sticker on iPhone and iPad: the system menu offers Add Sticker."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        #endif
    }

    func save(_ png: Data, image: CGImage) {
        guard let book = session.stickerBook else { return }
        if (try? book.add(
            png: png, width: image.width, height: image.height, source: item.fileId, pack: nil, style: model.style.rawValue)) != nil
        {
            withAnimation { model.saved = true }
        }
    }
}

/// A sticker image. On iPhone and iPad it carries VisionKit's subject interaction, whose menu has the system's
/// "Add Sticker" (and Copy and Share); elsewhere it is a plain image.
struct StickerImageView: View {
    let image: CGImage

    var body: some View {
        #if os(iOS)
            SubjectInteractionImage(image: image)
        #else
            Image(decorative: image, scale: 1).resizable().scaledToFit()
        #endif
    }
}

#if os(iOS)
    /// A `UIImageView` with an `ImageAnalysisInteraction` for subjects only (no text, no Look Up): touch and hold shows the
    /// system's menu for the sticker, which includes "Add Sticker".
    struct SubjectInteractionImage: UIViewRepresentable {
        let image: CGImage

        func makeUIView(context: Context) -> UIImageView {
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.isUserInteractionEnabled = true
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = [.imageSubject]
            view.addInteraction(interaction)
            context.coordinator.interaction = interaction
            return view
        }

        func updateUIView(_ view: UIImageView, context: Context) {
            guard context.coordinator.shown !== image else { return }
            context.coordinator.shown = image
            view.image = UIImage(cgImage: image)
            context.coordinator.analyze(image)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor final class Coordinator {
            var interaction: ImageAnalysisInteraction?
            var shown: CGImage?
            private var task: Task<Void, Never>?

            func analyze(_ image: CGImage) {
                guard ImageAnalyzer.isSupported else { return }
                task?.cancel()
                task = Task { [weak self] in
                    let analyzer = ImageAnalyzer()
                    let configuration = ImageAnalyzer.Configuration([.visualLookUp])
                    let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
                    guard !Task.isCancelled else { return }
                    self?.interaction?.analysis = analysis
                    self?.interaction?.preferredInteractionTypes = [.imageSubject]
                }
            }
        }
    }
#endif

/// The sticker book (SPEC §15.8.2): every sticker made in the app, people's packs first.
struct StickerBookScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var selected: Sticker?

    var book: StickerBook? { session.stickerBook }

    var body: some View {
        Group {
            if let book, !book.stickers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(book.packs, id: \.self) { pack in
                            section(title: pack, stickers: book.stickers.filter { $0.pack == pack }, book: book)
                        }
                        let single = book.stickers.filter { $0.pack == nil }
                        if !single.isEmpty {
                            section(
                                title: book.packs.isEmpty
                                    ? nil
                                    : String(localized: "More stickers", bundle: .module, comment: "Stickers that are not in a pack."),
                                stickers: single, book: book)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Stickers", bundle: .module), systemImage: "face.smiling")
                } description: {
                    Text(
                        "Open a photo of a person or pet and choose Make Sticker in its More menu, or make a sticker pack of a person in People.",
                        bundle: .module, comment: "Empty sticker book.")
                }
            }
        }
        .navigationTitle(String(localized: "Stickers", bundle: .module))
        .task { book?.load() }
    }

    func section(title: String?, stickers: [Sticker], book: StickerBook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.title3.bold()) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)], spacing: 16) {
                ForEach(stickers) { sticker in
                    StickerCell(sticker: sticker, url: book.url(of: sticker))
                        .contextMenu { menu(sticker, book: book) }
                }
            }
        }
    }

    @ViewBuilder func menu(_ sticker: Sticker, book: StickerBook) -> some View {
        if let png = try? Data(contentsOf: book.url(of: sticker)) {
            ShareLink(item: StickerTransfer(png: png), preview: SharePreview(String(localized: "Sticker", bundle: .module))) {
                Label(String(localized: "Share…", bundle: .module), systemImage: "square.and.arrow.up")
            }
            Button {
                StickerPasteboard.copy(png)
            } label: {
                Label(String(localized: "Copy", bundle: .module), systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            withAnimation { book.remove([sticker.id]) }
        } label: {
            Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
        }
    }
}

/// One sticker of the book: the PNG, decoded small.
struct StickerCell: View {
    let sticker: Sticker
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                StickerImageView(image: image)
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(sticker.pack.map { Text("Sticker of \($0)", bundle: .module) } ?? Text("Sticker", bundle: .module))
        .accessibilityAddTraits(.isImage)
        .task(id: sticker.id) {
            let url = url
            image = await Task.detached(priority: .userInitiated) { ImageDecoding.decode(url: url, maxPixelSize: 400) }.value
        }
    }
}

/// "Make Sticker Pack" of a person (SPEC §15.8.2): stickers of the person from several photos, cut out around their face,
/// appearing one by one; they go into the sticker book under the person's name.
struct StickerPackSheet: View {
    let person: String
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var made: [CGImage] = []
    @State private var total = 0
    @State private var done = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !done {
                        ProgressView(
                            value: Double(made.count), total: Double(max(total, 1)),
                            label: { Text("Making stickers of \(person)…", bundle: .module, comment: "Progress of a sticker pack.") },
                            currentValueLabel: { total > 0 ? Text("\(made.count) of \(total)", bundle: .module) : Text("") })
                    }
                    if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 16) {
                        ForEach(made.indices, id: \.self) { index in
                            Image(decorative: made[index], scale: 1).resizable().scaledToFit()
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                                .accessibilityLabel(Text("Sticker of \(person)", bundle: .module))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(person)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
        #endif
        .task { await make() }
    }

    func make() async {
        guard let services = session.services, let book = session.stickerBook else { return }
        let photos: [(item: MediaItem, face: CGRect)]
        do {
            photos = try await session.stickerPackPhotos(person: person)
        } catch {
            message = error.localizedDescription
            done = true
            return
        }
        total = photos.count
        for (item, face) in photos {
            guard !Task.isCancelled else { return }
            let model = StickerModel()
            await model.make(from: item, services: services, face: face)
            guard let image = model.styled[.outline], let png = StickerMaker.pngData(image) else { continue }
            try? book.add(
                png: png, width: image.width, height: image.height, source: item.fileId, pack: person, style: StickerStyle.outline.rawValue)
            withAnimation(reduceMotion ? .default : .spring(response: 0.45, dampingFraction: 0.65)) { made.append(image) }
        }
        done = true
        if made.isEmpty {
            message = String(
                localized: "No photo of \(person) gave a good sticker. Stickers need a photo where the face is large enough.",
                bundle: .module, comment: "A sticker pack of a person came out empty.")
        } else {
            message = String(
                localized: "The stickers are in your sticker book.", bundle: .module, comment: "After making a sticker pack.")
        }
    }
}
