// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking

/// How the backup uses a background transfer session (SPEC §7.18.6).
public struct BackgroundUploads: Sendable {
    public var transport: any BackgroundUploading
    /// Where the files wait while the system uploads them, and where the record of them is kept.
    public var directory: URL
    /// Larger files are uploaded in chunks by the app itself, which the system cannot do on its own.
    public var maxFileSize: Int64 = 100 * 1024 * 1024
    /// How many uploads are handed over ahead. More would only copy more of the photo library into the app's container.
    public var maxJobs = 16
    public var maxStagedBytes: Int64 = 256 * 1024 * 1024
    /// Larger files go in chunks (`ChunkedUpload`), one request per chunk; this many of them at once, each with the whole
    /// export waiting in the container.
    public var maxChunkedUploads = 1
    /// Chunks of one upload with the system at once (each a copy of its part of the file). More mean fewer launches of
    /// the app in the background to hand over the next ones.
    public var chunkWindow = 8

    public init(transport: any BackgroundUploading, directory: URL) {
        self.transport = transport
        self.directory = directory
    }
}

/// An upload that was handed to the system.
struct BackgroundUploadJob: Codable, Sendable, Equatable {
    /// The id the transfer session knows it by.
    var id: String
    var resource: BackupResource
    /// Destination below the user's files.
    var path: String
    var size: Int64
    var startedAt: Date
}

/// A large file that the system uploads in chunks (`ChunkedUpload`), one request per chunk. The export waits in
/// `<directory>/<upload id>/<file name>`, the chunk files next to it in `chunks`.
struct ChunkedBackgroundJob: Codable, Sendable, Equatable {
    var upload: ChunkedUpload
    var resource: BackupResource
    var fileName: String
    /// The networks its requests may use (Wi-Fi only, Low Data Mode), fixed when it was handed over.
    var allowsExpensiveNetwork: Bool
    var allowsConstrainedNetwork: Bool
    var startedAt: Date

    var id: String { upload.id }
}

/// The record of the uploads that are on their way, kept in a file so it outlives the app: when the system reports an
/// upload as finished, possibly to a later launch, this says which resource it was and where it went.
///
/// Losing an entry is harmless: the resource stays pending, and the next pass finds the file on the server (same name and
/// size count as uploaded, SPEC §7.18.4 layer 5) or uploads it again.
struct BackgroundUploadJournal {
    let directory: URL
    private(set) var jobs: [String: BackgroundUploadJob] = [:]
    /// Chunked uploads by upload id; their requests are in `ChunkedUpload.running`.
    private(set) var chunked: [String: ChunkedBackgroundJob] = [:]

    var file: URL { directory.appending(path: "journal.json") }

    /// The file's content. Earlier versions wrote the single uploads only (a dictionary by job id).
    private struct Stored: Codable {
        var jobs: [String: BackgroundUploadJob]
        var chunked: [String: ChunkedBackgroundJob]
    }

    init(directory: URL) {
        self.directory = directory
        guard let data = try? Data(contentsOf: file) else { return }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            jobs = stored.jobs
            chunked = stored.chunked
        } else if let jobs = try? JSONDecoder().decode([String: BackgroundUploadJob].self, from: data) {
            self.jobs = jobs
        }
    }

    func job(for resource: BackupResource) -> BackgroundUploadJob? {
        jobs.values.first { $0.resource.localIdentifier == resource.localIdentifier && $0.resource.kind == resource.kind }
    }

    func chunkedJob(for resource: BackupResource) -> ChunkedBackgroundJob? {
        chunked.values.first { $0.resource.localIdentifier == resource.localIdentifier && $0.resource.kind == resource.kind }
    }

    /// The resource is with the system (as one upload or in chunks).
    func isHandedOver(_ resource: BackupResource) -> Bool {
        job(for: resource) != nil || chunkedJob(for: resource) != nil
    }

    /// Resources that are with the system.
    var handedOverResources: [BackupResource] { jobs.values.map(\.resource) + chunked.values.map(\.resource) }

    /// The chunked upload a request belongs to.
    func chunkedUploadId(forJob jobId: String) -> String? {
        chunked.values.first { $0.upload.running[jobId] != nil }?.id
    }

    /// Ids of every request with the system: single uploads and the requests of chunked ones.
    var allJobIds: Set<String> {
        Set(jobs.keys).union(chunked.values.flatMap { $0.upload.running.keys })
    }

    /// Uploads with the system, single or chunked.
    var count: Int { jobs.count + chunked.count }

    /// Destinations that are taken although the server has nothing there yet.
    var reservedPaths: Set<String> { Set(jobs.values.map(\.path)).union(chunked.values.map(\.upload.path)) }

    /// Where a chunked upload's files are.
    func files(of job: ChunkedBackgroundJob) -> ChunkedUploadDriver.Files {
        let directory = stagingDirectory(job.id)
        return ChunkedUploadDriver.Files(
            file: directory.appending(path: job.fileName), chunks: directory.appending(path: "chunks"),
            allowsExpensiveNetwork: job.allowsExpensiveNetwork, allowsConstrainedNetwork: job.allowsConstrainedNetwork)
    }

    /// Records a chunked upload (new, or its state changed).
    mutating func setChunked(_ job: ChunkedBackgroundJob) throws {
        let previous = chunked[job.id]
        chunked[job.id] = job
        do {
            try save()
        } catch {
            chunked[job.id] = previous
            throw error
        }
    }

    /// The new state of a chunked upload's requests.
    mutating func updateChunked(_ upload: ChunkedUpload) throws {
        guard var job = chunked[upload.id] else { return }
        job.upload = upload
        try setChunked(job)
    }

    /// Forgets a chunked upload and deletes its files.
    @discardableResult
    mutating func removeChunked(_ id: String) -> ChunkedBackgroundJob? {
        try? FileManager.default.removeItem(at: stagingDirectory(id))
        guard let job = chunked.removeValue(forKey: id) else { return nil }
        try? save()
        return job
    }

    var stagedBytes: Int64 { jobs.values.reduce(0) { $0 + $1.size } }

    /// The directory an upload's file waits in.
    func stagingDirectory(_ id: String) -> URL { directory.appending(path: id) }

    /// Moves a file to where it waits for its upload.
    func stage(_ file: URL, id: String) throws -> URL {
        let target = stagingDirectory(id).appending(path: file.lastPathComponent)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    mutating func add(_ job: BackgroundUploadJob) throws {
        jobs[job.id] = job
        do {
            try save()
        } catch {
            jobs[job.id] = nil
            throw error
        }
    }

    /// Forgets an upload and deletes its file.
    @discardableResult
    mutating func remove(_ id: String) -> BackgroundUploadJob? {
        try? FileManager.default.removeItem(at: stagingDirectory(id))
        guard let job = jobs.removeValue(forKey: id) else { return nil }
        try? save()
        return job
    }

    /// Deletes files that wait for an upload nobody knows about (the app ended between moving the file and recording it).
    func removeUnknownFiles() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents
        where url.lastPathComponent != file.lastPathComponent && jobs[url.lastPathComponent] == nil && chunked[url.lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Copies of photos that are on their way to the server anyway do not belong into a device backup.
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try JSONEncoder().encode(Stored(jobs: jobs, chunked: chunked)).write(to: file, options: .atomic)
    }
}
