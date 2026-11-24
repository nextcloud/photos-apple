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

/// Remembers the upload folders an uploader left on the server for a later attempt, so that those nobody continues can be
/// removed again. The server cannot be asked: it does not list `uploads/<user>` ("Listing members of this collection is disabled").
public protocol UploadFolderRegistry: Sendable {
    /// An upload folder was created or continued.
    func touch(_ name: String, at date: Date)
    func remove(_ name: String)
    /// Folder names with the time they were last used.
    func entries() -> [String: Date]
}

/// Uploads files into the user's files with WebDAV (small files) or chunking v2 (SPEC §7.17).
///
/// Every request is repeated after a transient failure (`retry`). A chunked upload that still fails keeps its upload folder
/// on the server; the next attempt for the same file and destination finds it and continues with the first missing chunk.
public struct Uploader: Sendable {
    public private(set) var dav: DAVClient
    /// Files above this size are uploaded in chunks.
    public var chunkThreshold: Int64 = 10 * 1024 * 1024
    public var chunkSize: Int = 10 * 1024 * 1024
    /// Repeats single requests (a PUT, a chunk, a lookup) after timeouts, lost connections, 5xx and 429.
    public var retry: RetryPolicy? {
        get { dav.retry }
        set { dav.retry = newValue }
    }

    /// Where kept upload folders are remembered for `removeStaleUploads`. Without it the server's own expiry removes them.
    public var folders: (any UploadFolderRegistry)?

    public init(dav: DAVClient, retry: RetryPolicy? = .uploads) {
        self.dav = dav
        self.dav.retry = retry
    }

    var connection: ServerConnection { dav.connection }

    public enum ConflictPolicy: Sendable, Equatable {
        /// Append " (2)", " (3)"… (manual upload).
        case rename
        /// Treat an existing file with the same size as already uploaded (backup).
        case skipIfSameSize
        /// Also treat an existing file as already uploaded when its modification time is this capture time (± 1 s): a
        /// converted file (JPEG, H.264) is not the same bytes each time it is converted, but its name and the capture time
        /// the upload sets (`X-OC-MTime`) are (backup with "Most compatible").
        case skipIfSameSizeOrTime(Date)

        func isSameFile(size: Int64, existingSize: Int64?, existingModified: Date?) -> Bool {
            switch self {
            case .rename: false
            case .skipIfSameSize: existingSize == size
            case .skipIfSameSizeOrTime(let capturedAt):
                existingSize == size || existingModified.map { abs($0.timeIntervalSince(capturedAt)) <= 1 } == true
            }
        }
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
        var attempt = 1
        while true {
            let target: Target
            switch try await resolve(
                file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict, checksum: checksum, reserved: []
            )
            {
            case .existing(let existing): return existing
            case .free(let free): target = free
            }
            do {
                let response: HTTPResponse
                if target.size > chunkThreshold {
                    response = try await uploadChunked(
                        file: file, size: target.size, path: target.path, headers: target.headers,
                        fingerprint: target.digest ?? Self.fingerprint(of: file), progress: progress)
                } else {
                    do {
                        response = try await dav.put(connection.filesURL(target.path), file: file, headers: target.newFileHeaders)
                    } catch NetworkError.conflict {
                        try await dav.mkcolRecursive(userPath: folder)
                        response = try await dav.put(connection.filesURL(target.path), file: file, headers: target.newFileHeaders)
                    }
                    progress?(1)
                }
                return try await finish(path: target.path, response: response)
            } catch NetworkError.preconditionFailed where attempt < Self.maxNameAttempts {
                // The name was taken after it was found free (`If-None-Match: *`, `Overwrite: F`): nothing was overwritten.
                // A file of the same size there is this upload (its answer got lost, or another device was faster);
                // anything else gets the next free name.
                attempt += 1
                if let existing = try await existingFile(at: target.path, size: target.size) { return existing }
            }
        }
    }

    /// How often an upload looks for a free name again after the server said the name was taken meanwhile.
    static let maxNameAttempts = 3

    /// The file at `path` when it has this size.
    public func existingFile(at path: String, size: Int64) async throws -> UploadedFile? {
        do {
            let existing = try await dav.propfind(
                connection.filesURL(path), depth: 0, properties: [DAVProp.fileId, DAVProp.size, DAVProp.etag]
            ).first
            guard let existing, existing.int64(DAVProp.size) == size, let fileId = existing.int64(DAVProp.fileId) else { return nil }
            return UploadedFile(fileId: fileId, path: path, etag: existing.string(DAVProp.etag))
        } catch NetworkError.notFound {
            return nil
        }
    }

    /// Where a file goes and what is sent with it.
    struct Target {
        var path: String
        var size: Int64
        var headers: [String: String]
        var digest: String?

        /// The headers of the PUT that creates the file. `If-None-Match: *` makes the server refuse it (412) when a file
        /// with this name appeared after the name was found free, instead of overwriting that file.
        var newFileHeaders: [String: String] {
            headers.merging(["If-None-Match": "*"]) { $1 }
        }
    }

    enum Resolved {
        case existing(UploadedFile)
        case free(Target)
    }

    /// The lookups before an upload: the folder exists, and the name is free (or the file is there already).
    func resolve(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: ConflictPolicy, checksum: Bool, reserved: Set<String>
    ) async throws -> Resolved {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return try await resolve(
            size: size, checksumOf: checksum ? file : nil, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict,
            reserved: reserved)
    }

    /// The same for data of a known size that is not in a file here (PhotoKit sends it): without `checksumOf` no
    /// `OC-Checksum` is sent.
    func resolve(
        size: Int64, checksumOf file: URL?, fileName: String, folder: String, capturedAt: Date?, conflict: ConflictPolicy,
        reserved: Set<String>
    ) async throws -> Resolved {
        try await ensureFolder(folder)
        let name = try await freeName(fileName, in: folder, size: size, conflict: conflict, reserved: reserved)
        if case .existing(let existing) = name { return .existing(existing) }
        guard case .free(let targetName) = name else { throw NetworkError.conflict }
        let path = (folder.hasSuffix("/") ? folder : folder + "/") + targetName
        var headers: [String: String] = ["X-NC-WebDAV-Auto-Mkcol": "1"]
        if let capturedAt {
            let seconds = String(Int64(capturedAt.timeIntervalSince1970))
            headers["X-OC-MTime"] = seconds
            headers["X-OC-CTime"] = seconds
        }
        let digest = file.flatMap { try? Self.sha256(of: $0) }
        if let digest { headers["OC-Checksum"] = "SHA256:\(digest)" }
        return .free(Target(path: path, size: size, headers: headers, digest: digest))
    }

    // MARK: Uploads someone else sends (background transfers)

    /// An upload that is ready to be sent as one PUT.
    public enum Prepared: Sendable {
        /// A file with this name and size is there already (`ConflictPolicy.skipIfSameSize`).
        case existing(UploadedFile)
        /// Send `request` with the file as its body, then pass the answer to `finish(path:response:)`. The request does
        /// not overwrite: when the name was taken meanwhile, the answer is 412 (`NetworkError.preconditionFailed`) and
        /// the upload has to be prepared again.
        case put(path: String, request: HTTPRequest)
    }

    /// Does the lookups of an upload and returns the PUT request instead of sending it, for a background transfer session
    /// that sends the file while the app is suspended.
    ///
    /// - Parameter reserved: destination paths that count as taken although nothing is there yet: uploads still on their way.
    public func prepare(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: ConflictPolicy = .rename, checksum: Bool = true,
        reserved: Set<String> = []
    ) async throws -> Prepared {
        switch try await resolve(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict, checksum: checksum,
            reserved: reserved)
        {
        case .existing(let existing): return .existing(existing)
        case .free(let target):
            let request = HTTPRequest(
                method: "PUT", url: connection.filesURL(target.path), headers: dav.headers(target.newFileHeaders), timeout: 3600)
            return .put(path: target.path, request: request)
        }
    }

    /// The same for data of a known size that someone else reads and sends (the PhotoKit background-upload extension):
    /// no `OC-Checksum`, the data is not read here.
    public func prepare(
        size: Int64, fileName: String, folder: String, capturedAt: Date?, conflict: ConflictPolicy = .rename, reserved: Set<String> = []
    ) async throws -> Prepared {
        switch try await resolve(
            size: size, checksumOf: nil, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict,
            reserved: reserved)
        {
        case .existing(let existing): return .existing(existing)
        case .free(let target):
            let request = HTTPRequest(
                method: "PUT", url: connection.filesURL(target.path), headers: dav.headers(target.newFileHeaders), timeout: 3600)
            return .put(path: target.path, request: request)
        }
    }

    /// A chunked upload that is ready to be handed to a background transfer session (`ChunkedUpload`).
    public enum PreparedChunked: Sendable {
        /// A file with this name and size is there already.
        case existing(UploadedFile)
        /// The upload folder exists; hand over what `ChunkedUpload.next` says.
        case chunked(ChunkedUpload)
    }

    /// Does the lookups of a large upload and creates its upload folder (or finds what an earlier attempt sent there),
    /// for a background transfer session that sends the chunks while the app is suspended (SPEC §7.18.6). The upload
    /// folder is the one `upload` would use for the same file and destination.
    ///
    /// - Parameter reserved: destination paths that count as taken although nothing is there yet: uploads still on their way.
    public func prepareChunked(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: ConflictPolicy = .rename, checksum: Bool = true,
        reserved: Set<String> = []
    ) async throws -> PreparedChunked {
        let target: Target
        switch try await resolve(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict, checksum: checksum,
            reserved: reserved)
        {
        case .existing(let existing): return .existing(existing)
        case .free(let free): target = free
        }
        let chunkSize = effectiveChunkSize(for: target.size)
        let uploadFolder = uploadFolder(
            path: target.path, size: target.size, chunkSize: chunkSize, fingerprint: target.digest ?? Self.fingerprint(of: file))
        var upload = ChunkedUpload(
            id: UUID().uuidString, path: target.path, size: target.size, chunkSize: chunkSize, folder: uploadFolder,
            destination: connection.filesURL(target.path), headers: target.headers)
        try await openFolder(&upload)
        return .chunked(upload)
    }

    /// Creates the upload folder of a chunked upload, or lists the chunks an earlier attempt left in it.
    public func openFolder(_ upload: inout ChunkedUpload) async throws {
        folders?.touch(upload.folder.lastPathComponent, at: Date())
        var existing: [Int: Int64] = [:]
        do {
            try await dav.send("MKCOL", upload.folder, headers: upload.commonHeaders)
        } catch NetworkError.conflict {
            // 405: the folder of an earlier attempt.
            existing = try await existingChunks(in: upload.folder)
        }
        upload.folderReady(existing: existing)
    }

    /// The request of one step of a chunked upload, to be sent by a background transfer session: a chunk's `PUT` (the
    /// chunk's bytes are the body) or the final `MOVE` (with an empty body). The `MOVE` does not overwrite: a file that
    /// appeared at the destination meanwhile makes it fail with 412.
    public func request(for step: ChunkedUpload.Step, of upload: ChunkedUpload) -> HTTPRequest {
        switch step {
        case .chunk(let number):
            return HTTPRequest(
                method: "PUT", url: upload.folder.appending(path: String(number)), headers: dav.headers(upload.commonHeaders),
                timeout: 3600)
        case .assemble:
            var headers = upload.headers.merging(upload.commonHeaders) { $1 }
            headers["Overwrite"] = "F"
            return HTTPRequest(
                method: "MOVE", url: upload.folder.appending(path: ".file"), headers: dav.headers(headers), timeout: 3600)
        }
    }

    /// The file at the destination of a chunked upload, when it has the upload's size: the server put it together
    /// although the answer to the `MOVE` got lost.
    public func assembledFile(of upload: ChunkedUpload) async throws -> UploadedFile? {
        try await existingFile(at: upload.path, size: upload.size)
    }

    /// Turns the answer to the `MOVE` of a chunked upload into the uploaded file.
    public func finish(_ upload: ChunkedUpload, status: Int, headers: [String: String]) async throws -> UploadedFile {
        let uploaded = try await finish(path: upload.path, response: HTTPResponse(status: status, headers: headers))
        folders?.remove(upload.folder.lastPathComponent)
        return uploaded
    }

    /// A chunked upload is given up: its chunks are removed, unless a later attempt can still continue them
    /// (`keepsUploadFolder`). Best effort.
    public func abandon(_ upload: ChunkedUpload, after error: (any Error)?) async {
        if let error, Self.keepsUploadFolder(after: error) { return }
        var once = dav
        once.retry = nil
        try? await once.delete(upload.folder)
        folders?.remove(upload.folder.lastPathComponent)
    }

    /// Turns the answer to an upload's last request into the uploaded file; throws what the answer's status stands for.
    public func finish(path: String, response: HTTPResponse) async throws -> UploadedFile {
        if let error = NetworkError.from(status: response.status, data: response.data) {
            if error == .unauthorized { dav.onUnauthorized?() }
            throw error
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

    /// - Parameter reserved: paths that count as taken without asking the server (uploads on their way).
    func freeName(_ fileName: String, in folder: String, size: Int64, conflict: ConflictPolicy, reserved: Set<String> = [])
        async throws -> NameResult
    {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var counter = 2
        while true {
            let path = (folder.hasSuffix("/") ? folder : folder + "/") + candidate
            if !reserved.contains(path) {
                let existing: DAVResource?
                do {
                    existing = try await dav.propfind(
                        connection.filesURL(path), depth: 0, properties: [DAVProp.fileId, DAVProp.size, DAVProp.etag, DAVProp.lastModified]
                    ).first
                } catch NetworkError.notFound {
                    return .free(candidate)
                }
                if let existing,
                    conflict.isSameFile(
                        size: size, existingSize: existing.int64(DAVProp.size), existingModified: existing.httpDate(DAVProp.lastModified)),
                    let fileId = existing.int64(DAVProp.fileId)
                {
                    return .existing(UploadedFile(fileId: fileId, path: path, etag: existing.string(DAVProp.etag)))
                }
            }
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
            if counter > 1000 { throw NetworkError.conflict }
        }
    }

    // MARK: Chunked upload

    /// Upload folders of this app start with this (`uploads/<user>/photos-<key>`).
    static let uploadFolderPrefix = "photos-"

    /// Chunking v2 allows 10 000 chunks; very large files get bigger chunks.
    func effectiveChunkSize(for size: Int64) -> Int {
        max(chunkSize, Int((size + 9_999) / 10_000))
    }

    /// The same file going to the same place always uses the same upload folder, so an interrupted upload is found again.
    /// The chunk size is part of the key: chunks of another size could not be continued.
    static func uploadKey(path: String, size: Int64, chunkSize: Int, fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data("\(path)|\(size)|\(chunkSize)|\(fingerprint)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Stands in for the checksum when none is computed: size and modification time.
    static func fingerprint(of file: URL) -> String {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func uploadFolder(path: String, size: Int64, chunkSize: Int, fingerprint: String) -> URL {
        let key = Self.uploadKey(path: path, size: size, chunkSize: chunkSize, fingerprint: fingerprint)
        return connection.davURL("uploads/\(connection.userId)/\(Self.uploadFolderPrefix)\(key)/")
    }

    /// Chunking v2: MKCOL upload folder, PUT numbered chunks, MOVE `.file` to the destination.
    ///
    /// The upload folder stays on the server when the upload stops for a reason that does not rule out a later attempt
    /// (`keepsUploadFolder`), and that attempt continues it.
    func uploadChunked(
        file: URL, size: Int64, path: String, headers: [String: String], fingerprint: String, progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPResponse {
        let chunkSize = effectiveChunkSize(for: size)
        let folder = uploadFolder(path: path, size: size, chunkSize: chunkSize, fingerprint: fingerprint)
        let name = folder.lastPathComponent
        folders?.touch(name, at: Date())
        var restarted = false
        while true {
            do {
                let response = try await sendChunks(
                    file: file, size: size, chunkSize: chunkSize, path: path, folder: folder, headers: headers, progress: progress)
                folders?.remove(name)
                return response
            } catch NetworkError.notFound where !restarted {
                // The server removed the upload folder in the middle (it expires unfinished uploads): once more from the start.
                restarted = true
            } catch {
                if !Self.keepsUploadFolder(after: error) {
                    try? await dav.delete(folder)
                    folders?.remove(name)
                }
                throw error
            }
        }
    }

    private func sendChunks(
        file: URL, size: Int64, chunkSize: Int, path: String, folder: URL, headers: [String: String],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPResponse {
        let common = ["Destination": connection.filesURL(path).absoluteString, "OC-Total-Length": String(size)]
        var existing: [Int: Int64] = [:]
        do {
            try await dav.send("MKCOL", folder, headers: common)
        } catch NetworkError.conflict {
            // 405: the folder of an earlier attempt.
            existing = try await existingChunks(in: folder)
        }
        let count = Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
        func length(of index: Int) -> Int64 { index < count ? Int64(chunkSize) : size - Int64(count - 1) * Int64(chunkSize) }
        // Continue with the first chunk that is missing or incomplete; later ones are sent again.
        var index = 1
        while index <= count, existing[index] == length(of: index) { index += 1 }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent = Int64(index - 1) * Int64(chunkSize)
        try handle.seek(toOffset: UInt64(sent))
        if sent > 0 { progress?(Double(sent) / Double(max(size, 1)) * 0.98) }
        while index <= count {
            try Task.checkCancellation()
            let expected = Int(length(of: index))
            guard let chunk = try handle.read(upToCount: expected), chunk.count == expected else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: file])
            }
            _ = try await dav.put(folder.appending(path: String(index)), data: chunk, headers: common)
            sent += Int64(chunk.count)
            progress?(Double(sent) / Double(max(size, 1)) * 0.98)
            index += 1
        }
        var moveHeaders = headers.merging(common) { $1 }
        moveHeaders["Overwrite"] = "F"
        let response = try await assemble(folder: folder, path: path, size: size, headers: moveHeaders)
        progress?(1)
        return response
    }

    /// Sizes of the chunks an earlier attempt left in the upload folder, by chunk number.
    func existingChunks(in folder: URL) async throws -> [Int: Int64] {
        let resources = try await dav.propfind(folder, depth: 1, properties: [DAVProp.contentLength, DAVProp.size])
        var chunks: [Int: Int64] = [:]
        for resource in resources {
            guard let number = Int(resource.lastPathComponent), number > 0 else { continue }
            chunks[number] = resource.int64(DAVProp.contentLength) ?? resource.int64(DAVProp.size)
        }
        return chunks
    }

    /// The final MOVE. It is not simply sent again after a transient failure: the server may have assembled the file
    /// although its answer got lost, and a second MOVE would then fail. So the destination is looked at first.
    private func assemble(folder: URL, path: String, size: Int64, headers: [String: String]) async throws -> HTTPResponse {
        var once = dav
        once.retry = nil
        var attempt = 1
        while true {
            do {
                return try await once.send("MOVE", folder.appending(path: ".file"), headers: headers, timeout: 1800)
            } catch let error as NetworkError where RetryPolicy.isRetryable(error) || (error == .notFound && attempt > 1) {
                let destination = try? await dav.propfind(connection.filesURL(path), depth: 0, properties: [DAVProp.size]).first
                // Without the `OC-FileId` of the lost answer; `upload` asks for the file id.
                if let destination, destination.int64(DAVProp.size) == size { return HTTPResponse(status: 201) }
                guard error != .notFound, let retry, let delay = retry.delay(afterAttempt: attempt) else { throw error }
                do {
                    try await retry.sleep(delay)
                } catch {
                    throw NetworkError.cancelled
                }
                attempt += 1
            }
        }
    }

    /// Whether a failed chunked upload can still be continued later: after a transient failure, a pause, or a problem
    /// with the login or the connection's trust. Anything else (refused, no space, bad request, unreadable file) will
    /// not get better, and the chunks are removed.
    static func keepsUploadFolder(after error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? NetworkError else { return false }
        switch error {
        case .cancelled, .unauthorized, .untrustedCertificate, .clientCertificateRequired, .locked: return true
        default: return error.isTransient
        }
    }

    /// Unfinished uploads are kept for this long, like the server does it itself.
    public static let staleUploadAge: TimeInterval = 24 * 3600

    /// Removes the remembered upload folders (`folders`) that have not been used for a while: uploads that were never
    /// continued because the file was deleted on the device, renamed, or converted differently. Best effort; returns how
    /// many were removed.
    @discardableResult
    public func removeStaleUploads(olderThan age: TimeInterval = Uploader.staleUploadAge, now: Date = Date()) async -> Int {
        guard let folders else { return 0 }
        var once = dav
        once.retry = nil
        var removed = 0
        for (name, used) in folders.entries() where now.timeIntervalSince(used) > age && name.hasPrefix(Self.uploadFolderPrefix) {
            do {
                try await once.delete(connection.davURL("uploads/\(connection.userId)/\(name)/"))
                removed += 1
            } catch NetworkError.notFound {
                // The server was faster.
            } catch {
                continue
            }
            folders.remove(name)
        }
        return removed
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
