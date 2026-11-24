// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI

/// The year in review's data on screen: computed from the index on a database queue, then the photos the cards show.
@MainActor @Observable final class YearInReviewModel {
    let year: Int
    private(set) var content: YearCardContent?
    private(set) var cards: [YearInReview.Card] = []
    /// The year's highlights film.
    private(set) var recap: Memory?
    private(set) var loaded = false
    /// The cards as pictures (PNG files), for sharing; made once the photos are there.
    private(set) var cardFiles: [URL] = []

    init(year: Int) {
        self.year = year
    }

    func load(session: SessionModel) async {
        guard let services = session.services else { return }
        let items = (try? await services.library.yearReviewItems(year: year)) ?? []
        let hidden = session.hiddenPeopleFile.map { HiddenPeople.load(from: $0).names } ?? []
        let review = YearInReview(year: year, items: items, hiddenPeople: hidden)
        recap = try? await services.library.recap(year: year)
        var content = YearCardContent(review: review)
        self.content = content
        cards = review.cards
        loaded = true

        // The photos of the cards, then where the faces are in the people's photos.
        var wanted = Set(review.bestOf)
        wanted.formUnion(review.people.map(\.cover))
        wanted.formUnion(review.pets.map(\.cover))
        for id in [review.busiestDay?.cover, review.firstSnow?.fileId, review.firstBeach?.fileId, review.cover] {
            if let id { wanted.insert(id) }
        }
        let stored = (try? await services.library.fetchItems(Array(wanted))) ?? [:]
        for item in stored.values {
            let request = ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: 1024, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item), maxPixelSize: 1080)
            if let image = await services.images.preview(request) {
                content.images[item.fileId] = image
                self.content = content
            }
        }
        for person in review.people {
            guard let image = content.images[person.cover] else { continue }
            content.focus[person.cover] = await Task.detached(priority: .userInitiated) { await FrameFocus.focus(of: image) }.value
        }
        self.content = content
        cardFiles = renderCardFiles()
    }

    /// Every card as a 1080 × 1920 picture.
    func renderCards() -> [CGImage] {
        guard let content else { return [] }
        return cards.compactMap { card in
            let renderer = ImageRenderer(content: YearCard(card: card, content: content, animated: false))
            renderer.scale = 1080 / YearCard.design.width
            renderer.isOpaque = true
            return renderer.cgImage
        }
    }

    /// The cards as PNG files in a temporary folder of their own (removed when the screen closes).
    private func renderCardFiles() -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "YearInReview/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, image) in renderCards().enumerated() {
            let url = folder.appending(path: "\(year) in review \(index + 1).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { files.append(url) }
        }
        return files
    }

    func cleanUp() {
        if let folder = cardFiles.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        cardFiles = []
    }

    /// The cards as a short portrait video (each card about a picture long, cross-faded, with the memories' music).
    func exportVideo(codec: FilmExporter.Codec, still: Bool, report: @escaping @MainActor (Double, String) -> Void) async throws -> URL {
        report(0.05, FilmExportJob.renderingStep)
        var material = FilmMaterial()
        material.cards = renderCards()
        let music = SlideshowMusicStore.current()
        var musicFile: URL?
        if let music { musicFile = SlideshowMusicStore.readableURL(for: music) }
        var rhythm = FilmRhythm.steady
        if let music, let musicFile { rhythm = await FilmRhythmCache.shared.rhythm(for: music, file: musicFile) ?? .steady }
        let plan = FilmPlan(cards: material.cards.count, rhythm: rhythm)
        let exporter = FilmExporter(
            plan: plan, material: material, size: CGSize(width: 1080, height: 1920), codec: codec, music: musicFile, still: still,
            fileName: String(localized: "\(String(year)) in review", bundle: .module, comment: "Year in review title, e.g. 2025 in review: the screen title, the heading of every card and the video file name."))
        return try await exporter.export { progress in
            Task { @MainActor in report(0.1 + 0.9 * progress, FilmExportJob.renderingStep) }
        }
    }
}

/// The year in review (SPEC §15.1): swipeable cards with the year's numbers, shareable as pictures or as a short video,
/// and the year's highlights film.
struct YearInReviewScreen: View {
    let year: Int
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: YearInReviewModel
    @State private var page: YearInReview.Card?
    @State private var slideshow: SlideshowStart?
    @State private var exporting = false

    init(year: Int) {
        self.year = year
        _model = State(initialValue: YearInReviewModel(year: year))
    }

    static func title(_ year: Int) -> String {
        String(localized: "\(String(year)) in review", bundle: .module, comment: "Year in review title, e.g. 2025 in review: the screen title, the heading of every card and the video file name.")
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1.4, max(0.4, min((proxy.size.height - 60) / YearCard.design.height, (proxy.size.width - 32) / YearCard.design.width)))
            VStack(spacing: 14) {
                if let content = model.content {
                    cardPages(content, scale: scale, width: proxy.size.width)
                    pageDots
                } else if model.loaded {
                    ContentUnavailableView(String(localized: "No photos to show", bundle: .module), systemImage: "calendar")
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .navigationTitle(Self.title(year))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar { toolbar }
        .memorySlideshow($slideshow)
        .sheet(isPresented: $exporting) {
            YearInReviewExportSheet(model: model)
        }
        .task {
            await model.load(session: session)
            if page == nil { page = model.cards.first }
        }
        .onDisappear { model.cleanUp() }
    }

    func cardPages(_ content: YearCardContent, scale: CGFloat, width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.cards, id: \.self) { (card: YearInReview.Card) in
                    YearCard(card: card, content: content, animated: page == card)
                        .scaleEffect(scale)
                        .frame(width: YearCard.design.width * scale, height: YearCard.design.height * scale)
                        .clipShape(.rect(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(YearCard(card: card, content: content).accessibilityText)
                        .frame(width: width)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(press.key == .rightArrow ? 1 : -1)
            return .handled
        }
    }

    var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(model.cards, id: \.self) { (card: YearInReview.Card) in
                Circle().fill(.white.opacity(card == page ? 1 : 0.35)).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AccessibilityText.position(index: model.cards.firstIndex(where: { $0 == page }) ?? 0, count: model.cards.count))
    }

    func step(_ delta: Int) {
        guard let index = model.cards.firstIndex(where: { $0 == page }) else { return }
        let next = min(max(0, index + delta), model.cards.count - 1)
        withAnimation(reduceMotion ? nil : .smooth) { page = model.cards[next] }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let recap = model.recap {
                Button {
                    slideshow = SlideshowStart(memory: recap)
                } label: {
                    Label(Self.playTitle, systemImage: "play.rectangle")
                }
                .help(Self.playTitle)
            }
            Menu {
                if !model.cardFiles.isEmpty {
                    ShareLink(items: model.cardFiles) {
                        Label(Self.shareImagesTitle, systemImage: "photo.on.rectangle")
                    }
                }
                Button {
                    exporting = true
                } label: {
                    Label(MemoryFilmExportSheet.menuTitle, systemImage: "film")
                }
            } label: {
                Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
            }
            .disabled(model.content == nil)
        }
    }

    static var playTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Play Film", bundle: .module, comment: "Year in review: plays the year's highlights as a memory film."),
            other: LocalizedStringResource("Play film", bundle: .module, comment: "Year in review: plays the year's highlights as a memory film."))
    }

    static var shareImagesTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Share Cards as Images…", bundle: .module, comment: "Year in review: shares the cards as pictures."),
            other: LocalizedStringResource(
                "Share cards as images…", bundle: .module, comment: "Year in review: shares the cards as pictures."))
    }
}

/// The year in review as a short portrait video.
struct YearInReviewExportSheet: View {
    let model: YearInReviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var job = FilmExportJob()
    @AppStorage("memoryFilmCodec") private var codec = FilmExporter.Codec.h264.rawValue
    @AppStorage(SlideshowMusicStore.key) private var storedMusic = ""

    var body: some View {
        FilmExportView(
            title: YearInReviewScreen.title(model.year), job: job, codec: $codec,
            musicNote: MemoryFilmExportSheet.musicNote(SlideshowMusic(stored: storedMusic)), fileName: YearInReviewScreen.title(model.year)
        ) {
            let codec = FilmExporter.Codec(rawValue: codec) ?? .h264
            let still = reduceMotion
            let model = model
            job.start { report in try await model.exportVideo(codec: codec, still: still, report: report) }
        }
    }
}

/// A year's card in the Memories screen and the library's strip: the year big, in Nextcloud colours.
struct YearInReviewCard: View {
    let year: Int
    var compact = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(red: 0, green: 0.36, blue: 0.62), Color(red: 0.36, green: 0.18, blue: 0.75)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Image(systemName: "sparkles").font(.system(size: compact ? 40 : 70)).foregroundStyle(.white.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(compact ? 8 : 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(year)).font(.system(size: compact ? 30 : 52, weight: .heavy, design: .rounded))
                Text("Year in review", bundle: .module, comment: "Under the year on the card that opens the year in review.")
                    .font(compact ? .caption2.bold() : .subheadline.bold())
            }
            .foregroundStyle(.white)
            .padding(compact ? 8 : 14)
        }
        .clipShape(.rect(cornerRadius: compact ? 12 : 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(YearInReviewScreen.title(year))
        .accessibilityAddTraits(.isButton)
    }
}
