// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS) || os(macOS)
    import Foundation
    import OSLog
    import Photos
    import PhotosBackup
    import PhotosModel
    import PhotosNetworking
    import PhotosStore
    import Synchronization

    /// The work of the app's PhotoKit background-upload extension (`Extensions/BackgroundUpload`, SPEC §7.18.6), which the
    /// system starts whenever it likes while backup is on: it opens the backup account from the shared container (accounts,
    /// keychain, database, options) and runs `BackupEngine.processUploadJobs`.
    public enum BackgroundUploadExtensionHost {
        private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
        /// The run in progress; the system may ask again while one runs, and ends the extension with `willTerminate`.
        private static let current = Mutex<Task<UploadJobsResult, Never>?>(nil)

        /// One run. A second call while one runs waits for it.
        public static func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
            let task = current.withLock { current in
                if let running = current { return running }
                let task = Task { await run() }
                current = task
                return task
            }
            let result = await task.value
            current.withLock { if $0 == task { $0 = nil } }
            switch result {
            case .processing: return .processing
            case .completed: return .completed
            case .failure: return .failure
            }
        }

        /// The system ends the extension: the run stops between two steps (what it recorded stays recorded).
        public static func willTerminate() {
            current.withLock { $0?.cancel() }
        }

        private static func run() async -> UploadJobsResult {
            let layout = AppPaths.layout
            let settings = BackupSettings.load(from: layout.backupSettingsFile)
            // Without the App Group the extension sees nothing of the app (unsigned development builds).
            guard AppPaths.usesAppGroup, settings.isEnabled, let id = settings.accountId,
                let account = AccountRegistry.load().accounts.first(where: { $0.id == id }), !account.isSignedOut,
                let password = Keychain().string(for: Keychain.passwordKey(id.rawValue))
            else {
                logger.notice("backup: PhotoKit asked for uploads, but backup is off or its account is not available")
                return .completed
            }
            let http = AppModel.makeHTTPClient()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let connection = ServerConnection(
                serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
                userAgent: UserAgent.make(appVersion: version))
            let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
            do {
                let database = try AccountDatabase(url: layout.database(id))
                let features = AccountServices.loadFeatures(id, layout: layout)
                let engine = await BackupEngine.forUploadJobs(
                    api: api, database: database, accountId: id, metadataEditing: features?.has(.metadataEdit) ?? false)
                let directory = layout.accountDirectory(id)
                return await engine.processUploadJobs(
                    settings: settings, service: PhotoKitUploadJobs(), journal: UploadJobJournal.file(in: directory),
                    appUploads: directory.appending(path: BackupModel.backgroundUploadsFolder),
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            } catch {
                logger.error("backup: the backup account could not be opened: \(error.localizedDescription, privacy: .public)")
                return .failure
            }
        }
    }
#endif
