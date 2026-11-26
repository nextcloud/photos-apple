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
    // MARK: Upload

    /// Uploads the resources. Returns why some of them still wait, or nil when all were tried.
    ///
    /// Throws for what ends the run: cancellation, a lost connection, and errors that every other file would hit as well
    /// (`BackupPolicy.blocker`). A failure of one resource is recorded and the run goes on.
    ///
    /// With `background`, files up to its size limit are prepared here (name, folder) and handed to the system, a few
    /// ahead of what it has finished; the pass ends when the system has reported all of them, or leaves them to it when it
    /// is interrupted. Larger files are sent in chunks by the app itself, as without `background`; they come last
    /// (`BackupPolicy.uploadOrder`), so that a pass that only gets a short time hands everything else over first.
    ///
    /// - Parameter drain: wait until the system has reported what it was given; without it the call returns when
    ///   everything is handed over (a round of the pass that is followed by others).
    func upload(_ work: [BackupResource], settings: BackupSettings, drain: Bool = true) async throws -> Waiting? {
        backgroundStop = nil
        retake = []
        if !missingChecked {
            missingChecked = true
            await checkForMissingUploads()
        }
        // Large files of earlier passes whose next chunks nobody handed over (the app had no time, or no connection).
        await driveChunkedUploads()
        // What the system reported while the server was asked is done already. Earlier rounds of the pass count too.
        let base = passUploads
        progress = (base.done + work.count { settled.contains(LedgerKey($0)) }, base.done + work.count + base.later, "")
        defer {
            passUploads.done = progress?.done ?? passUploads.done
            progress = nil
        }
        publishProgress()
        var heldVideos: BackupPause?
        var heldForICloud = false
        let order = BackupPolicy.uploadOrder(work, backgroundLimit: background?.maxFileSize)
        var queue = order.first + order.last
        /// Resources the app sends itself, after everything the system can take.
        var large = Set(order.last.map { LedgerKey($0) })
        /// Exports that turned out too large for the system while smaller files were still waiting.
        var postponed: [LedgerKey: (resource: BackupResource, file: URL)] = [:]
        defer {
            // The pass ended before it got to them: the next one does not have to read them again.
            for (resource, file) in postponed.values { keepOrDiscard(file, of: resource, settings: settings, keep: true) }
        }
        var nameAttempts: [LedgerKey: Int] = [:]
        var index = 0
        while true {
            try Task.checkCancellation()
            try throwBackgroundStop()
            if !retake.isEmpty {
                // Their name was taken meanwhile: once more, with a new look at what is there.
                for resource in retake { nameAttempts[LedgerKey(resource), default: 0] += 1 }
                queue.insert(contentsOf: retake, at: index)
                retake = []
            }
            guard index < queue.count else {
                // The pass is through when the system is.
                guard drain, activeBackgroundUploads > 0 else { break }
                try await waitForBackgroundUploads()
                if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
                if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
                continue
            }
            let resource = queue[index]
            let key = LedgerKey(resource)
            index += 1
            if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
            if resource.mediaKind == .video, let reason = pauseReason(settings, isVideo: true) {
                // Photos go on while the videos wait for Wi-Fi.
                heldVideos = reason
                continue
            }
            // With the system since an earlier pass, or reported by it since this one started.
            if journal?.isHandedOver(resource) == true || settled.contains(key) { continue }
            // PhotoKit sends it (the background-upload extension created a job for it).
            if UploadJobJournal.claims(at: uploadJobs).keys.contains(key) { continue }
            // The system has to have room for a file it will take: a small one, or the chunks of a large one.
            while large.contains(key) ? chunkedIsFull : backgroundIsFull(adding: resource) {
                try await waitForBackgroundUploads()
                if let reason = pauseReason(settings, isVideo: false) { return Waiting(reason: reason) }
                if let reason = await takeBackHeldVideos(settings) { heldVideos = reason }
            }
            progress?.current = resource.originalName
            publishProgress()
            var file: URL? = postponed.removeValue(forKey: key)?.file
            var handedOver = false
            var keep = false
            defer { if let file { keepOrDiscard(file, of: resource, settings: settings, keep: keep) } }
            let mayDownload = BackupPolicy.allowsICloudDownload(settings, network: network)
            do {
                if nameAttempts[key, default: 0] > Self.maxNameAttempts { throw NetworkError.preconditionFailed }
                let exported: URL
                if let file {
                    exported = file
                } else if let kept = keptExport(of: resource, settings: settings) {
                    exported = kept
                    file = kept
                } else {
                    // Before anything is written: a full device is not this file's fault, and the next one would not fit either.
                    guard BackupPolicy.hasRoom(free: freeSpace(), size: MostCompatible.spaceNeeded(resource, settings: settings)) else {
                        throw BackupDeviceError.outOfSpace
                    }
                    var written = try await library.export(resource, settings: settings, allowNetwork: mayDownload)
                    file = written
                    if MostCompatible.mayConvert(resource, settings: settings) {
                        // JPEG / H.264 next to the export, in the same directory: removed with it.
                        written = try await convert(written, resource)
                        file = written
                    }
                    exported = written
                }
                let conflict = BackupPolicy.conflictPolicy(resource, settings: settings)
                let name = BackupNaming.fileName(
                    originalName: resource.originalName, fileExtension: exported.pathExtension, isVideo: resource.mediaKind == .video,
                    date: resource.createdAt, naming: settings.naming)
                let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: resource.createdAt)
                // Layer 5: an existing file with the same name and size counts as uploaded; otherwise " (2)".
                if let background, Self.size(of: exported) <= background.maxFileSize {
                    handedOver = try await handOver(
                        resource, file: exported, fileName: name, folder: folder, settings: settings, conflict: conflict)
                } else if background != nil, !large.contains(key), queue[index...].contains(where: { !large.contains(LedgerKey($0)) }) {
                    // Larger than PhotoKit said (or it did not say): after the files the system can take, like the others.
                    large.insert(key)
                    postponed[key] = (resource, exported)
                    file = nil
                    queue.append(resource)
                    continue
                } else if background != nil {
                    // In chunks, each one a request of the system's: it goes on while the app is suspended (SPEC §7.18.6).
                    handedOver = try await handOverChunked(
                        resource, file: exported, fileName: name, folder: folder, settings: settings, conflict: conflict)
                } else {
                    let uploaded = try await remote.upload(
                        file: exported, fileName: name, folder: folder, capturedAt: resource.createdAt, conflict: conflict)
                    try await completed(resource, uploaded: uploaded)
                }
            } catch BackupDeviceError.needsICloudDownload where !mayDownload {
                if settings.downloadFromICloud {
                    // It waits for Wi-Fi; that is not a failure.
                    heldForICloud = true
                    continue
                }
                // The user does not want downloads from iCloud: left out until that changes.
                try record(resource, state: .skipped, error: BackupDeviceError.needsICloudDownload.localizedDescription)
            } catch {
                // An upload that was interrupted goes on with the same file (a large one is expensive to read again).
                keep = Task.isCancelled || BackupPolicy.isCancellation(error) || (error as? NetworkError)?.isTransient == true
                // The user's pause is not a failure of this file.
                if Task.isCancelled { throw CancellationError() }
                if let stop = uploadFailed(resource, error: error) { throw stop }
            }
            // An upload that is with the system now is counted when the system reports it.
            if handedOver { continue }
            progress?.done += 1
            try? refreshCounts()
        }
        try throwBackgroundStop()
        if let heldVideos { return Waiting(reason: heldVideos, videosOnly: true, needsICloud: heldForICloud) }
        return heldForICloud ? Waiting(reason: .iCloud, needsICloud: true) : nil
    }

    /// How often a pass prepares an upload again whose name was taken between the name check and the PUT.
    static let maxNameAttempts = 3

    /// The upload of a resource arrived: remembers it, links Live Photo halves, puts the file into the local index.
    func completed(_ resource: BackupResource, uploaded: UploadedFile) async throws {
        try record(resource, state: .uploaded, matchedBy: .ownUpload, serverPath: uploaded.path, serverFileId: uploaded.fileId)
        status.uploaded += 1
        status.uploadedThisPass += 1
        await linkLivePhoto(resource, uploaded: uploaded)
        await remote.didUpload(uploaded, resource: resource, metadataEditing: metadataEditing)
    }

    /// Deals with the failed upload of one resource. Returns the error that ends the pass, or nil when the pass goes on
    /// (the failure is then recorded and the resource backs off).
    func uploadFailed(_ resource: BackupResource, error: any Error) -> (any Error)? {
        if BackupPolicy.isCancellation(error) { return CancellationError() }
        if let error = error as? NetworkError, BackupPolicy.endsPass(error) { return error }
        logger.error("backup of \(resource.originalName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
        let blocker = BackupPolicy.blocker(for: error)
        // A full quota or a refusal may concern this file only (too big, blocked type): it backs off like any
        // failed file, so the next run starts with another one. A lost login or certificate says nothing about the file.
        // Nor does a full device.
        if blocker != .unauthorized, blocker != .serverTrust, blocker != .deviceStorageFull {
            try? record(resource, state: .failed, error: error.localizedDescription)
        }
        return blocker != nil ? error : nil
    }

    static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
