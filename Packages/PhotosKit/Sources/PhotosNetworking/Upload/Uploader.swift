// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhotosModel

/// The result of an upload.
public struct UploadedFile: Sendable, Hashable {
    public var fileId: FileID
    public var path: String
    public var etag: String?
}

/// Uploads files into the user's files with WebDAV (small files) or chunking v2 (SPEC §7.17).
public struct Uploader: Sendable {
    public let dav: DAVClient
    /// Files above this size are uploaded in chunks.
    public var chunkThreshold: Int64 = 10 * 1024 * 1024
    public var chunkSize: Int = 10 * 1024 * 1024

    public init(dav: DAVClient) {
        self.dav = dav
    }

    var connection: ServerConnection { dav.connection }

    public enum ConflictPolicy: Sendable {
        /// Append " (2)", " (3)"… (manual upload).
        case rename
        /// Treat an existing file with the same size as already uploaded (backup).
        case skipIfSameSize
    }

    /// Uploads a local file to `<folder>/<fileName>`.
    ///
    /// - Parameters:
    ///   - capturedAt: sent as `X-OC-MTime` / `X-OC-CTime`, so the server falls back to the capture time when it can't read EXIF.
    ///   - progress: fraction 0…1.
    public func upload(
        file: URL,
        fileName: String,
        folder: String,
        capturedAt: Date?,
        conflict: ConflictPolicy = .rename,
        checksum: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadedFile {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try await ensureFolder(folder)
        let name = try await freeName(fileName, in: folder, size: size, conflict: conflict)
        if case .existing(let existing) = name { return existing }
        guard case .free(let targetName) = name else { throw NetworkError.conflict }
        let path = (folder.hasSuffix("/") ? folder : folder + "/") + targetName
        var headers: [String: String] = ["X-NC-WebDAV-Auto-Mkcol": "1"]
        if let capturedAt {
            let seconds = String(Int64(capturedAt.timeIntervalSince1970))
            headers["X-OC-MTime"] = seconds
            headers["X-OC-CTime"] = seconds
        }
        if checksum, let digest = try? Self.sha256(of: file) { headers["OC-Checksum"] = "SHA256:\(digest)" }

        let response: HTTPResponse
        if size > chunkThreshold {
            response = try await uploadChunked(file: file, size: size, path: path, headers: headers, progress: progress)
        } else {
            do {
                response = try await dav.put(connection.filesURL(path), file: file, headers: headers)
            } catch NetworkError.conflict {
                try await dav.mkcolRecursive(userPath: folder)
                response = try await dav.put(connection.filesURL(path), file: file, headers: headers)
            }
            progress?(1)
        }
        if let fileId = Self.parseFileId(response.header("oc-fileid")) {
            return UploadedFile(fileId: fileId, path: path, etag: response.header("oc-etag") ?? response.header("etag"))
        }
        let resources = try await dav.propfind(connection.filesURL(path), depth: 0, properties: [DAVProp.fileId, DAVProp.etag])
        guard let fileId = resources.first?.int64(DAVProp.fileId) else { throw NetworkError.invalidResponse("upload without file id") }
        return UploadedFile(fileId: fileId, path: path, etag: resources.first?.string(DAVProp.etag))
    }

    /// Creates the destination folder when missing (chunked MOVE does not create parents).
    func ensureFolder(_ folder: String) async throws {
        do {
            _ = try await dav.propfind(connection.filesURL(folder), depth: 0, properties: [DAVProp.resourceType])
        } catch NetworkError.notFound {
            try await dav.mkcolRecursive(userPath: folder)
        }
    }

    enum NameResult {
        case free(String)
        case existing(UploadedFile)
    }

    func freeName(_ fileName: String, in folder: String, size: Int64, conflict: ConflictPolicy) async throws -> NameResult {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var counter = 2
        while true {
            let path = (folder.hasSuffix("/") ? folder : folder + "/") + candidate
            let existing: DAVResource?
            do {
                existing = try await dav.propfind(
                    connection.filesURL(path), depth: 0, properties: [DAVProp.fileId, DAVProp.size, DAVProp.etag]
                ).first
            } catch NetworkError.notFound {
                return .free(candidate)
            }
            if conflict == .skipIfSameSize, let existing, existing.int64(DAVProp.size) == size, let fileId = existing.int64(DAVProp.fileId)
            {
                return .existing(UploadedFile(fileId: fileId, path: path, etag: existing.string(DAVProp.etag)))
            }
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
            if counter > 1000 { throw NetworkError.conflict }
        }
    }

    /// Chunking v2: MKCOL upload folder, PUT numbered chunks, MOVE `.file` to the destination.
    func uploadChunked(file: URL, size: Int64, path: String, headers: [String: String], progress: (@Sendable (Double) -> Void)?)
        async throws
        -> HTTPResponse
    {
        let destination = connection.filesURL(path).absoluteString
        let uploadFolder = connection.davURL("uploads/\(connection.userId)/photos-\(UUID().uuidString)/")
        let common = ["Destination": destination, "OC-Total-Length": String(size)]
        try await dav.send("MKCOL", uploadFolder, headers: common)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var index = 1
        var sent: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                _ = try await dav.put(uploadFolder.appending(path: String(index)), data: chunk, headers: common)
                sent += Int64(chunk.count)
                progress?(Double(sent) / Double(max(size, 1)) * 0.98)
                index += 1
            }
            var moveHeaders = headers.merging(common) { $1 }
            moveHeaders["Overwrite"] = "F"
            let response = try await dav.send("MOVE", uploadFolder.appending(path: ".file"), headers: moveHeaders, timeout: 1800)
            progress?(1)
            return response
        } catch {
            try? await dav.delete(uploadFolder)
            throw error
        }
    }

    /// `OC-FileId` is the numeric id zero-padded and followed by the instance id, e.g. `00000123ocabcdef`.
    static func parseFileId(_ header: String?) -> FileID? {
        guard let header else { return nil }
        let digits = header.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : FileID(digits)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
