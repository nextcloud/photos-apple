// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS) || os(macOS)
    import Foundation
    import OSLog
    import Photos
    import Synchronization

    /// PhotoKit's background-upload service (`PHAssetResourceUploadJob`, iOS/iPadOS and macOS 27): the system reads a
    /// resource from the photo library, downloads it from iCloud when needed, and sends it with the request the backup
    /// gives it, also while the app is not running (SPEC §7.18.6). Only usable inside the app's
    /// `com.apple.photos.background-upload` extension.
    public final class PhotoKitUploadJobs: UploadJobService {
        /// The job objects of the last fetch, by id: acknowledging and retrying need them.
        private let known = Mutex<[String: PHAssetResourceUploadJob]>([:])

        public init() {}

        public var jobLimit: Int { PHAssetResourceUploadJob.jobLimit }

        public func endedJobs() async -> [UploadJobInfo] { fetch(.acknowledge) }

        public func retryableJobs() async -> [UploadJobInfo] { fetch(.retry) }

        public func jobsInFlight() async -> [UploadJobInfo] { fetch(.process) }

        private func fetch(_ action: PHAssetResourceUploadJob.Action) -> [UploadJobInfo] {
            var jobs: [PHAssetResourceUploadJob] = []
            PHAssetResourceUploadJob.fetchJobs(action: action, options: nil).enumerateObjects { job, _, _ in jobs.append(job) }
            known.withLock { known in for job in jobs { known[job.localIdentifier] = job } }
            return jobs.map(Self.info)
        }

        static func info(_ job: PHAssetResourceUploadJob) -> UploadJobInfo {
            let state: UploadJobInfo.State =
                switch job.state {
                case .succeeded: .succeeded
                case .failed: .failed
                case .cancelled: .cancelled
                default: .inFlight
                }
            let headers = Dictionary((job.responseHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
            return UploadJobInfo(
                id: job.localIdentifier, destination: job.destination.url, state: state, responseHeaders: headers,
                errorDescription: job.error?.localizedDescription)
        }

        public func create(_ resource: BackupResource, settings: BackupSettings, request: URLRequest) async throws -> String {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [resource.localIdentifier], options: nil).firstObject,
                let photoResource = PhotoLibrarySource().resources(of: asset, settings: settings).first(where: {
                    $0.0.kind == resource.kind
                })?
                .1
            else { throw CocoaError(.fileNoSuchFile) }
            let id = Mutex<String?>(nil)
            try await PHPhotoLibrary.shared().performChanges {
                let change = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: request, resource: photoResource)
                id.withLock { $0 = change.placeholderForCreatedAssetResourceUploadJob?.localIdentifier }
            }
            guard let created = id.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
            return created
        }

        public func acknowledge(_ ids: [String]) async throws {
            let jobs = known.withLock { known in ids.compactMap { known[$0] } }
            guard !jobs.isEmpty else { return }
            try await PHPhotoLibrary.shared().performChanges {
                for job in jobs { PHAssetResourceUploadJobChangeRequest(for: job)?.acknowledge() }
            }
        }

        public func retry(_ id: String, request: URLRequest) async throws {
            guard let job = known.withLock({ $0[id] }) else { return }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: request)
            }
        }
    }

    /// Turns PhotoKit's background uploads for this app on and off (`PHPhotoLibrary.enableUploadJobExtension`). The
    /// system then calls the app's background-upload extension by itself.
    public enum UploadJobExtension {
        private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")

        /// Whether PhotoKit calls the extension.
        public static var isEnabled: Bool { PHPhotoLibrary.shared().uploadJobExtensionEnabled }

        /// - Parameters:
        ///   - enabled: backup is on, with access to the whole library (PhotoKit requires it) and a container the extension
        ///     shares with the app.
        ///   - wifiOnly: "Wi-Fi only for all": PhotoKit then never uses cellular (videos are kept off it per request).
        public static func update(enabled: Bool, wifiOnly: Bool) {
            let library = PHPhotoLibrary.shared()
            do {
                if enabled {
                    let options = PHAssetResourceUploadJobOptions()
                    options.preventsExpensiveNetworkAccess = wifiOnly
                    if !library.uploadJobExtensionEnabled {
                        try library.enableUploadJobExtension(with: options)
                        logger.notice("backup: PhotoKit background uploads turned on")
                    } else if library.uploadJobExtensionOptions?.preventsExpensiveNetworkAccess != wifiOnly {
                        try library.setUploadJobExtensionOptions(options)
                    }
                } else if library.uploadJobExtensionEnabled {
                    try library.disableUploadJobExtension()
                    logger.notice("backup: PhotoKit background uploads turned off")
                }
            } catch {
                logger.error("backup: PhotoKit background uploads could not be changed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
#endif
