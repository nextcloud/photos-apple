// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A chunked upload (Nextcloud chunking v2) that a background transfer session sends one request at a time, so that it
/// goes on while the app is suspended or not running (SPEC §7.18.6).
///
/// A value that only says what to do next: whoever drives it (`BackupEngine`, the share uploads) creates the upload folder
/// (`Uploader.openFolder`), writes the chunk files, hands the requests to the system (`Uploader.request(for:of:)`) and
/// reports what the system says (`finished`). It is kept in a file between launches, so an upload continues where it
/// stopped. The upload folder is the one `Uploader.upload` uses for the same file and destination, so an upload the app
/// started itself is continued too.
///
/// Phases: `needsFolder` → `sending` (chunks, any order, a few at a time) → `assembling` (the final `MOVE`) → `finished`,
/// or `failed`.
public struct ChunkedUpload: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// The upload folder has to be created (or looked at) by the app itself: `Uploader.openFolder`.
        case needsFolder
        /// Chunks are being sent.
        case sending
        /// All chunks are on the server; the `MOVE` that puts the file together is next or on its way.
        case assembling
        /// The file is at its destination.
        case finished
        /// It stopped for a reason the next request would meet as well; see `ChunkedUpload.Outcome.failed`.
        case failed
    }

    /// One request of the upload that the system sends.
    public enum Step: Codable, Hashable, Sendable {
        /// `PUT` of chunk n (1-based).
        case chunk(Int)
        /// `MOVE` of the assembled file to its destination.
        case assemble
    }

    /// What a reported request means for the upload.
    public enum Outcome: Sendable, Equatable {
        /// Go on: hand over what `next` returns.
        case continuing
        /// The server removed the upload folder (it expires unfinished uploads): it is created again, and every chunk is
        /// sent again.
        case needsFolder
        /// The answer to the `MOVE`: the file is there.
        case assembled(status: Int, headers: [String: String])
        /// The `MOVE` got no answer, or the server refused it (412: a file is at the destination; 404 after an earlier
        /// attempt): the server may have put the file together anyway. Look at the destination (`Uploader.assembledFile`).
        /// When it is not there: after a 412 the name is taken by another file (the upload has to start again with
        /// another name), otherwise `retryAssembly()`.
        case checkDestination(NetworkError)
        /// Given up; the error says why (`Uploader.keepsUploadFolder(after:)` tells whether the chunks may be kept).
        case failed(NetworkError)
        /// Not a request of this upload, or one reported before.
        case unknown
    }

    public let id: String
    /// Destination below the user's files.
    public let path: String
    public let size: Int64
    public let chunkSize: Int
    /// `uploads/<user>/photos-<key>/`.
    public let folder: URL
    public let destination: URL
    /// Sent with the `MOVE`: `X-OC-MTime`, `X-OC-CTime`, `OC-Checksum`.
    public let headers: [String: String]
    public private(set) var phase: Phase = .needsFolder
    /// Chunks the server has.
    public private(set) var sent: Set<Int> = []
    /// Requests with the system, by the id they were started with.
    public private(set) var running: [String: Step] = [:]
    /// Failed attempts per request that did not end the upload (key: `Step.key`).
    public private(set) var failures: [String: Int] = [:]

    /// How often one request may fail for a transient reason before the upload is given up (the next attempt of the
    /// upload goes on with the chunks that are there).
    public static let maxFailures = 4

    public init(id: String, path: String, size: Int64, chunkSize: Int, folder: URL, destination: URL, headers: [String: String]) {
        self.id = id
        self.path = path
        self.size = size
        self.chunkSize = chunkSize
        self.folder = folder
        self.destination = destination
        self.headers = headers
    }

    public var chunkCount: Int { max(1, Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))) }

    /// Byte range of a chunk (1-based) in the file.
    public func range(of chunk: Int) -> Range<Int64> {
        let start = Int64(chunk - 1) * Int64(chunkSize)
        return start..<min(size, start + Int64(chunkSize))
    }

    /// Headers of every request of the upload (chunking v2 wants the destination and the total size on each).
    public var commonHeaders: [String: String] {
        ["Destination": destination.absoluteString, "OC-Total-Length": String(size)]
    }

    /// Bytes the server has.
    public var sentBytes: Int64 { sent.reduce(0) { $0 + Int64(range(of: $1).count) } }

    public var isDone: Bool { phase == .finished || phase == .failed }

    /// The upload folder exists. `existing` are the chunks an earlier attempt left there (number → size); those of the
    /// right size are not sent again.
    public mutating func folderReady(existing: [Int: Int64] = [:]) {
        guard phase == .needsFolder else { return }
        sent = Set(existing.compactMap { number, length in (1...chunkCount).contains(number) && length == Int64(range(of: number).count) ? number : nil })
        running = [:]
        phase = sent.count == chunkCount ? .assembling : .sending
    }

    /// The requests to hand over now, at most `limit` running at once: missing chunks in order, then the `MOVE` once
    /// every chunk is there. Nothing while the folder is missing or the upload is done.
    public func next(limit: Int) -> [Step] {
        let room = limit - running.count
        guard room > 0 else { return [] }
        switch phase {
        case .needsFolder, .finished, .failed:
            return []
        case .sending:
            let busy = Set(running.values)
            var steps: [Step] = []
            for chunk in 1...chunkCount where !sent.contains(chunk) && !busy.contains(.chunk(chunk)) {
                steps.append(.chunk(chunk))
                if steps.count == room { break }
            }
            return steps
        case .assembling:
            return running.isEmpty ? [.assemble] : []
        }
    }

    /// A request was handed to the system under this id.
    public mutating func started(_ step: Step, jobId: String) {
        running[jobId] = step
    }

    /// The system no longer knows these requests and never reported them: they are handed over again.
    public mutating func lost(_ jobIds: Set<String>) {
        for id in jobIds { running[id] = nil }
    }

    /// A request was taken back (the user's pause): it is handed over again with the next attempt.
    public mutating func withdrawn(_ jobId: String) {
        running[jobId] = nil
    }

    /// The `MOVE` is handed over once more (the destination did not have the file).
    public mutating func retryAssembly() {
        guard phase == .assembling else { return }
        running = running.filter { $0.value != .assemble }
    }

    /// The file is at its destination (found there after the answer to the `MOVE` got lost).
    public mutating func markFinished() {
        phase = .finished
        running = [:]
    }

    /// Gives the upload up (the destination check found another file, or the caller stops it).
    public mutating func markFailed() {
        phase = .failed
        running = [:]
    }

    /// The system reports a request: the server's status and headers, or an error.
    public mutating func finished(jobId: String, status: Int?, headers: [String: String] = [:], error: NetworkError?) -> Outcome {
        guard let step = running.removeValue(forKey: jobId), !isDone else { return .unknown }
        if error == .cancelled { return .continuing }
        let failure = error ?? status.flatMap { NetworkError.from(status: $0, data: Data()) }
        switch step {
        case .chunk(let number):
            guard let failure else {
                guard status != nil else { return fail(.invalidResponse("no answer")) }
                sent.insert(number)
                failures[step.key] = nil
                if phase == .sending, sent.count == chunkCount { phase = .assembling }
                return .continuing
            }
            // The upload folder is gone: everything once more, the server has none of it.
            if failure == .notFound { return restart() }
            return transient(failure, step: step)
        case .assemble:
            guard let failure else {
                guard let status else { return fail(.invalidResponse("no answer")) }
                phase = .finished
                running = [:]
                return .assembled(status: status, headers: headers)
            }
            let earlier = failures[step.key, default: 0]
            if failure == .notFound, earlier == 0 {
                // The first `MOVE` found no upload folder: the server expired it. Everything once more.
                return restart()
            }
            // The server may have put the file together although its answer got lost; a second `MOVE` would then fail.
            if failure == .preconditionFailed || failure == .notFound || RetryPolicy.isRetryable(failure) {
                failures[step.key] = earlier + 1
                if earlier + 1 > Self.maxFailures { return fail(failure) }
                return .checkDestination(failure)
            }
            return fail(failure)
        }
    }

    private mutating func restart() -> Outcome {
        phase = .needsFolder
        sent = []
        running = [:]
        failures = [:]
        return .needsFolder
    }

    private mutating func transient(_ error: NetworkError, step: Step) -> Outcome {
        guard error.isTransient || RetryPolicy.isRetryable(error) else { return fail(error) }
        failures[step.key, default: 0] += 1
        return failures[step.key, default: 0] >= Self.maxFailures ? fail(error) : .continuing
    }

    private mutating func fail(_ error: NetworkError) -> Outcome {
        phase = .failed
        running = [:]
        return .failed(error)
    }
}

extension ChunkedUpload.Step {
    /// A string for the step, for dictionaries that are stored.
    var key: String {
        switch self {
        case .chunk(let number): "chunk-\(number)"
        case .assemble: "assemble"
        }
    }
}
