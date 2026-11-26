// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

extension BackupEngine {
    // MARK: Uploads handed to the system (SPEC §7.18.6)

    func setMissingCheckInterval(_ interval: TimeInterval) { missingCheckInterval = interval }

    /// Uploads that are with the system, by the id it knows them by (tests).
    var backgroundJobs: [String: BackgroundUploadJob] { journal?.jobs ?? [:] }

    /// Chunked uploads that are with the system, by upload id (tests).
    var chunkedJobs: [String: ChunkedBackgroundJob] { journal?.chunked ?? [:] }

    /// Uploads the system works on, and reports that are still being recorded. A chunked upload counts while it has
    /// requests with the system; one that has none (it could not hand over its next chunks) would wait for nothing.
    var activeBackgroundUploads: Int {
        guard let journal else { return finishing }
        return journal.jobs.count + finishing + journal.chunked.values.count { !$0.upload.running.isEmpty }
    }

    /// Whether the next large file has to wait until a chunked upload has finished.
    var chunkedIsFull: Bool {
        guard let background, let journal else { return false }
        return journal.chunked.values.count { !$0.upload.running.isEmpty } >= background.maxChunkedUploads
    }

    /// Whether the next file has to wait until the system has finished some of what it was given.
    func backgroundIsFull(adding resource: BackupResource) -> Bool {
        guard let background, let journal, !journal.jobs.isEmpty || finishing > 0 else { return false }
        if journal.jobs.count + finishing >= background.maxJobs { return true }
        let size = resource.byteSize ?? 0
        return size <= background.maxFileSize && journal.stagedBytes + size > background.maxStagedBytes
    }

    /// Prepares the upload and hands the file to the system. Returns false when nothing had to be sent because the file
    /// is on the server already.
    func handOver(
        _ resource: BackupResource, file: URL, fileName: String, folder: String, settings: BackupSettings,
        conflict: Uploader.ConflictPolicy
    ) async throws -> Bool {
        guard let background else { return false }
        // Names of uploads that are on their way are taken, although the server has nothing there yet.
        let prepared = try await remote.prepareUpload(
            file: file, fileName: fileName, folder: folder, capturedAt: resource.createdAt, conflict: conflict,
            reserved: reservedPaths)
        switch prepared {
        case .existing(let uploaded):
            try await completed(resource, uploaded: uploaded)
            return false
        case .put(let path, var request):
            // The system sends the file whenever it likes; the request itself has to say where it must not go.
            let isVideo = resource.mediaKind == .video
            request.allowsExpensiveNetwork = !(settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos))
            request.allowsConstrainedNetwork = settings.allowLowDataMode
            let job = BackgroundUploadJob(
                id: UUID().uuidString, resource: resource, path: path, size: Self.size(of: file), startedAt: now())
            guard let staged = try journal?.stage(file, id: job.id) else { return false }
            do {
                // Recorded before it starts: a report without a record could not be understood.
                try journal?.add(job)
                try await background.transport.start(jobId: job.id, request: request, file: staged)
            } catch {
                journal?.remove(job.id)
                throw error
            }
            return true
        }
    }

    /// The system reports that an upload has ended, with the server's answer or an error. This may be long after the pass
    /// that handed it over, and in another launch of the app.
    public func backgroundUploadFinished(_ event: BackgroundUploadEvent) async {
        if let upload = journal?.chunkedUploadId(forJob: event.jobId) {
            await chunkReported(upload, event: event)
            return
        }
        guard let job = journal?.remove(event.jobId) else { return }
        missing.remove(job.id)
        guard !isShutDown else { return }
        finishing += 1
        let result = await finish(job, event: event)
        finishing -= 1
        settle(job.resource, result)
        try? refreshCounts()
        publishProgress()
        wakeWaiters()
    }

    enum Finished {
        /// Done with for this pass: uploaded, or failed and recorded.
        case done
        /// Not sent (taken back, or the pass was stopped): it stays to do.
        case stillToDo
        /// The server did not take the file because its name was taken after the name check (`If-None-Match: *` → 412).
        /// Nothing was overwritten; the upload is prepared again, which finds the file that is there now (the same size
        /// counts as uploaded) or the next free name.
        case nameTaken
    }

    private func finish(_ job: BackgroundUploadJob, event: BackgroundUploadEvent) async -> Finished {
        do {
            if let error = event.error { throw error }
            guard let response = event.response else { throw NetworkError.invalidResponse("upload without an answer") }
            let uploaded = try await remote.finishUpload(path: job.path, response: response)
            try await completed(job.resource, uploaded: uploaded)
            return .done
        } catch {
            return handedOverFailed(job.resource, error: error)
        }
    }

    /// What the failure of an upload the system sent means.
    func handedOverFailed(_ resource: BackupResource, error: any Error) -> Finished {
        if error as? NetworkError == .preconditionFailed { return .nameTaken }
        // Taken back (the user's pause, a video that has to wait for Wi-Fi): still to do, not a failure.
        if BackupPolicy.isCancellation(error) { return .stillToDo }
        guard let stop = uploadFailed(resource, error: error) else { return .done }
        // Only a running pass can be stopped; without one the resource simply stays to do.
        if progress != nil, backgroundStop == nil { backgroundStop = stop }
        return .stillToDo
    }

    /// Records how the report of a single or chunked upload ended for the running pass.
    func settle(_ resource: BackupResource, _ result: Finished) {
        switch result {
        case .done:
            settled.insert(LedgerKey(resource))
            progress?.done += 1
        case .stillToDo:
            settled.insert(LedgerKey(resource))
        case .nameTaken:
            // Only a running pass can prepare it again; otherwise the next one does.
            if progress != nil { retake.append(resource) }
        }
    }
}
