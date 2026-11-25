// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

/// A new capture time and/or position for one photo (SPEC §16.4 batch fixes, GPX geotagging).
public struct MetadataEdit: Hashable, Sendable {
    public var fileId: FileID
    public var capturedAt: Date?
    /// The UTC offset of `capturedAt` (written into the file where the file is rewritten).
    public var offset: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var removeLocation: Bool

    public init(
        fileId: FileID, capturedAt: Date? = nil, offset: Int? = nil, latitude: Double? = nil, longitude: Double? = nil,
        altitude: Double? = nil, removeLocation: Bool = false
    ) {
        self.fileId = fileId
        self.capturedAt = capturedAt
        self.offset = offset
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.removeLocation = removeLocation
    }

    public var changesDate: Bool { capturedAt != nil }
    public var changesLocation: Bool { removeLocation || (latitude != nil && longitude != nil) }

    /// The edit that puts back what `item` has now, for the parts this edit changes.
    public func inverse(of item: MediaItem) -> MetadataEdit {
        var undo = MetadataEdit(fileId: fileId)
        if changesDate {
            undo.capturedAt = item.timestamp
            undo.offset = item.captureOffset
        }
        if changesLocation {
            if item.hasLocation {
                undo.latitude = item.latitude
                undo.longitude = item.longitude
                undo.altitude = item.altitude
            } else {
                undo.removeLocation = true
            }
        }
        return undo
    }
}

/// What a batch fix did, with what puts it back.
public struct BatchFixResult: Sendable {
    public enum Undo: Sendable {
        case metadata([MetadataEdit])
        case rename([FileID: String])
    }

    public var changed: Int
    /// File name and why, for photos that were not changed.
    public var problems: [(name: String, reason: String)]
    public var undo: Undo?
    /// Changes were written into the files (new versions) rather than as server metadata.
    public var rewroteFiles: Bool

    public init(changed: Int = 0, problems: [(name: String, reason: String)] = [], undo: Undo? = nil, rewroteFiles: Bool = false) {
        self.changed = changed
        self.problems = problems
        self.undo = undo
        self.rewroteFiles = rewroteFiles
    }
}

/// Why a batch fix skipped a photo.
public enum BatchFixProblem: LocalizedError, Sendable {
    case readOnly
    case unsupportedFormat
    case changedOnServer
    case nameTaken

    public var errorDescription: String? {
        switch self {
        case .readOnly: String(localized: "Shared with you without permission to change it.", bundle: .module)
        case .unsupportedFormat:
            String(
                localized: "This server can't change the date or place of this kind of file. Nextcloud 35 or later can.",
                bundle: .module)
        case .changedOnServer: String(localized: "Changed on the server in the meantime. Try again after the next sync.", bundle: .module)
        case .nameTaken: String(localized: "Another file in the folder already has this name.", bundle: .module)
        }
    }
}

extension SessionModel {
    static let organizeLogger = Logger(subsystem: "com.nextcloud.photos", category: "organize")

    /// How batch fixes write capture time and position on this server: as server metadata (Nextcloud 35+, through the
    /// outbox) or into the files themselves (new versions).
    public var writesMetadataIntoFiles: Bool { !features.has(.metadataEdit) }

    /// Whether a batch date or place fix can change this photo.
    public func metadataProblem(_ item: MediaItem) -> BatchFixProblem? {
        if !item.permissions.canWrite || item.isCollectionChild { return .readOnly }
        if writesMetadataIntoFiles && (item.kind != .image || !MetadataRewriter.canRewrite(fileName: item.name)) {
            return .unsupportedFormat
        }
        return nil
    }

    /// Applies capture time and position changes (SPEC §16.4). With metadata editing on the server they go through the
    /// outbox (optimistic, offline-safe); without it each photo is downloaded, its metadata rewritten and uploaded as a
    /// new version with `If-Match`, so a newer version on the server is never replaced.
    public func applyMetadataEdits(_ edits: [MetadataEdit], progress: (@MainActor (Int, Int) -> Void)? = nil) async -> BatchFixResult {
        guard let services, !edits.isEmpty else { return BatchFixResult() }
        let items = (try? services.library.items(edits.map(\.fileId))) ?? [:]
        var result = BatchFixResult(rewroteFiles: writesMetadataIntoFiles)
        var applicable: [(MetadataEdit, MediaItem)] = []
        for edit in edits {
            guard let item = items[edit.fileId] else { continue }
            if let problem = metadataProblem(item) {
                result.problems.append((item.name, problem.localizedDescription))
            } else {
                applicable.append((edit, item))
            }
        }
        let undo = applicable.map { $0.0.inverse(of: $0.1) }
        if !writesMetadataIntoFiles {
            await enqueue(
                applicable.map { edit, item in
                    .setMetadata(
                        fileId: item.fileId, path: item.path, capturedAt: edit.capturedAt, latitude: edit.latitude,
                        longitude: edit.longitude, removeLocation: edit.removeLocation)
                })
            // The outbox keeps no offset; the index shows the photo in the new zone until the next full read.
            for (edit, _) in applicable where edit.changesDate {
                let offset = edit.offset
                try? services.library.update(edit.fileId) { $0.captureOffset = offset }
            }
            result.changed = applicable.count
            result.undo = .metadata(undo)
            progress?(applicable.count, applicable.count)
            return result
        }
        // Into the files: three at a time.
        var done = 0
        var succeeded: [FileID] = []
        await withTaskGroup(of: (FileID, String, (any Error)?).self) { group in
            var iterator = applicable.makeIterator()
            func addNext() {
                guard let (edit, item) = iterator.next() else { return }
                group.addTask { (item.fileId, item.name, await Self.rewriteFile(item, edit: edit, services: services)) }
            }
            for _ in 0..<3 { addNext() }
            for await (fileId, name, error) in group {
                done += 1
                progress?(done, applicable.count)
                if let error {
                    result.problems.append((name, error.localizedDescription))
                } else {
                    succeeded.append(fileId)
                }
                addNext()
            }
        }
        result.changed = succeeded.count
        let succeededSet = Set(succeeded)
        result.undo = .metadata(undo.filter { succeededSet.contains($0.fileId) })
        if !succeeded.isEmpty { await syncNow() }
        return result
    }

    /// One photo: download, rewrite, upload over the version the index knows, update the index.
    nonisolated static func rewriteFile(_ item: MediaItem, edit: MetadataEdit, services: AccountServices) async -> (any Error)? {
        do {
            let original = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
            let directory = FileManager.default.temporaryDirectory.appending(path: "BatchFix/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let change = MetadataRewriter.Change(
                capturedAt: edit.capturedAt, offset: edit.offset, latitude: edit.latitude, longitude: edit.longitude,
                altitude: edit.altitude,
                removeLocation: edit.removeLocation)
            guard let rewritten = MetadataRewriter.rewrite(original, with: change, in: directory) else {
                return BatchFixProblem.unsupportedFormat
            }
            var headers: [String: String] = [:]
            if !item.etag.isEmpty { headers["If-Match"] = "\"\(item.etag)\"" }
            let response: HTTPResponse
            do {
                response = try await services.dav.put(services.connection.filesURL(item.path), file: rewritten, headers: headers)
            } catch NetworkError.preconditionFailed {
                return BatchFixProblem.changedOnServer
            }
            let etag = AppDataFiles.etag(response)
            try? services.library.update(item.fileId) { row in
                if let capturedAt = edit.capturedAt {
                    row.capturedAt = capturedAt
                    row.captureOffset = edit.offset
                }
                if edit.removeLocation {
                    row.latitude = nil
                    row.longitude = nil
                    row.place = nil
                } else if let latitude = edit.latitude, let longitude = edit.longitude {
                    row.latitude = latitude
                    row.longitude = longitude
                }
                if !etag.isEmpty { row.etag = etag }
            }
            return nil
        } catch {
            return error
        }
    }

    /// Renames photos in their folders (MOVE with `If-Match`). The motion part of a Live Photo follows its photo.
    public func rename(_ names: [FileID: String], progress: (@MainActor (Int, Int) -> Void)? = nil) async -> BatchFixResult {
        guard let services, !names.isEmpty else { return BatchFixResult() }
        let items = (try? services.library.items(Array(names.keys))) ?? [:]
        var result = BatchFixResult()
        var undo: [FileID: String] = [:]
        var done = 0
        let ordered = names.sorted { $0.key < $1.key }
        for (fileId, newName) in ordered {
            done += 1
            progress?(done, ordered.count)
            guard let item = items[fileId], item.name != newName else { continue }
            guard item.permissions.canRename, item.isOwnStorage || item.permissions.canMove else {
                result.problems.append((item.name, BatchFixProblem.readOnly.localizedDescription))
                continue
            }
            do {
                try await move(item, to: newName, services: services)
                undo[fileId] = item.name
                result.changed += 1
                // The Live Photo's video gets the same name.
                if let peer = item.livePhotoPeer, let video = try? services.library.item(peer) {
                    let ext = (video.name as NSString).pathExtension
                    let base = (newName as NSString).deletingPathExtension
                    let videoName = ext.isEmpty ? base : "\(base).\(ext)"
                    if video.name != videoName, (try? await move(video, to: videoName, services: services)) != nil {
                        undo[peer] = video.name
                    }
                }
            } catch NetworkError.preconditionFailed {
                result.problems.append((item.name, BatchFixProblem.changedOnServer.localizedDescription))
            } catch NetworkError.conflict {
                result.problems.append((item.name, BatchFixProblem.nameTaken.localizedDescription))
            } catch {
                result.problems.append((item.name, error.localizedDescription))
            }
        }
        result.undo = .rename(undo)
        if result.changed > 0 { await syncNow() }
        return result
    }

    private func move(_ item: MediaItem, to newName: String, services: AccountServices) async throws {
        let destination = (item.directory as NSString).appendingPathComponent(newName)
        try await services.api.move(userPath: item.path, to: destination, ifMatch: item.etag.isEmpty ? nil : item.etag)
        try? services.library.update(item.fileId) { row in
            row.path = destination
            row.name = newName
        }
    }

    /// Puts back what a batch fix changed.
    public func undoBatchFix(_ undo: BatchFixResult.Undo) async -> BatchFixResult {
        switch undo {
        case .metadata(let edits): await applyMetadataEdits(edits)
        case .rename(let names): await rename(names)
        }
    }
}
