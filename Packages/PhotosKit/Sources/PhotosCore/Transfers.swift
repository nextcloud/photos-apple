// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// One manual upload (SPEC §7.17).
public struct Transfer: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case waiting
        case uploading(Double)
        case done(FileID)
        case failed(String)
    }

    public var id = UUID()
    public var fileName: String
    public var state: State = .waiting

    public var isFinished: Bool {
        switch state {
        case .done, .failed: true
        default: false
        }
    }
}

/// A local file to upload.
public struct UploadSource: Sendable {
    public var file: URL
    public var fileName: String
    public var capturedAt: Date?
    /// Motion part of a Live Photo, uploaded next to the still and linked.
    public var pairedVideo: URL?
    /// Delete the local file after upload (temporary copies).
    public var isTemporary: Bool

    public init(file: URL, fileName: String? = nil, capturedAt: Date? = nil, pairedVideo: URL? = nil, isTemporary: Bool = true) {
        self.file = file
        self.fileName = fileName ?? file.lastPathComponent
        self.capturedAt = capturedAt
        self.pairedVideo = pairedVideo
        self.isTemporary = isTemporary
    }
}

/// Queue of manual uploads with progress, used by pickers, drag and drop and the share extension.
@MainActor
@Observable
public final class TransferQueue {
    public private(set) var transfers: [Transfer] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "upload")
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending: [(UUID, UploadSource, String, Album?)] = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored weak var session: SessionModel?

    init() {}

    /// Stops uploading and waits until the running upload has stopped (account switch, removal). Uploads that had not
    /// finished are marked as failed and their temporary files are removed.
    func shutdown() async {
        let abandoned = pending
        pending = []
        for (id, source, _, _) in abandoned {
            update(id, .failed(String(localized: "Cancelled")))
            Self.removeTemporaryFiles(of: source)
        }
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
    }

    static func removeTemporaryFiles(of source: UploadSource) {
        guard source.isTemporary else { return }
        try? FileManager.default.removeItem(at: source.file)
        if let video = source.pairedVideo { try? FileManager.default.removeItem(at: video) }
    }

    public var activeCount: Int { transfers.filter { !$0.isFinished }.count }

    public var overallProgress: Double {
        let active = transfers.filter { !$0.isFinished }
        guard !active.isEmpty else { return 1 }
        let sum = active.reduce(0.0) { total, transfer in
            if case .uploading(let value) = transfer.state { return total + value }
            return total
        }
        return sum / Double(active.count)
    }

    public func clearFinished() { transfers.removeAll(where: \.isFinished) }

    /// Queues files for upload into `folder` (default: the Photos upload folder), optionally adding them to an own album.
    public func upload(_ sources: [UploadSource], to folder: String? = nil, album: Album? = nil) {
        guard let session else { return }
        let target = folder ?? session.features.userConfig.photosLocation
        for source in sources {
            let transfer = Transfer(fileName: source.fileName)
            transfers.append(transfer)
            pending.append((transfer.id, source, target, album))
        }
        if !running {
            running = true
            drainTask = Task { await drain() }
        }
    }

    private func update(_ id: UUID, _ state: Transfer.State) {
        if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].state = state }
    }

    private func drain() async {
        running = true
        defer { running = false }
        while !pending.isEmpty {
            let (id, source, folder, album) = pending.removeFirst()
            guard let session, let services = session.services else { return }
            let uploader = Uploader(dav: services.dav)
            update(id, .uploading(0))
            do {
                let still = try await uploader.upload(
                    file: source.file, fileName: source.fileName, folder: folder, capturedAt: source.capturedAt,
                    progress: { value in Task { @MainActor in self.update(id, .uploading(value)) } })
                var uploadedIds = [still.fileId]
                if let video = source.pairedVideo {
                    let videoName = (source.fileName as NSString).deletingPathExtension + ".MOV"
                    let motion = try await uploader.upload(file: video, fileName: videoName, folder: folder, capturedAt: source.capturedAt)
                    try? await services.api.linkLivePhoto(
                        imagePath: still.path, imageFileId: still.fileId, videoPath: motion.path, videoFileId: motion.fileId)
                    uploadedIds.append(motion.fileId)
                }
                // Show it immediately, before the next sync.
                if let items = try? await services.api.items(fileIds: uploadedIds, properties: DAVProp.mediaIndex) {
                    try? services.library.upsert(items)
                    if let album, let item = items.first(where: { $0.fileId == still.fileId }) {
                        try? await services.api.addToAlbum(album, userPath: item.path)
                        try? await session.refreshAlbumContent(album, force: true)
                    }
                }
                update(id, .done(still.fileId))
            } catch {
                logger.error("upload failed: \(error.localizedDescription, privacy: .public)")
                update(id, .failed(error.localizedDescription))
            }
            Self.removeTemporaryFiles(of: source)
        }
    }
}
