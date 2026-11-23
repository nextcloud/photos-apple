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

/// The record of the uploads that are on their way, kept in a file so it outlives the app: when the system reports an
/// upload as finished, possibly to a later launch, this says which resource it was and where it went.
///
/// Losing an entry is harmless: the resource stays pending, and the next pass finds the file on the server (same name and
/// size count as uploaded, SPEC §7.18.4 layer 5) or uploads it again.
struct BackgroundUploadJournal {
    let directory: URL
    private(set) var jobs: [String: BackgroundUploadJob] = [:]

    var file: URL { directory.appending(path: "journal.json") }

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: file), let jobs = try? JSONDecoder().decode([String: BackgroundUploadJob].self, from: data) {
            self.jobs = jobs
        }
    }

    func job(for resource: BackupResource) -> BackgroundUploadJob? {
        jobs.values.first { $0.resource.localIdentifier == resource.localIdentifier && $0.resource.kind == resource.kind }
    }

    /// Destinations that are taken although the server has nothing there yet.
    var reservedPaths: Set<String> { Set(jobs.values.map(\.path)) }

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
        for url in contents where url.lastPathComponent != file.lastPathComponent && jobs[url.lastPathComponent] == nil {
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
        try JSONEncoder().encode(jobs).write(to: file, options: .atomic)
    }
}
