// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// A video export running or done (SPEC §15.1): progress, cancel, the finished file, and its clean-up. The file lives in
/// its own temporary folder, which is removed when the sheet closes; an upload to Nextcloud gets its own copy.
@MainActor @Observable final class FilmExportJob {
    enum State {
        case ready
        case working(progress: Double, step: String)
        case done(URL)
        case failed(String)
    }

    private(set) var state = State.ready
    private var task: Task<Void, Never>?

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Runs `make` (which reports progress 0…1 with a description of the step) and keeps its file.
    func start(_ make: @escaping @MainActor (_ report: @escaping @MainActor (Double, String) -> Void) async throws -> URL) {
        cancel()
        state = .working(progress: 0, step: FilmExportJob.preparingStep)
        task = Task { [self] in
            do {
                let url = try await make { [weak self] progress, step in
                    guard let self, self.isWorking else { return }
                    self.state = .working(progress: progress, step: step)
                }
                try Task.checkCancellation()
                state = .done(url)
            } catch is CancellationError {
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { state = .ready }
    }

    /// Cancels a running export and removes the finished file's folder.
    func cleanUp() {
        cancel()
        if case .done(let url) = state { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        state = .ready
    }

    /// A copy of the finished video for an upload (the upload removes it when it is done).
    static func uploadCopy(of url: URL) throws -> URL {
        // Outside the export folder (whose leftovers the next export removes); the system empties it in time.
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "MemoryFilmCopies/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    static var preparingStep: String {
        String(localized: "Preparing…", bundle: .module, comment: "Video export: first step, before the photos are loaded.")
    }
    static var photosStep: String {
        String(localized: "Loading photos…", bundle: .module, comment: "Video export: the photos are being loaded.")
    }
    static var renderingStep: String {
        String(localized: "Making the video…", bundle: .module, comment: "Video export: frames are being rendered and encoded.")
    }
}

/// Exports a memory film as a video (SPEC §15.1): 1080p H.264 or HEVC, with the chosen music when it is a file the app
/// can read, then shares it, saves it to Nextcloud or (on the Mac) to a file.
struct MemoryFilmExportSheet: View {
    let start: SlideshowStart
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var job = FilmExportJob()
    @AppStorage("memoryFilmCodec") private var codec = FilmExporter.Codec.h264.rawValue
    @AppStorage(SlideshowMusicStore.key) private var storedMusic = ""

    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Export Video…", bundle: .module, comment: "Memory: makes a video file of the memory's film to share or save."),
            other: LocalizedStringResource(
                "Export video…", bundle: .module, comment: "Memory: makes a video file of the memory's film to share or save."))
    }

    var choice: FilmChoice {
        _ = storedMusic
        return FilmChoiceStore.choice(for: start.id)
    }

    var body: some View {
        FilmExportView(
            title: start.title, job: job, codec: $codec, musicNote: Self.note(choice), fileName: start.title
        ) {
            let codec = FilmExporter.Codec(rawValue: codec) ?? .h264
            let still = reduceMotion
            job.start { report in
                try await Self.export(start, session: session, codec: codec, still: still, report: report)
            }
        }
    }

    /// The style of the video and what happens to the music (SPEC §16.6), said before the export starts.
    static func note(_ choice: FilmChoice) -> String {
        let style = String(
            localized: "Style: \(choice.style.title).", bundle: .module,
            comment: "Video export of a memory: the film style the video is made in. The argument is the style's name.")
        let music: String? =
            switch choice.soundtrack {
            case .style:
                String(
                    localized: "With its own music, made on this device.", bundle: .module,
                    comment: "Video export of a memory: the film style's music goes into the video.")
            case .mine: musicNote(SlideshowMusicStore.current())
            case .none: nil
            }
        return [style, music].compactMap { $0 }.joined(separator: " ")
    }

    /// What the export does with the user's own music, said before it starts.
    static func musicNote(_ music: SlideshowMusic?) -> String? {
        guard let music else { return nil }
        if SlideshowMusicStore.readableURL(for: music) == nil {
            return String(
                localized: "Songs from Apple Music are protected and can't be put into a video. The video will have no music.",
                bundle: .module, comment: "Video export of a memory whose music is an Apple Music song.")
        }
        return String(
            localized: "With your music “\(music.title)”.", bundle: .module,
            comment: "Video export of a memory: the chosen music file goes into the video. The argument is its name.")
    }

    /// Loads everything the film needs at full size and writes the video.
    static func export(
        _ start: SlideshowStart, session: SessionModel, codec: FilmExporter.Codec, still: Bool,
        report: @escaping @MainActor (Double, String) -> Void
    ) async throws -> URL {
        guard let services = session.services else { throw CancellationError() }
        let making = await FilmMaking.prepare(start, services: services, choice: FilmChoiceStore.choice(for: start.id), waitsForScore: true)
        let plan = making.plan
        let size = CGSize(width: 1920, height: 1080)
        var material = FilmMaterial()
        report(0.02, FilmExportJob.photosStep)

        // Pictures (with their focus) and clips, a few at a time.
        let needed = Array(Set(plan.segments.compactMap { plan.shotIndex(of: $0) })).sorted()
        var done = 0
        for chunk in stride(from: 0, to: needed.count, by: 4).map({ Array(needed[$0..<min($0 + 4, needed.count)]) }) {
            try Task.checkCancellation()
            for shot in chunk {
                guard let item = making.items[safe: shot] else { continue }
                let request = ImagePipeline.Request(
                    fileId: item.fileId, etag: item.etag, bucket: 4096, hasPreview: item.hasPreview, mimeType: item.mimeType,
                    originalURL: services.originalURL(for: item), maxPixelSize: 2560)
                if let image = await services.images.preview(request) {
                    material.stills[shot] = image
                    material.focus[shot] = await Task.detached(priority: .userInitiated) { await FrameFocus.focus(of: image) }.value
                }
                let clipItem = plan.shots[shot].isVideo ? item : making.motions[item.fileId]
                if let clipItem, plan.shots[shot].kind != .photo {
                    material.clips[shot] = try? await services.images.originals.original(
                        fileId: clipItem.fileId, etag: clipItem.etag, url: services.originalURL(for: clipItem), maxBytes: 500_000_000)
                }
                done += 1
                report(0.02 + 0.26 * Double(done) / Double(max(needed.count, 1)), FilmExportJob.photosStep)
            }
        }

        // Title, flight captions and maps.
        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()
            switch segment.content {
            case .title:
                material.overlays[index] = render(
                    FilmTitleOverlay(title: start.title, subtitle: start.subtitle, place: start.place, height: size.height), size: size)
            case .flight(let from, let to, let fromName, let toName):
                material.overlays[index] = render(FilmFlightCaption(from: fromName, to: toName, height: size.height), size: size)
                material.maps[index] = await FilmPictures.map(from: from, to: to, size: size)
            case .shot, .card: break
            }
        }
        report(0.3, FilmExportJob.renderingStep)
        let exporter = FilmExporter(
            plan: plan, material: material, size: size, codec: codec, music: making.musicFile, still: still, fileName: start.title)
        return try await exporter.export { progress in
            Task { @MainActor in report(0.3 + 0.7 * progress, FilmExportJob.renderingStep) }
        }
    }

    /// A view as a transparent full-frame picture.
    static func render(_ view: some View, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// The export sheet's content, shared by memory films and the year in review: the format, what happens to the music,
/// progress with Cancel, then Share, Save to Nextcloud and (Mac) Save.
struct FilmExportView: View {
    let title: String
    let job: FilmExportJob
    @Binding var codec: String
    let musicNote: String?
    let fileName: String
    let start: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var savingFile = false
    @State private var fileToSave: URL?
    @State private var uploadedTo: String?

    var body: some View {
        NavigationStack {
            Form {
                switch job.state {
                case .ready:
                    options
                case .working(let progress, let step):
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: progress) {
                                Text(step)
                            } currentValueLabel: {
                                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                case .done(let url):
                    finished(url)
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button(
                            PlatformWording.title(
                                mac: LocalizedStringResource(
                                    "Try Again", bundle: .module, comment: "Video export failed: starts it again."),
                                other: LocalizedStringResource("Try again", bundle: .module))
                        ) { start() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if job.isWorking {
                        Button(String(localized: "Cancel", bundle: .module)) { job.cancel() }
                    } else {
                        Button(String(localized: "Done", bundle: .module)) { dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(job.isWorking)
        .onDisappear { job.cleanUp() }
        .sheet(isPresented: $choosingFolder) {
            ServerFolderPicker(
                confirmTitle: String(
                    localized: "Save Here", bundle: .module, comment: "Folder picker: saves the video into the folder shown.")
            ) { folder in
                saveToNextcloud(folder)
            }
        }
        .fileMover(isPresented: $savingFile, file: fileToSave) { result in
            // Not moved (cancelled): the copy goes.
            if case .failure = result, let fileToSave { try? FileManager.default.removeItem(at: fileToSave.deletingLastPathComponent()) }
            fileToSave = nil
        }
    }

    var options: some View {
        Section {
            Picker(String(localized: "Format", bundle: .module, comment: "Video export: the video codec."), selection: $codec) {
                Text("H.264 (most compatible)", bundle: .module, comment: "Video export format: H.264, plays everywhere.")
                    .tag(FilmExporter.Codec.h264.rawValue)
                Text("HEVC (smaller)", bundle: .module, comment: "Video export format: HEVC, about half the size.")
                    .tag(FilmExporter.Codec.hevc.rawValue)
            }
            Button {
                start()
            } label: {
                Label(String(localized: "Export", bundle: .module, comment: "Video export: starts making the video."), systemImage: "film")
            }
            .keyboardShortcut(.defaultAction)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("1080p video, made on this device.", bundle: .module, comment: "Video export: what the video is.")
                if let musicNote { Text(musicNote) }
            }
        }
    }

    func finished(_ url: URL) -> some View {
        Section {
            Label(
                String(localized: "The video is ready.", bundle: .module, comment: "Video export finished."),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            ShareLink(item: url) {
                Label(String(localized: "Share…", bundle: .module), systemImage: "square.and.arrow.up")
            }
            Button {
                choosingFolder = true
            } label: {
                Label(
                    String(
                        localized: "Save to Nextcloud…", bundle: .module,
                        comment: "Video export: uploads the video to a folder the user picks."),
                    systemImage: "icloud.and.arrow.up")
            }
            #if os(macOS)
                Button {
                    fileToSave = try? FilmExportJob.uploadCopy(of: url)
                    savingFile = fileToSave != nil
                } label: {
                    Label(
                        String(localized: "Save to Mac…", bundle: .module, comment: "Video export: saves the video as a file on the Mac."),
                        systemImage: "arrow.down.doc")
                }
            #endif
        } footer: {
            if let uploadedTo {
                Text(
                    "Uploading to “\(uploadedTo)”. It appears in Transfers until it is done.", bundle: .module,
                    comment: "Video export: the video is being uploaded into this folder.")
            }
        }
    }

    func saveToNextcloud(_ folder: String) {
        guard case .done(let url) = job.state, let copy = try? FilmExportJob.uploadCopy(of: url) else { return }
        session.transfers.upload([UploadSource(file: copy, fileName: url.lastPathComponent, isTemporary: true)], to: folder)
        uploadedTo = folder
    }
}
