// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the app itself asks the server about a chunked upload that a background transfer session sends (`Uploader`; tests
/// use a fake).
public protocol ChunkedUploadServer: Sendable {
    /// Creates the upload folder, or lists the chunks an earlier attempt left in it.
    func openFolder(_ upload: inout ChunkedUpload) async throws
    /// The request of one step (a chunk's `PUT`, the final `MOVE`).
    func request(for step: ChunkedUpload.Step, of upload: ChunkedUpload) -> HTTPRequest
    /// The answer to the `MOVE` as the uploaded file.
    func finish(_ upload: ChunkedUpload, status: Int, headers: [String: String]) async throws -> UploadedFile
    /// The file at the destination when it has the upload's size.
    func assembledFile(of upload: ChunkedUpload) async throws -> UploadedFile?
    /// The upload is given up: removes its chunks unless a later attempt can continue them.
    func abandon(_ upload: ChunkedUpload, after error: (any Error)?) async
}

extension Uploader: ChunkedUploadServer {}

/// Sends chunked uploads (`ChunkedUpload`) through a background transfer session: writes each chunk into a file of its own
/// (a background upload needs a file), hands its request to the system, and when the system reports it, does what only the
/// app can do (create the upload folder again, look at the destination, read the file id) and hands over the next ones.
///
/// The caller keeps the state: `save` is called with every change before a request is started, so that a report the
/// system delivers to a later launch can be understood. The functions run on the caller's actor.
public struct ChunkedUploadDriver: Sendable {
    public var transport: any BackgroundUploading
    public var uploader: any ChunkedUploadServer
    /// Requests of one upload with the system at once; each has a chunk file of its own.
    public var window: Int

    public init(transport: any BackgroundUploading, uploader: any ChunkedUploadServer, window: Int = 8) {
        self.transport = transport
        self.uploader = uploader
        self.window = window
    }

    /// Where an upload's requests are, and which networks they may use.
    public struct Files: Sendable {
        /// The whole file.
        public var file: URL
        /// Where the chunk files are written (one per request, named by its job id) and the empty body of the `MOVE`.
        public var chunks: URL
        public var allowsExpensiveNetwork = true
        public var allowsConstrainedNetwork = true

        public init(file: URL, chunks: URL, allowsExpensiveNetwork: Bool = true, allowsConstrainedNetwork: Bool = true) {
            self.file = file
            self.chunks = chunks
            self.allowsExpensiveNetwork = allowsExpensiveNetwork
            self.allowsConstrainedNetwork = allowsConstrainedNetwork
        }

        func chunkFile(_ jobId: String) -> URL { chunks.appending(path: jobId) }
    }

    /// Where an upload stands after a call.
    public enum Progress: Sendable {
        /// Requests are with the system (or wait for the next call: no room, or the app could not reach the server).
        case running
        case finished(UploadedFile)
        /// Given up. The upload folder is kept when a later attempt can continue it (`Uploader.keepsUploadFolder`).
        case failed(any Error)
    }

    /// Hands over what the upload needs next: creates its upload folder when it has none, then chunks up to `window`,
    /// then the `MOVE`. Also the way to continue an upload after a launch or a pause.
    ///
    /// Errors of the app's own requests (the folder) are returned as `.failed` when they end the upload and as `.running`
    /// when they are transient: the next call tries again.
    public func advance(
        _ upload: inout ChunkedUpload, files: Files, isolation: isolated (any Actor)? = #isolation,
        save: (ChunkedUpload) throws -> Void
    ) async -> Progress {
        do {
            if upload.phase == .needsFolder {
                try await uploader.openFolder(&upload)
                try save(upload)
            }
            try FileManager.default.createDirectory(at: files.chunks, withIntermediateDirectories: true)
            for step in upload.next(limit: window) {
                let jobId = UUID().uuidString
                let body = files.chunkFile(jobId)
                try write(step, of: upload, from: files.file, to: body)
                var request = uploader.request(for: step, of: upload)
                request.allowsExpensiveNetwork = files.allowsExpensiveNetwork
                request.allowsConstrainedNetwork = files.allowsConstrainedNetwork
                // Recorded before it starts: a report without a record could not be understood.
                upload.started(step, jobId: jobId)
                do {
                    try save(upload)
                    try await transport.start(jobId: jobId, request: request, file: body)
                } catch {
                    upload.withdrawn(jobId)
                    try? save(upload)
                    try? FileManager.default.removeItem(at: body)
                    throw error
                }
            }
            return .running
        } catch let error as NetworkError where error.isTransient || RetryPolicy.isRetryable(error) || error == .cancelled {
            return .running
        } catch is CancellationError {
            return .running
        } catch {
            upload.markFailed()
            try? save(upload)
            await uploader.abandon(upload, after: error)
            return .failed(error)
        }
    }

    /// The system reports one of the upload's requests. Returns nil when the report is not one of this upload's.
    ///
    /// - Parameter handOver: hand over the next requests; false while the uploads are paused (they go on with the next
    ///   `advance`).
    public func report(
        _ event: BackgroundUploadEvent, upload: inout ChunkedUpload, files: Files, handOver: Bool = true,
        isolation: isolated (any Actor)? = #isolation, save: (ChunkedUpload) throws -> Void
    ) async -> Progress? {
        guard upload.running[event.jobId] != nil else { return nil }
        try? FileManager.default.removeItem(at: files.chunkFile(event.jobId))
        let outcome = upload.finished(
            jobId: event.jobId, status: event.response?.status, headers: event.response?.headers ?? [:], error: event.error)
        try? save(upload)
        switch outcome {
        case .unknown:
            return nil
        case .continuing, .needsFolder:
            // A request that was taken back (the user's pause) is not handed over again here; the next attempt does it.
            if event.error == .cancelled || !handOver { return .running }
            return await advance(&upload, files: files, save: save)
        case .assembled(let status, let headers):
            do {
                let uploaded = try await uploader.finish(upload, status: status, headers: headers)
                removeFiles(files)
                return .finished(uploaded)
            } catch {
                // The file is there, only its id could not be read: the next pass finds it by name and size.
                removeFiles(files)
                return .failed(error)
            }
        case .checkDestination(let error):
            do {
                if let uploaded = try await uploader.assembledFile(of: upload) {
                    upload.markFinished()
                    try? save(upload)
                    removeFiles(files)
                    return .finished(uploaded)
                }
            } catch let lookup as NetworkError where lookup.isTransient || RetryPolicy.isRetryable(lookup) {
                // Asked again with the next call (`advance` hands the `MOVE` over again).
                upload.retryAssembly()
                try? save(upload)
                return .running
            } catch {
                return fail(&upload, error: error, files: files, save: save)
            }
            if error == .preconditionFailed {
                // Another file has the name now: this upload cannot go there. Its chunks are of no use for another name.
                upload.markFailed()
                try? save(upload)
                await uploader.abandon(upload, after: nil)
                removeFiles(files)
                return .failed(error)
            }
            upload.retryAssembly()
            try? save(upload)
            return handOver ? await advance(&upload, files: files, save: save) : .running
        case .failed(let error):
            await uploader.abandon(upload, after: error)
            removeFiles(files)
            return .failed(error)
        }
    }

    private func fail(_ upload: inout ChunkedUpload, error: any Error, files: Files, save: (ChunkedUpload) throws -> Void) -> Progress {
        upload.markFailed()
        try? save(upload)
        removeFiles(files)
        return .failed(error)
    }

    /// Writes the body of a request: the chunk's bytes, or nothing for the `MOVE`.
    func write(_ step: ChunkedUpload.Step, of upload: ChunkedUpload, from file: URL, to body: URL) throws {
        switch step {
        case .assemble:
            try Data().write(to: body)
        case .chunk(let number):
            let range = upload.range(of: number)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            guard let data = try handle.read(upToCount: range.count), data.count == range.count else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: file])
            }
            try data.write(to: body)
        }
    }

    /// Removes the chunk files (the whole file belongs to the caller).
    public func removeFiles(_ files: Files) {
        try? FileManager.default.removeItem(at: files.chunks)
    }
}
