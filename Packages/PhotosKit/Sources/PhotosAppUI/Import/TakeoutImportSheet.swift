// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

/// One import of a Google Takeout export (SPEC §7.18.10). It belongs to an account and outlives the sheet: closing the
/// sheet does not stop it, opening it again shows how far it got.
@MainActor
@Observable
final class TakeoutImportController {
    enum Stage: Equatable {
        case choose, reading, ready, running, finished
    }

    private(set) var stage: Stage = .choose
    private(set) var plan: TakeoutPlan?
    private(set) var progress = TakeoutProgress()
    /// Files an earlier, interrupted import of the same export got through.
    private(set) var alreadyDone = 0
    private(set) var error: String?
    var options = TakeoutOptions(destination: "/Photos/Google Photos")
    @ObservationIgnored private var source: TakeoutSource?
    @ObservationIgnored private var accessed: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    private static var controllers: [AccountID: TakeoutImportController] = [:]

    static func controller(for account: AccountID) -> TakeoutImportController {
        if let controller = controllers[account] { return controller }
        let controller = TakeoutImportController()
        controllers[account] = controller
        return controller
    }

    /// Reads the export: every sidecar and album description, not the photos.
    func read(_ urls: [URL], session: SessionModel) {
        stopAccessing()
        accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        stage = .reading
        error = nil
        let journalDirectory = Self.journalDirectory(session)
        options.destination = (session.features.userConfig.photosLocation as NSString).appendingPathComponent("Google Photos")
        options.descriptionsAsComments = session.features.has(.comments)
        task = Task {
            do {
                let (source, plan) = try await Task.detached(priority: .userInitiated) {
                    let source = try TakeoutSource.open(urls)
                    return (source, try TakeoutPlan.build(source))
                }.value
                guard !plan.items.isEmpty else {
                    error = String(
                        localized: "No photos or videos were found. Choose the Takeout folder or its ZIP files.", bundle: .module)
                    stage = .choose
                    return
                }
                self.source = source
                self.plan = plan
                alreadyDone = journalDirectory.flatMap { TakeoutJournal.load(from: $0, planKey: plan.key)?.completed } ?? 0
                stage = .ready
            } catch {
                self.error = error.localizedDescription
                stage = .choose
            }
        }
    }

    static func journalDirectory(_ session: SessionModel) -> URL? {
        session.services.map { $0.layout.accountDirectory($0.account.id).appending(path: "Takeout") }
    }

    func start(session: SessionModel) {
        guard let source, let plan, let services = session.services, let journalDirectory = Self.journalDirectory(session) else { return }
        let importer = TakeoutImporter(
            source: source, plan: plan, api: services.api, database: services.database, features: session.features, options: options,
            journalDirectory: journalDirectory)
        stage = .running
        progress = TakeoutProgress()
        progress.total = plan.items.count
        task = Task {
            let result = await importer.run { progress in
                Task { @MainActor [weak self] in
                    if self?.stage == .running { self?.progress = progress }
                }
            }
            progress = result
            stage = .finished
            alreadyDone = TakeoutJournal.load(from: journalDirectory, planKey: plan.key)?.completed ?? 0
            await session.syncNow()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Back to the start: another export can be chosen.
    func reset() {
        task?.cancel()
        task = nil
        source = nil
        plan = nil
        progress = TakeoutProgress()
        error = nil
        stage = .choose
        stopAccessing()
    }

    private func stopAccessing() {
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        accessed = []
    }

    /// Whether the destination is inside a timeline folder, so the imported photos show in the library.
    func destinationIsInTimeline(_ session: SessionModel) -> Bool {
        let destination = options.destination
        return session.features.userConfig.photosSourceFolders.contains { folder in
            folder == "/" || destination == folder || destination.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}

/// Import from Google Takeout (Mac): choose the export, see what it holds, import it with progress, cancel and resume.
struct TakeoutImportSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false

    var controller: TakeoutImportController { TakeoutImportController.controller(for: session.account.id) }

    var body: some View {
        @Bindable var controller = controller
        NavigationStack {
            Form {
                switch controller.stage {
                case .choose: chooseSection
                case .reading:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading the export…", bundle: .module)
                        }
                    }
                case .ready: readySections(controller)
                case .running, .finished: progressSections
                }
                if let error = controller.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Import from Google Takeout", bundle: .module))
            .toolbar { toolbar }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .zip], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                controller.read(urls, session: session)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if controller.stage == .running {
                Button(String(localized: "Stop Import", bundle: .module)) { controller.cancel() }
            } else {
                Button(String(localized: "Close", bundle: .module)) {
                    if controller.stage == .finished { controller.reset() }
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
                Button(title) {
                    controller.start(session: session)
                }
                .disabled(controller.options.destination.isEmpty || !controller.options.destination.hasPrefix("/"))
            case .running:
                // The import goes on without the sheet.
                Button(String(localized: "Hide", bundle: .module)) { dismiss() }
            case .finished:
                // Stopped, or some files failed: the journal knows what is done, the rest is tried again.
                if controller.progress.phase != .finished || controller.progress.failed > 0 {
                    Button(String(localized: "Resume Import", bundle: .module)) { controller.start(session: session) }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder var chooseSection: some View {
        Section {
            Text(
                "Download your photos from Google with Google Takeout (takeout.google.com, Google Photos only). Choose the unpacked Takeout folder, or its ZIP files: they don't need to be unpacked.",
                bundle: .module)
            Button(String(localized: "Choose Takeout Folder or ZIP Files…", bundle: .module)) { choosing = true }
        } footer: {
            Text(
                "Photos and videos are uploaded as they are, with the date and place Google Photos knows. Photos already on your server are skipped, and albums are created again.",
                bundle: .module)
        }
    }

    @ViewBuilder func readySections(_ controller: TakeoutImportController) -> some View {
        @Bindable var controller = controller
        if let plan = controller.plan {
            Section(String(localized: "Export", bundle: .module)) {
                LabeledContent(
                    String(localized: "Photos and videos", bundle: .module),
                    value: "\(plan.items.count.formatted()) · \(Formatters.bytes(Int64(plan.totalBytes)))")
                LabeledContent(String(localized: "Albums", bundle: .module), value: plan.albums.count.formatted())
                if plan.duplicatesInExport > 0 {
                    Text("\(plan.duplicatesInExport) copies in album folders are imported once.", bundle: .module)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if plan.withoutSidecar > 0 {
                    Text(
                        "\(plan.withoutSidecar) items have no Google Photos details; they keep the date in their own metadata.",
                        bundle: .module
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if plan.skippedTrash > 0 {
                    Text("\(plan.skippedTrash) items in the export's trash are left out.", bundle: .module)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if controller.alreadyDone > 0 {
                    Text(
                        "An earlier import of this export got through \(controller.alreadyDone) of \(plan.items.count) items. It continues where it stopped.",
                        bundle: .module
                    )
                    .font(.footnote)
                }
            }
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
                Toggle(String(localized: "Sort into a folder per year", bundle: .module), isOn: $controller.options.yearSubfolders)
                Toggle(String(localized: "Create albums", bundle: .module), isOn: $controller.options.createAlbums)
                if session.features.has(.comments) {
                    Toggle(
                        String(localized: "Keep captions as comments", bundle: .module), isOn: $controller.options.descriptionsAsComments)
                }
            } header: {
                Text("Import", bundle: .module)
            } footer: {
                if !session.features.has(.metadataEdit) {
                    Text(
                        "Places from Google Photos can only be added to photos without a location of their own on Nextcloud 35 or later.",
                        bundle: .module)
                }
            }
        }
    }

    @ViewBuilder var progressSections: some View {
        let progress = controller.progress
        Section {
            ProgressView(value: progress.fraction) {
                Text(statusTitle(progress))
            } currentValueLabel: {
                Text("\(progress.processed) of \(progress.total)", bundle: .module).monospacedDigit()
            }
            if let name = progress.currentName, progress.isRunning {
                Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent(String(localized: "Uploaded", bundle: .module), value: progress.uploaded.formatted())
            LabeledContent(String(localized: "Already on your server", bundle: .module), value: progress.duplicates.formatted())
            if progress.failed > 0 {
                LabeledContent(String(localized: "Could not be uploaded", bundle: .module), value: progress.failed.formatted())
            }
            if progress.albumsTotal > 0 {
                LabeledContent(
                    String(localized: "Albums", bundle: .module),
                    value: "\(progress.albumsCreated.formatted()) / \(progress.albumsTotal.formatted())")
            }
        } footer: {
            if progress.isRunning {
                Text("You can close this window; the import goes on while the app is open.", bundle: .module)
            }
        }
        if !progress.failures.isEmpty {
            Section(String(localized: "Problems", bundle: .module)) {
                ForEach(progress.failures, id: \.self) { Text($0).font(.footnote) }
            }
        }
    }

    func statusTitle(_ progress: TakeoutProgress) -> String {
        switch progress.phase {
        case .importing: String(localized: "Importing…", bundle: .module)
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
