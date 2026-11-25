// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import WatchConnectivity
import WidgetKit

/// The photos the iPhone sent (SPEC §15.3). The watch never talks to the server and holds no account: the phone sends a
/// `WatchDigest` as its application context and each photo as a small JPEG file (`transferFile`). Both are kept in the App Group, where the
/// complication reads them too.
@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var digest: WatchDigest?
    /// Bumped when photo files arrive, so views that show one look again.
    private(set) var filesVersion = 0
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "watch")

    /// The App Group's folder (shared with the complication); the app's own when there is no App Group (unsigned builds).
    nonisolated static var directory: URL {
        let group = Bundle.main.object(forInfoDictionaryKey: "PhotosAppGroup") as? String ?? "group.com.nextcloud.photos"
        let base =
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: WatchDigest.directoryName)
    }

    override init() {
        super.init()
        digest = Self.loadDigest()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #if DEBUG
            // Screenshots and UI checks without a paired phone: PHOTOS_DEBUG_WATCH_DIGEST=<folder with digest.json and the
            // JPEGs> fills the store as if the phone had sent it.
            if let folder = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_WATCH_DIGEST"] {
                importFolder(URL(filePath: folder))
            }
        #endif
    }

    func image(for photo: WatchDigest.Photo) -> URL? {
        let url = Self.directory.appending(path: photo.file)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    nonisolated static func loadDigest() -> WatchDigest? {
        guard let data = try? Data(contentsOf: directory.appending(path: WatchDigest.fileName)) else { return nil }
        return try? JSONDecoder().decode(WatchDigest.self, from: data)
    }

    /// A new digest: kept, files it no longer names removed, missing ones asked for again.
    func receive(digestData data: Data) {
        guard let digest = try? JSONDecoder().decode(WatchDigest.self, from: data) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.directory.appending(path: WatchDigest.fileName), options: .atomic)
        let wanted = digest.files.union([WatchDigest.fileName])
        let present = (try? manager.contentsOfDirectory(atPath: Self.directory.path(percentEncoded: false))) ?? []
        for name in present where !wanted.contains(name) {
            try? manager.removeItem(at: Self.directory.appending(path: name))
        }
        self.digest = digest
        let missing = digest.files.filter { !manager.fileExists(atPath: Self.directory.appending(path: $0).path(percentEncoded: false)) }
        if !missing.isEmpty, WCSession.default.activationState == .activated {
            // Files sent before the watch app was installed again, or lost: the phone sends them once more.
            WCSession.default.transferUserInfo([WatchDigest.missingKey: Array(missing).sorted()])
        }
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("watch: digest with \(digest.photos.count) photos, \(missing.count) still coming")
    }

    /// A photo file from the phone: moved into the App Group under its name.
    nonisolated static func store(file: URL, named name: String) -> Bool {
        // Only names as the phone makes them: what arrives must not lead out of the folder.
        guard WatchDigest.isValidFileName(name) else { return false }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: name)
        try? manager.removeItem(at: target)
        return (try? manager.moveItem(at: file, to: target)) != nil || (try? manager.copyItem(at: file, to: target)) != nil
    }

    func fileArrived() {
        filesVersion += 1
        WidgetCenter.shared.reloadAllTimelines()
    }

    #if DEBUG
        private func importFolder(_ folder: URL) {
            let manager = FileManager.default
            for name in (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] where name.hasSuffix(".jpg") {
                let copy = manager.temporaryDirectory.appending(path: UUID().uuidString)
                try? manager.copyItem(at: folder.appending(path: name), to: copy)
                _ = Self.store(file: copy, named: name)
            }
            if let data = try? Data(contentsOf: folder.appending(path: WatchDigest.fileName)) { receive(digestData: data) }
            fileArrived()
        }
    #endif
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        let context = session.receivedApplicationContext
        guard let data = context[WatchDigest.contextKey] as? Data else { return }
        Task { @MainActor in self.receive(digestData: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchDigest.contextKey] as? Data else { return }
        Task { @MainActor in self.receive(digestData: data) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this returns: it is moved now, not in a later task.
        guard let name = file.metadata?[WatchDigest.fileKey] as? String, Self.store(file: file.fileURL, named: name) else { return }
        Task { @MainActor in self.fileArrived() }
    }
}
