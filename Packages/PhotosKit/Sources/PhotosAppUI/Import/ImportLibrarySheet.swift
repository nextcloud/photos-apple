// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// "Import Library…": brings the photos of other services home to Nextcloud (SPEC §15.7). Choose the exports (Google
/// Takeout, Apple's data export, Facebook, Instagram, on the Mac also the Photos library), see what they hold, import
/// with progress, and end with the "Welcome home" summary.
struct ImportLibrarySheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false

    var controller: ImportController { ImportController.controller(for: session) }

    static let allowedTypes: [UTType] = [.folder, .zip, .json, .commaSeparatedText, .image, .movie]

    /// Debug builds: `PHOTOS_DEBUG_IMPORT=<folder or ZIP>` opens the import at launch and reads it (screenshots, UI
    /// tests); `PHOTOS_DEBUG_IMPORT_DESTINATION` sets the server folder, `PHOTOS_DEBUG_IMPORT_START=1` starts at once.
    static var debugExport: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_IMPORT"], !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        #endif
        return nil
    }

    @State private var debugStarted = false

    /// Reads (and starts) the debug export once.
    func runDebugImport() {
        #if DEBUG
            guard !debugStarted, let url = Self.debugExport, controller.stage == .choose else { return }
            debugStarted = true
            let environment = ProcessInfo.processInfo.environment
            controller.read([url], session: session)
            Task {
                while controller.stage == .reading { try? await Task.sleep(for: .milliseconds(200)) }
                if let destination = environment["PHOTOS_DEBUG_IMPORT_DESTINATION"] { controller.options.destination = destination }
                if environment["PHOTOS_DEBUG_IMPORT_START"] == "1", controller.stage == .ready { controller.start(session: session) }
            }
        #endif
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .fileImporter(isPresented: $choosing, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result, !urls.isEmpty else { return }
                    controller.read(urls, session: session)
                }
                .onAppear { runDebugImport() }
        }
        #if os(macOS)
            .frame(minWidth: 600, idealWidth: 660, minHeight: 600, idealHeight: 700)
        #endif
    }

    var title: String {
        switch controller.stage {
        case .finished where controller.progress.phase == .finished: ""
        default: String(localized: "Import Library", bundle: .module, comment: "Title of the import window or sheet.")
        }
    }

    @ViewBuilder var content: some View {
        switch controller.stage {
        case .choose: ImportChooseView(choosing: $choosing)
        case .reading: ImportReadingView(status: controller.readingStatus) { controller.cancel() }
        case .ready: ImportReviewForm()
        case .running: ImportRunningView()
        case .finished:
            if controller.progress.phase == .finished, let summary = controller.summary {
                WelcomeHomeView(summary: summary, previews: controller.previews, reportURL: controller.reportURL) {
                    controller.reset()
                    dismiss()
                }
            } else {
                ImportRunningView()
            }
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch controller.stage {
            case .running:
                Button(String(localized: "Stop Import", bundle: .module, comment: "Import: stops the running import (it can be resumed)."))
                {
                    controller.cancel()
                }
            case .finished where controller.progress.phase == .finished:
                EmptyView()
            default:
                Button(String(localized: "Close", bundle: .module)) {
                    if controller.stage == .finished || controller.stage == .ready { controller.reset() }
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            switch controller.stage {
            case .ready:
                let title: String =
                    controller.alreadyDone > 0
                    ? String(localized: "Resume Import", bundle: .module) : String(localized: "Import", bundle: .module)
                Button(title) { controller.start(session: session) }
                    .disabled(controller.options.destination.isEmpty || !controller.options.destination.hasPrefix("/"))
            case .running:
                // The import goes on without the sheet.
                Button(String(localized: "Hide", bundle: .module)) { dismiss() }
            case .finished where controller.progress.phase != .finished:
                Button(String(localized: "Resume Import", bundle: .module)) { controller.start(session: session) }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: Choose

/// Where to get each export, and the button that picks the files.
struct ImportChooseView: View {
    @Environment(SessionModel.self) private var session
    @Binding var choosing: Bool
    @State private var libraryDenied = false

    var controller: ImportController { ImportController.controller(for: session) }

    struct Guide: Identifiable {
        var source: ImportSourceKind
        var symbol: String
        var steps: String
        var link: URL
        var id: ImportSourceKind { source }
    }

    static var guides: [Guide] {
        [
            Guide(
                source: .googlePhotos, symbol: "photo.stack",
                steps: String(
                    localized: "On takeout.google.com, choose only Google Photos and create the export. Download all of its ZIP files.",
                    bundle: .module, comment: "Import: how to get the Google Photos export."),
                link: URL(string: "https://takeout.google.com/")!),
            Guide(
                source: .iCloudPhotos, symbol: "icloud",
                steps: String(
                    localized: "On privacy.apple.com, choose “Request a copy of your data”, then iCloud Photos. Download every part.",
                    bundle: .module, comment: "Import: how to get Apple's iCloud Photos data export."),
                link: URL(string: "https://privacy.apple.com/")!),
            Guide(
                source: .facebook, symbol: "person.2",
                steps: String(
                    localized: "In Facebook's Accounts Center, choose “Download your information”, the format JSON and high media quality.",
                    bundle: .module, comment: "Import: how to get the Facebook export. Keep “JSON” untranslated."),
                link: URL(string: "https://accountscenter.facebook.com/info_and_permissions/dyi")!),
            Guide(
                source: .instagram, symbol: "camera",
                steps: String(
                    localized:
                        "In Instagram's Accounts Center, choose “Download your information”, the format JSON and high media quality.",
                    bundle: .module, comment: "Import: how to get the Instagram export. Keep “JSON” untranslated."),
                link: URL(string: "https://accountscenter.instagram.com/info_and_permissions/dyi/")!),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if let record = controller.resumable {
                    resumeCard(record)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(Self.guides) { guide in GuideCard(guide: guide) }
                }
                #if os(macOS)
                    libraryCard
                #endif
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        // The one thing to do here stays in reach while the guides scroll.
        .safeAreaInset(edge: .bottom) {
            chooseButton
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    var chooseButton: some View {
        VStack(spacing: 8) {
            Button {
                choosing = true
            } label: {
                Label(
                    String(localized: "Choose Export Files…", bundle: .module, comment: "Import: the button that opens the file picker."),
                    systemImage: "folder"
                )
                .frame(maxWidth: 360)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(
                "Choose the ZIP files as they are, or the folder they were unpacked into. You can choose exports of several services at once.",
                bundle: .module, comment: "Import: below the file picker button."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "house.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Bring everything home", bundle: .module, comment: "Import: headline of the start screen.")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(
                "Move your photos and videos from other services to your Nextcloud, with their dates, places, captions, favourites and albums. Nothing is uploaded twice.",
                bundle: .module, comment: "Import: introduction on the start screen."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    func resumeCard(_ record: ImportSessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "An import of \(record.total) photos and videos did not finish. It continues where it stopped.", bundle: .module,
                    comment: "Import: an earlier import can be resumed. The value is a number.")
                if !record.names.isEmpty {
                    Text(record.names.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    Button(String(localized: "Resume Import", bundle: .module)) { controller.resume(record, session: session) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Forget It", bundle: .module, comment: "Import: drops the unfinished import.")) {
                        controller.forgetResumable(session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(
                String(localized: "Unfinished import", bundle: .module, comment: "Import: title of the resume card."),
                systemImage: "clock.arrow.circlepath")
        }
    }

    #if os(macOS)
        var libraryCard: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Imports every photo and video of the Photos app on this Mac, originals kept in iCloud included, with favourites and albums.",
                        bundle: .module, comment: "Import (Mac): what importing the Photos library does."
                    )
                    .foregroundStyle(.secondary)
                    Button(String(localized: "Import Photos Library", bundle: .module, comment: "Import (Mac): reads the Photos library."))
                    {
                        Task {
                            let status = await PhotoLibrarySource.requestAuthorization()
                            guard status == .authorized || status == .limited else {
                                libraryDenied = true
                                return
                            }
                            controller.includePhotosLibrary = true
                            controller.read([], session: session)
                        }
                    }
                    if libraryDenied {
                        Text(
                            "Nextcloud Photos may not read your Photos library. Allow it in System Settings › Privacy & Security › Photos.",
                            bundle: .module, comment: "Import (Mac): the Photos library permission was denied."
                        )
                        .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(ImportSummary.title(of: .photosLibrary), systemImage: "photo.on.rectangle.angled")
            }
        }
    #endif
}

/// How to get one service's export.
struct GuideCard: View {
    let guide: ImportChooseView.Guide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ImportSummary.title(of: guide.source), systemImage: guide.symbol)
                .font(.headline)
            Text(guide.steps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Link(destination: guide.link) {
                Label(guide.link.host() ?? "", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct ImportReadingView: View {
    let status: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
            Button(String(localized: "Cancel", bundle: .module), action: cancel)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Review

/// What the exports hold, and how they are imported.
struct ImportReviewForm: View {
    @Environment(SessionModel.self) private var session

    var controller: ImportController { ImportController.controller(for: session) }

    var body: some View {
        @Bindable var controller = controller
        Form {
            if let plan = controller.plan {
                foundSection(plan)
                if !plan.skipped.isEmpty { skippedSection(plan) }
            }
            optionsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder func foundSection(_ plan: ImportPlan) -> some View {
        Section {
            ForEach(plan.sources, id: \.source) { entry in
                LabeledContent {
                    Text(entry.count.formatted()).monospacedDigit()
                } label: {
                    Label(ImportSummary.title(of: entry.source), systemImage: ImportSourceStyle.symbol(entry.source))
                }
            }
            LabeledContent(
                String(localized: "Photos and videos", bundle: .module),
                value: "\(plan.items.count.formatted()) · \(Formatters.bytes(Int64(plan.totalBytes)))")
            if !plan.albums.isEmpty {
                LabeledContent(String(localized: "Albums", bundle: .module), value: plan.albums.count.formatted())
            }
            if let years = plan.years {
                LabeledContent(
                    String(localized: "Years", bundle: .module, comment: "Import: the years the photos span."),
                    value: years.lowerBound == years.upperBound ? String(years.lowerBound) : "\(years.lowerBound)–\(years.upperBound)")
            }
        } header: {
            Text("Found", bundle: .module, comment: "Import: heading of what the chosen exports hold.")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if plan.duplicatesInExport + plan.duplicatesAcrossSources > 0 {
                    Text(
                        "\(plan.duplicatesInExport + plan.duplicatesAcrossSources) copies of the same photo in album folders or in several exports are imported once.",
                        bundle: .module, comment: "Import: copies inside the exports.")
                }
                if plan.withoutDetails > 0 {
                    Text(
                        "\(plan.withoutDetails) items have no details in the export; they keep the date in their own metadata.",
                        bundle: .module, comment: "Import: items without a sidecar or index entry.")
                }
                if controller.alreadyDone > 0 {
                    Text(
                        "An earlier import of these files got through \(controller.alreadyDone) of \(plan.items.count) items. It continues where it stopped.",
                        bundle: .module, comment: "Import: resuming. The values are numbers.")
                }
                Text(
                    "Photos already on your Nextcloud are found and not uploaded again.", bundle: .module,
                    comment: "Import: duplicates on the server are skipped.")
            }
        }
    }

    @ViewBuilder func skippedSection(_ plan: ImportPlan) -> some View {
        Section {
            ForEach(plan.skipped.keys.sorted(), id: \.self) { reason in
                DisclosureGroup {
                    ForEach(plan.skippedExamples[reason] ?? [], id: \.self) { name in
                        Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } label: {
                    SkipReasonLabel(reason: reason, count: plan.skipped[reason] ?? 0)
                }
            }
        } header: {
            Text("Left out", bundle: .module, comment: "Import: heading of what is not imported.")
        }
    }

    @ViewBuilder var optionsSection: some View {
        @Bindable var controller = controller
        Section {
            TextField(String(localized: "Upload to", bundle: .module), text: $controller.options.destination)
                .autocorrectionDisabled()
            if !controller.destinationIsInTimeline(session) {
                Label {
                    Text(
                        "This folder is not one of your timeline folders: the imported photos would not show in your library. Choose a folder inside \(session.features.userConfig.photosSourceFolders.joined(separator: ", ")).",
                        bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            Toggle(
                String(
                    localized: "A folder per service", bundle: .module, comment: "Import option: Google Photos, iCloud Photos… folders."),
                isOn: $controller.options.folderPerSource)
            Toggle(String(localized: "Sort into a folder per year", bundle: .module), isOn: $controller.options.yearSubfolders)
            Toggle(String(localized: "Create albums", bundle: .module), isOn: $controller.options.createAlbums)
            Toggle(
                String(localized: "Keep favourites", bundle: .module, comment: "Import option: favourites become Nextcloud favourites."),
                isOn: $controller.options.favorites)
            if session.features.has(.comments) {
                Toggle(String(localized: "Keep captions as comments", bundle: .module), isOn: $controller.options.captionsAsComments)
            }
            Toggle(
                String(
                    localized: "Give photos back their date and place", bundle: .module,
                    comment: "Import option: write the capture date, location and caption of the export into photos that lack them."),
                isOn: $controller.options.addMissingMetadata)
            Toggle(
                String(localized: "Put hidden photos into the archive", bundle: .module, comment: "Import option."),
                isOn: $controller.options.hiddenToArchive)
        } header: {
            Text("Import", bundle: .module)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Facebook and Instagram remove the date and place from their copies; the import writes them back from the export. Other photos stay exactly as they are.",
                    bundle: .module, comment: "Import: explains the date and place option.")
                if !session.features.has(.metadataEdit) {
                    Text(
                        "Places from the exports can only be added to videos and other files without a location of their own on Nextcloud 35 or later.",
                        bundle: .module, comment: "Import: location limitation on older servers.")
                }
            }
        }
    }
}

enum ImportSourceStyle {
    static func symbol(_ source: ImportSourceKind) -> String {
        switch source {
        case .googlePhotos: "photo.stack"
        case .iCloudPhotos: "icloud"
        case .facebook: "person.2"
        case .instagram: "camera"
        case .photosLibrary: "photo.on.rectangle.angled"
        case .files: "folder"
        }
    }
}

// MARK: Running

/// The import at work: the photo being imported, the progress, what happened so far.
struct ImportRunningView: View {
    @Environment(SessionModel.self) private var session

    var controller: ImportController { ImportController.controller(for: session) }

    var body: some View {
        let progress = controller.progress
        ScrollView {
            VStack(spacing: 20) {
                PreviewStack(previews: Array(controller.previews.suffix(3)))
                    .frame(height: 200)
                    .padding(.top, 12)
                VStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 420)
                    Text(statusTitle(progress))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if progress.isRunning {
                        Text(controller.statusLine).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            .contentTransition(.numericText())
                        if let name = progress.currentName {
                            Text(name).font(.footnote).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row(String(localized: "Uploaded", bundle: .module), progress.uploaded)
                    row(String(localized: "Already on your server", bundle: .module), progress.duplicates)
                    if progress.failed > 0 { row(String(localized: "Could not be uploaded", bundle: .module), progress.failed) }
                    if progress.bytesTotal > 0 {
                        GridRow {
                            Text("Data", bundle: .module, comment: "Import progress: amount of data handled so far.").foregroundStyle(
                                .secondary)
                            Text("\(Formatters.bytes(Int64(progress.bytesDone))) / \(Formatters.bytes(Int64(progress.bytesTotal)))")
                                .monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                if progress.isRunning {
                    Text(backgroundNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !progress.failures.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.failures, id: \.self) { Text($0).font(.footnote) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Problems", bundle: .module)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    var backgroundNote: String {
        #if os(macOS)
            String(
                localized: "You can close this window; the import goes on while the app is open.", bundle: .module)
        #else
            String(
                localized:
                    "You can leave the app: the import goes on and shows its progress. If it is stopped, it continues where it stopped.",
                bundle: .module, comment: "Import (iPhone, iPad): the import runs in the background.")
        #endif
    }

    func row(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit().contentTransition(.numericText(value: Double(value)))
        }
    }

    func statusTitle(_ progress: ImportProgress) -> String {
        switch progress.phase {
        case .importing:
            String(localized: "Bringing your photos home…", bundle: .module, comment: "Import: title while the import runs.")
        case .albums: String(localized: "Creating albums…", bundle: .module)
        case .finished:
            progress.failed > 0
                ? String(localized: "Import finished with problems", bundle: .module)
                : String(localized: "Import finished", bundle: .module)
        case .cancelled: String(localized: "Import stopped. It continues where it stopped when you resume it.", bundle: .module)
        case .stopped(let reason): String(localized: "Import stopped: \(reason)", bundle: .module)
        }
    }
}

/// The last photos imported, stacked like prints: the newest one slides on top.
struct PreviewStack: View {
    let previews: [Data]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if previews.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 180, height: 180)
                    .overlay { Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary) }
            }
            ForEach(Array(previews.enumerated()), id: \.element) { offset, data in
                PreviewTile(data: data)
                    .rotationEffect(.degrees(Double(offset - previews.count + 1) * 6))
                    .offset(x: CGFloat(offset - previews.count + 1) * 14)
                    .transition(
                        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3), value: previews)
        .accessibilityHidden(true)
    }
}

struct PreviewTile: View {
    let data: Data

    var body: some View {
        Group {
            if let image = Self.image(data) {
                image.resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: 170, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 4) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }

    static func image(_ data: Data) -> Image? {
        #if os(macOS)
            NSImage(data: data).map { Image(nsImage: $0) }
        #else
            UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// A reason things were left out, with its count at the end of the first line (also for long, wrapping reasons).
struct SkipReasonLabel: View {
    let reason: ImportSkipReason
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ImportSummary.explanation(of: reason))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
