// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosCore
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

/// The photo Image ▸ Edit With ▸ opens, and how (SPEC §15.2).
struct EditWithTarget {
    var item: MediaItem
    /// Opens the photo in the app at this URL.
    var open: (URL) -> Void
}

/// Saving what another app made of a photo (SPEC §15.2, "Edit in external app"): a save replaces the file on the server
/// as a new version (`If-Match` with the ETag the app downloaded, so a newer version is never overwritten); when the
/// server has a newer version, or the photo may not be changed, it is uploaded as a copy next to it instead.
enum ExternalEditSaving {
    /// Where a save went.
    enum Outcome: Equatable, Sendable {
        /// The file on the server is the edited one now; this is its new ETag.
        case replaced(etag: String?)
        /// A copy was made next to the original: its path and ETag. Later saves go to the copy.
        case copy(path: String, etag: String?)
    }

    /// The file a session writes to on the server: the original, or the copy made earlier.
    struct Target: Equatable, Sendable {
        var path: String
        var etag: String
        var canWrite: Bool
        var capturedAt: Date?
    }

    /// `<name> (edited).<ext>`: the stacking rule shows it with the original (`TimelineStacks`).
    static func copyName(for name: String, savedAs file: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = file.pathExtension.isEmpty ? (name as NSString).pathExtension : file.pathExtension
        return ext.isEmpty ? "\(base) (edited)" : "\(base) (edited).\(ext)"
    }

    /// ETags come quoted from the server; the index keeps them without quotes.
    static func etag(of response: HTTPResponse) -> String? {
        (response.header("oc-etag") ?? response.header("etag"))?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func save(_ file: URL, to target: Target, name: String, dav: DAVClient) async throws -> Outcome {
        let sameType = (name as NSString).pathExtension.lowercased() == file.pathExtension.lowercased()
        if target.canWrite, sameType {
            var headers: [String: String] = [:]
            if !target.etag.isEmpty { headers["If-Match"] = "\"\(target.etag)\"" }
            do {
                let response = try await dav.put(dav.connection.filesURL(target.path), file: file, headers: headers)
                return .replaced(etag: etag(of: response))
            } catch NetworkError.preconditionFailed {
                // Changed on the server since it was downloaded: the edit goes next to it.
            }
        }
        let folder = (target.path as NSString).deletingLastPathComponent
        let uploaded = try await Uploader(dav: dav).upload(
            file: file, fileName: copyName(for: name, savedAs: file), folder: folder.isEmpty ? "/" : folder,
            capturedAt: target.capturedAt)
        return .copy(path: uploaded.path, etag: uploaded.etag)
    }

    /// What is known of a file to notice that another app saved it.
    struct Snapshot: Equatable, Sendable {
        var modified: Date?
        var size: Int?

        init(modified: Date?, size: Int?) {
            self.modified = modified
            self.size = size
        }

        init?(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            self.init(modified: values.contentModificationDate, size: values.fileSize)
        }
    }

    /// A save is finished when the file was changed and has stayed the same since the last look (apps write in steps,
    /// or save to a temporary file and swap it in).
    static func isSettledSave(uploaded: Snapshot?, previous: Snapshot?, current: Snapshot?) -> Bool {
        guard let current, current.size ?? 0 > 0 else { return false }
        return current != uploaded && current == previous
    }
}

#if os(macOS)
    /// The photos open in other apps, each watched for saves until the user is done or the app quits.
    @MainActor
    @Observable
    final class ExternalEditCenter {
        static let shared = ExternalEditCenter()

        struct Session: Identifiable, Equatable {
            enum State: Equatable {
                case downloading
                case opening
                /// Open in the app; saves are uploaded.
                case watching
                case uploading
                case failed(String)
            }

            let id = UUID()
            var name: String
            var fileId: FileID
            var appName: String
            var appBundleId: String?
            var state: State = .downloading
            /// The last save that reached the server, and whether it went to a copy.
            var savedAt: Date?
            var savedAsCopy = false
            var folder: URL
            var file: URL
        }

        private(set) var sessions: [Session] = []
        @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
        @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "edit-with")

        /// Every session's files live here; what is left from an earlier run is removed at the first use.
        static var root: URL { FileManager.default.temporaryDirectory.appending(path: "EditWith") }

        private init() {
            try? FileManager.default.removeItem(at: Self.root)
        }

        /// UI checks without another app coming to the front: `PHOTOS_DEBUG_EDIT_WITH_NO_OPEN=1` (debug builds) downloads
        /// and watches the photo without opening it; the check changes the file itself.
        static var skipsOpening: Bool {
            #if DEBUG
                ProcessInfo.processInfo.environment["PHOTOS_DEBUG_EDIT_WITH_NO_OPEN"] != nil
            #else
                false
            #endif
        }

        #if DEBUG
            private static var debugStartUsed = false

            /// `PHOTOS_DEBUG_EDIT_WITH=<index>` (debug builds): opens that photo of the grid in Preview at launch, once.
            static func debugStart(ids: [FileID], session: SessionModel) {
                guard !debugStartUsed, let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_EDIT_WITH"], let index = Int(raw),
                    ids.indices.contains(index), let item = try? session.services?.library.item(ids[index])
                else { return }
                debugStartUsed = true
                shared.open(item, with: URL(filePath: "/System/Applications/Preview.app"), session: session)
            }
        #endif

        /// How often the file is looked at.
        static let pollInterval: Duration = .seconds(1)

        func open(_ item: MediaItem, with app: URL, session: SessionModel) {
            guard let services = session.services else { return }
            let folder = Self.root.appending(path: UUID().uuidString)
            let file = folder.appending(path: item.name)
            let bundle = Bundle(url: app)
            var entry = Session(
                name: item.name, fileId: item.fileId, appName: EditWithApps.name(of: app), appBundleId: bundle?.bundleIdentifier,
                folder: folder, file: file)
            entry.state = .downloading
            sessions.append(entry)
            let id = entry.id
            watchers[id] = Task { [weak self] in
                await self?.run(id, item: item, app: app, services: services, session: session)
            }
        }

        private func update(_ id: UUID, _ change: (inout Session) -> Void) {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            change(&sessions[index])
        }

        private func run(_ id: UUID, item: MediaItem, app: URL, services: AccountServices, session: SessionModel) async {
            guard let entry = sessions.first(where: { $0.id == id }) else { return }
            do {
                try FileManager.default.createDirectory(at: entry.folder, withIntermediateDirectories: true)
                let original = try await services.images.originals.original(
                    fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
                try FileManager.default.copyItem(at: original, to: entry.file)
                update(id) { $0.state = .opening }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                if !Self.skipsOpening {
                    _ = try await NSWorkspace.shared.open([entry.file], withApplicationAt: app, configuration: configuration)
                }
                update(id) { $0.state = .watching }
            } catch {
                logger.error("edit with: could not open: \(error.localizedDescription, privacy: .public)")
                update(id) { $0.state = .failed(error.localizedDescription) }
                return
            }
            var target = ExternalEditSaving.Target(
                path: item.path, etag: item.etag, canWrite: item.permissions.canWrite, capturedAt: item.capturedAt)
            var uploaded = ExternalEditSaving.Snapshot(entry.file)
            var previous = uploaded
            let terminated = Self.terminations(of: entry.appBundleId)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                let current = ExternalEditSaving.Snapshot(entry.file)
                if ExternalEditSaving.isSettledSave(uploaded: uploaded, previous: previous, current: current) {
                    update(id) { $0.state = .uploading }
                    do {
                        let outcome = try await ExternalEditSaving.save(entry.file, to: target, name: item.name, dav: services.dav)
                        switch outcome {
                        case .replaced(let etag):
                            target.etag = etag ?? ""
                            update(id) {
                                $0.savedAt = Date()
                                $0.state = .watching
                            }
                        case .copy(let path, let etag):
                            target = ExternalEditSaving.Target(path: path, etag: etag ?? "", canWrite: true, capturedAt: item.capturedAt)
                            update(id) {
                                $0.savedAt = Date()
                                $0.savedAsCopy = true
                                $0.state = .watching
                            }
                        }
                        uploaded = current
                        await session.syncNow()
                    } catch {
                        logger.error("edit with: upload failed: \(error.localizedDescription, privacy: .public)")
                        update(id) { $0.state = .failed(error.localizedDescription) }
                        // Tried again at the next change.
                        uploaded = current
                    }
                }
                previous = current
                // The app quit: its last save is in; the session ends.
                if terminated.hasEnded(), current == uploaded {
                    break
                }
            }
            terminated.cancel()
            if !Task.isCancelled { finish(id) }
        }

        /// Ends a session: no more uploads, the copy on this Mac is removed.
        func finish(_ id: UUID) {
            watchers[id]?.cancel()
            watchers[id] = nil
            if let entry = sessions.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: entry.folder) }
            sessions.removeAll { $0.id == id }
        }

        /// Notices when the editing app quits.
        @MainActor
        final class TerminationWatch {
            private var ended = false
            private var task: Task<Void, Never>?

            init(bundleId: String?) {
                guard let bundleId else { return }
                task = Task { [weak self] in
                    for await note in NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.didTerminateApplicationNotification)
                    {
                        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        if app?.bundleIdentifier == bundleId {
                            self?.ended = true
                            return
                        }
                    }
                }
            }

            func hasEnded() -> Bool { ended }
            func cancel() { task?.cancel() }
        }

        static func terminations(of bundleId: String?) -> TerminationWatch { TerminationWatch(bundleId: bundleId) }
    }

    /// The apps that can open a photo, as Finder's "Open With" lists them.
    @MainActor
    enum EditWithApps {
        static func type(of item: MediaItem) -> UTType {
            UTType(filenameExtension: (item.name as NSString).pathExtension) ?? UTType(mimeType: item.mimeType) ?? .image
        }

        /// The default app first, then the others by name; this app is left out.
        static func apps(for item: MediaItem) -> [URL] {
            let type = type(of: item)
            let own = Bundle.main.bundleURL.standardizedFileURL
            let all = NSWorkspace.shared.urlsForApplications(toOpen: type).filter { $0.standardizedFileURL != own }
            let preferred = NSWorkspace.shared.urlForApplication(toOpen: type)
            var seen = Set<String>()
            let unique = all.filter { seen.insert(name(of: $0)).inserted }
            let sorted = unique.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
            guard let preferred, let first = sorted.first(where: { $0.standardizedFileURL == preferred.standardizedFileURL }) else {
                return sorted
            }
            return [first] + sorted.filter { $0 != first }
        }

        static func name(of app: URL) -> String {
            FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }

        static func icon(of app: URL) -> NSImage {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }

        /// "Other…": an app chosen in the Applications folder.
        static func chooseApp() -> URL? {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(filePath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Edit", bundle: .module, comment: "Edit With › Other…: button of the app picker.")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// Image ▸ Edit With ▸ <apps>, Other….
    struct EditWithMenu: View {
        let item: EditWithTarget?

        var body: some View {
            Menu(EditWithWording.menuTitle) {
                if let item {
                    let apps = EditWithApps.apps(for: item.item)
                    ForEach(apps, id: \.self) { app in
                        Button {
                            item.open(app)
                        } label: {
                            Label {
                                Text(verbatim: EditWithApps.name(of: app))
                            } icon: {
                                Image(nsImage: EditWithApps.icon(of: app))
                            }
                        }
                    }
                    if !apps.isEmpty { Divider() }
                    Button(EditWithWording.otherTitle) {
                        if let app = EditWithApps.chooseApp() { item.open(app) }
                    }
                }
            }
            .disabled(item == nil)
        }
    }

    /// The photos open in other apps, in the toolbar while there are any: what happened to the last save, and Done.
    struct ExternalEditsIndicator: View {
        @State private var center = ExternalEditCenter.shared
        @State private var showing = false

        var body: some View {
            if !center.sessions.isEmpty {
                Button {
                    showing = true
                } label: {
                    Label(EditWithWording.indicatorTitle(center.sessions.count), systemImage: "pencil.and.outline")
                }
                .help(EditWithWording.indicatorTitle(center.sessions.count))
                .popover(isPresented: $showing) {
                    ExternalEditsList().frame(width: 380)
                }
            }
        }
    }

    private struct ExternalEditsList: View {
        @State private var center = ExternalEditCenter.shared

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(center.sessions) { session in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: session.name).lineLimit(1).truncationMode(.middle)
                            Text(EditWithWording.status(session)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(String(localized: "Done", bundle: .module)) { center.finish(session.id) }
                            .help(EditWithWording.doneHelp)
                    }
                    .padding(12)
                    Divider()
                }
                Text(EditWithWording.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
    }
#endif

enum EditWithWording {
    static var menuTitle: String {
        String(localized: "Edit With", bundle: .module, comment: "Image menu (Mac): submenu with apps that can edit the photo.")
    }

    static var otherTitle: String {
        String(localized: "Other…", bundle: .module, comment: "Edit With submenu: choose another app.")
    }

    static func indicatorTitle(_ count: Int) -> String {
        String(
            localized: "Editing \(count) photos in other apps", bundle: .module,
            comment: "Toolbar button (Mac) while photos are open in other apps. Plural variations.")
    }

    static var doneHelp: String {
        String(
            localized: "Stop watching for saves and remove the copy on this Mac", bundle: .module,
            comment: "Tooltip of Done for a photo open in another app.")
    }

    static var footer: String {
        String(
            localized:
                "Every save in the other app is uploaded as a new version of the photo. If the photo changed on the server in the meantime, the save becomes a copy next to it.",
            bundle: .module, comment: "Explanation below the photos open in other apps (Mac).")
    }

    #if os(macOS)
        static func status(_ session: ExternalEditCenter.Session) -> String {
            switch session.state {
            case .downloading:
                return String(localized: "Downloading the original…", bundle: .module, comment: "Edit With status.")
            case .opening:
                return String(localized: "Opening in \(session.appName)…", bundle: .module, comment: "Edit With status: the app's name.")
            case .uploading:
                return String(localized: "Uploading the edited photo…", bundle: .module, comment: "Edit With status.")
            case .failed(let message):
                return message
            case .watching:
                guard let saved = session.savedAt else {
                    return String(
                        localized: "Open in \(session.appName). Save there to update it on your Nextcloud.", bundle: .module,
                        comment: "Edit With status: the app's name.")
                }
                let time = saved.formatted(date: .omitted, time: .shortened)
                return session.savedAsCopy
                    ? String(
                        localized: "Saved as a copy at \(time)", bundle: .module,
                        comment: "Edit With status: the save went to a copy (the photo changed on the server or is read-only).")
                    : String(
                        localized: "Saved at \(time)", bundle: .module, comment: "Edit With status: the photo on the server was updated.")
            }
        }
    #endif
}
