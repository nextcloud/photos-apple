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
    // MARK: Chunked uploads handed to the system

    /// Destinations that are taken although the server has nothing there yet: what is on its way with the system.
    var reservedPaths: Set<String> {
        (journal?.reservedPaths ?? []).union(UploadJobJournal.claims(at: uploadJobs).paths)
    }

    private func chunkedDriver(_ background: BackgroundUploads) -> ChunkedUploadDriver {
        ChunkedUploadDriver(transport: background.transport, uploader: remote.chunkedServer, window: background.chunkWindow)
    }

    /// Prepares a large upload (name, folder, upload folder on the server), moves the file to where it waits, and hands its
    /// first chunks to the system. Returns false when nothing had to be sent because the file is on the server already.
    func handOverChunked(
        _ resource: BackupResource, file: URL, fileName: String, folder: String, settings: BackupSettings,
        conflict: Uploader.ConflictPolicy
    ) async throws -> Bool {
        guard background != nil, journal != nil else { return false }
        let prepared = try await remote.prepareChunkedUpload(
            file: file, fileName: fileName, folder: folder, capturedAt: resource.createdAt, conflict: conflict, reserved: reservedPaths)
        switch prepared {
        case .existing(let uploaded):
            try await completed(resource, uploaded: uploaded)
            return false
        case .chunked(let upload):
            let isVideo = resource.mediaKind == .video
            let job = ChunkedBackgroundJob(
                upload: upload, resource: resource, fileName: file.lastPathComponent,
                allowsExpensiveNetwork: !(settings.wifiOnly || (isVideo && settings.wifiOnlyForVideos)),
                allowsConstrainedNetwork: settings.allowLowDataMode, startedAt: now())
            guard try journal?.stage(file, id: upload.id) != nil else { return false }
            do {
                try journal?.setChunked(job)
            } catch {
                journal?.removeChunked(upload.id)
                throw error
            }
            if let progress = await advanceChunked(upload.id) { await chunkedEnded(upload.id, progress) }
            return true
        }
    }

    /// Hands over what a chunked upload needs next (its upload folder, chunks, the `MOVE`).
    private func advanceChunked(_ id: String) async -> ChunkedUploadDriver.Progress? {
        await chunkedGate.enter()
        defer { chunkedGate.leave() }
        guard let background, let job = journal?.chunked[id], let files = journal?.files(of: job) else { return nil }
        var upload = job.upload
        let progress = await chunkedDriver(background).advance(&upload, files: files) { try self.journal?.updateChunked($0) }
        try? journal?.updateChunked(upload)
        return progress
    }

    /// Continues the chunked uploads that have room for more requests: after a launch, after the user's pause, or when
    /// the app could not reach the server while it handed them over.
    func driveChunkedUploads() async {
        guard !handOverPaused, !isShutDown, let ids = journal?.chunked.keys else { return }
        for id in ids {
            if let progress = await advanceChunked(id) { await chunkedEnded(id, progress) }
        }
    }

    /// The system reports a request of a chunked upload.
    func chunkReported(_ id: String, event: BackgroundUploadEvent) async {
        missing.remove(event.jobId)
        finishing += 1
        await chunkedGate.enter()
        var progress: ChunkedUploadDriver.Progress?
        if let background, let job = journal?.chunked[id], let files = journal?.files(of: job) {
            var upload = job.upload
            progress = await chunkedDriver(background).report(
                event, upload: &upload, files: files, handOver: !handOverPaused && !isShutDown
            ) { try self.journal?.updateChunked($0) }
            try? journal?.updateChunked(upload)
        }
        chunkedGate.leave()
        finishing -= 1
        if let progress { await chunkedEnded(id, progress) }
        try? refreshCounts()
        publishProgress()
        wakeWaiters()
    }

    /// Records a chunked upload that has ended; one that goes on is left alone.
    private func chunkedEnded(_ id: String, _ progress: ChunkedUploadDriver.Progress) async {
        switch progress {
        case .running:
            return
        case .finished(let uploaded):
            guard let job = journal?.removeChunked(id), !isShutDown else { return }
            do {
                try await completed(job.resource, uploaded: uploaded)
                settle(job.resource, .done)
            } catch {
                settle(job.resource, handedOverFailed(job.resource, error: error))
            }
        case .failed(let error):
            guard let job = journal?.removeChunked(id), !isShutDown else { return }
            logger.notice("backup: a chunked upload ended without the file")
            settle(job.resource, handedOverFailed(job.resource, error: error))
        }
    }

    /// Backup was turned off: large files that wait in the container are removed, and their chunks on the server.
    func discardChunkedUploads() {
        guard let background, let jobs = journal?.chunked.values, !jobs.isEmpty else { return }
        let ids = Set(jobs.flatMap { $0.upload.running.keys })
        let server = remote.chunkedServer
        let uploads = jobs.map(\.upload)
        for job in jobs { journal?.removeChunked(job.id) }
        Task {
            await background.transport.cancel(jobIds: ids)
            for upload in uploads { await server.abandon(upload, after: nil) }
        }
    }

    func throwBackgroundStop() throws {
        guard let stop = backgroundStop else { return }
        backgroundStop = nil
        throw stop
    }

    func publishProgress() {
        if let progress {
            publish(.uploading(done: progress.done, total: progress.total, current: progress.current))
        } else {
            statusHandler?(status)
        }
    }

    func cancelBackgroundUploads() {
        guard let background, let ids = journal?.allJobIds, !ids.isEmpty else { return }
        Task { await background.transport.cancel(jobIds: ids) }
    }

    /// Videos that were handed over on Wi-Fi must not go on over a cellular connection. The system would let them wait
    /// and they would block the queue for the photos, so they are taken back; they are handed over again on Wi-Fi.
    func takeBackHeldVideos(_ settings: BackupSettings) async -> BackupPause? {
        guard let background, let journal, let reason = pauseReason(settings, isVideo: true) else { return nil }
        let ids = Set(journal.jobs.values.filter { $0.resource.mediaKind == .video }.map(\.id))
        guard !ids.isEmpty else { return nil }
        await background.transport.cancel(jobIds: ids)
        return reason
    }

    /// Gives up uploads the system no longer knows and never reported (it was reset, or the report got lost). They are
    /// given up the second time they are found missing, so a report that is just on its way is not overtaken. The
    /// resources stay to do: the next pass finds the file on the server or uploads it again.
    func checkForMissingUploads() async {
        guard let background, let ids = journal?.allJobIds, !ids.isEmpty else {
            missing = []
            return
        }
        lastMissingCheck = Date()
        let active = await background.transport.activeJobIds()
        let gone = ids.subtracting(active)
        await chunkedGate.enter()
        defer { chunkedGate.leave() }
        for id in gone.intersection(missing) {
            if journal?.remove(id) != nil {
                logger.notice("an upload handed to the system was lost; it is done again")
            } else if let upload = journal?.chunkedUploadId(forJob: id), var state = journal?.chunked[upload]?.upload {
                // Only the request is lost: the chunk is handed over again, the others stay.
                state.lost([id])
                try? journal?.updateChunked(state)
                logger.notice("a chunk handed to the system was lost; it is sent again")
            }
        }
        missing = gone.subtracting(missing)
    }

    func wakeWaiters() {
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Waits until the system reports an upload, the network or power state changes, or some time has passed. Throws when
    /// the pass was cancelled or a reported upload ends it.
    func waitForBackgroundUploads() async throws {
        let id = UUID()
        let interval = missingCheckInterval
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            await self?.wake(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
        timeout.cancel()
        try Task.checkCancellation()
        try throwBackgroundStop()
        if Date().timeIntervalSince(lastMissingCheck) >= interval {
            await checkForMissingUploads()
            await driveChunkedUploads()
        }
    }

    /// Links the still and the motion part of a Live Photo once both are on the server, also when they got there in different runs.
    func linkLivePhoto(_ resource: BackupResource, uploaded: UploadedFile) async {
        guard [.photo, .edited, .pairedVideo].contains(resource.kind) else { return }
        let entries = (try? ledgerEntries(of: resource.localIdentifier)) ?? []
        func server(_ kind: BackupResourceKind) -> (path: String, fileId: FileID)? {
            guard let entry = entries.first(where: { $0.resourceKind == kind.rawValue }), BackupPolicy.isComplete(entry),
                let path = entry.serverPath, let fileId = entry.serverFileId
            else { return nil }
            return (path, fileId)
        }
        let still: (path: String, fileId: FileID)?
        let motion: (path: String, fileId: FileID)?
        if resource.kind == .pairedVideo {
            still = server(.edited) ?? server(.photo)
            motion = (uploaded.path, uploaded.fileId)
        } else {
            still = (uploaded.path, uploaded.fileId)
            motion = server(.pairedVideo)
        }
        guard let still, let motion else { return }
        do {
            try await remote.linkLivePhoto(
                imagePath: still.path, imageFileId: still.fileId, videoPath: motion.path, videoFileId: motion.fileId)
        } catch {
            logger.error("linking a Live Photo failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
