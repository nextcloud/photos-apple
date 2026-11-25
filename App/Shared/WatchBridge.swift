// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS)
    import Foundation
    import OSLog
    import PhotosCore
    import PhotosModel
    import WatchConnectivity

    /// Sends today's photos to the Apple Watch app (SPEC §15.3): after a sync, when the app comes to the front and in the
    /// background refresh. The watch gets small JPEGs and a `WatchDigest` naming them, never the account or its password.
    /// Photos it already has are not sent again; with app lock on it gets an empty, locked digest.
    @MainActor
    final class WatchBridge: NSObject {
        static let shared = WatchBridge()

        private weak var app: AppModel?
        private var pending: Task<Void, Never>?
        private let logger = Logger(subsystem: "com.nextcloud.photos", category: "watch")
        /// File names the watch has or is receiving (cleared when it reports one missing).
        private var sent: Set<String> {
            get { Set(UserDefaults.standard.stringArray(forKey: "watchSentFiles") ?? []) }
            set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "watchSentFiles") }
        }

        /// The phone's copies of what it sends (Caches: the system may clear them, they are made again).
        private static var outbox: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: WatchDigest.directoryName)
        }

        func start(app: AppModel) {
            guard self.app == nil, WCSession.isSupported() else { return }
            self.app = app
            WCSession.default.delegate = self
            WCSession.default.activate()
            observeSync()
        }

        /// Sends the digest again a little later (several triggers in a row send once).
        func scheduleUpdate(after delay: Duration = .seconds(3)) {
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.update()
            }
        }

        /// Builds today's digest and sends what the watch does not have yet.
        func update() async {
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
            let digest: WatchDigest
            let today = Calendar.current.startOfDay(for: Date())
            if AppLockSettings.isEnabled() {
                digest = WatchDigest(day: today, onThisDayTitle: nil, photos: [], photoOfTheDay: nil, isLocked: true)
            } else if let services = app?.session?.services, app?.session?.isSignedOut == false {
                digest = await CompanionExport.watchDigest(services: services, directory: Self.outbox)
            } else {
                // Logged out: the watch shows nothing and asks to open the app.
                digest = WatchDigest(day: today, onThisDayTitle: nil, photos: [], photoOfTheDay: nil)
            }
            var sent = self.sent.intersection(digest.files)
            var transferred = 0
            for photo in digest.photos where !sent.contains(photo.file) {
                let url = Self.outbox.appending(path: photo.file)
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                session.transferFile(url, metadata: [WatchDigest.fileKey: photo.file])
                sent.insert(photo.file)
                transferred += 1
            }
            self.sent = sent
            logger.notice(
                "watch: \(transferred, privacy: .public) photos sent, \(digest.photos.count - transferred, privacy: .public) already there")
            do {
                let encoded = try JSONEncoder().encode(digest)
                // Beside the photos, for looking at what the watch got (docs/TESTING.md).
                try? encoded.write(to: Self.outbox.appending(path: WatchDigest.fileName), options: .atomic)
                // A sync that changed nothing the watch shows sends nothing.
                guard transferred > 0 || encoded != UserDefaults.standard.data(forKey: "watchDigest") else { return }
                try session.updateApplicationContext([WatchDigest.contextKey: encoded])
                UserDefaults.standard.set(encoded, forKey: "watchDigest")
                logger.notice("watch: digest sent, \(digest.photos.count) photos")
            } catch {
                logger.error("watch: digest not sent: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// A sync that has finished, an account switch or app lock: the watch's photos may have changed.
        private func observeSync() {
            withObservationTracking {
                _ = app?.session?.syncStatus
                _ = app?.session?.account.id
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .idle = self.app?.session?.syncStatus { self.scheduleUpdate() }
                    self.observeSync()
                }
            }
        }

        private func resend(_ missing: [String]) {
            logger.notice("watch: \(missing.count, privacy: .public) photos missing on the watch")
            sent = sent.subtracting(missing)
            UserDefaults.standard.removeObject(forKey: "watchDigest")
            scheduleUpdate(after: .zero)
        }
    }

    extension WatchBridge: WCSessionDelegate {
        nonisolated func session(
            _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
        ) {
            guard activationState == .activated else { return }
            Task { @MainActor in self.scheduleUpdate(after: .zero) }
        }

        nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
            // The watch app was installed (or the watch changed): it has nothing yet.
            let installed = session.isWatchAppInstalled
            Task { @MainActor in
                if !installed {
                    self.sent = []
                    UserDefaults.standard.removeObject(forKey: "watchDigest")
                }
                self.scheduleUpdate(after: .zero)
            }
        }

        nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            // The watch names photos it does not have (re-installed app, lost transfer): they are sent again.
            guard let missing = userInfo[WatchDigest.missingKey] as? [String] else { return }
            Task { @MainActor in self.resend(missing) }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // Another watch was chosen: the new one gets everything.
            Task { @MainActor in
                self.sent = []
                UserDefaults.standard.removeObject(forKey: "watchDigest")
                WCSession.default.activate()
            }
        }
    }
#endif
