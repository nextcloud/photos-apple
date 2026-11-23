// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A trashed file (SPEC §7.14).
public struct TrashedItem: Sendable, Hashable, Identifiable {
    public var id: String { trashName }
    /// Name in the trash bin, e.g. `IMG_1.jpg.d1790000000`.
    public var trashName: String
    public var fileId: FileID
    public var originalName: String
    public var originalLocation: String
    public var deletedAt: Date?
    public var mimeType: String
    public var size: Int64
}

extension PhotosAPI {
    // MARK: Trash bin

    public func trash(mimeTypes: [String]) async throws -> [TrashedItem] {
        let resources = try await dav.propfind(
            connection.davURL("trashbin/\(connection.userId)/trash/"), depth: 1,
            properties: [
                DAVProp.fileId, DAVProp.contentType, DAVProp.size, DAVProp.trashbinFilename, DAVProp.trashbinOriginalLocation,
                DAVProp.trashbinDeletionTime,
            ])
        let mimes = Set(mimeTypes)
        return resources.dropFirst().compactMap { resource in
            guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId), let mime = resource.string(DAVProp.contentType),
                mimes.contains(mime)
            else { return nil }
            return TrashedItem(
                trashName: resource.lastPathComponent, fileId: fileId,
                originalName: resource.string(DAVProp.trashbinFilename) ?? resource.lastPathComponent,
                originalLocation: resource.string(DAVProp.trashbinOriginalLocation) ?? "",
                deletedAt: resource.unixDate(DAVProp.trashbinDeletionTime),
                mimeType: mime, size: resource.int64(DAVProp.size) ?? 0)
        }
        .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func restore(_ item: TrashedItem) async throws {
        // `Overwrite: T` as the web client sends it: the restore folder reports every name as existing, so with
        // `Overwrite: F` the server answers 412. Nothing is overwritten; the server renames when the place is taken.
        try await dav.move(
            connection.davURL("trashbin/\(connection.userId)/trash/\(item.trashName)"),
            to: connection.davURL("trashbin/\(connection.userId)/restore/\(item.trashName)"), overwrite: true)
    }

    public func deletePermanently(_ item: TrashedItem) async throws {
        try await dav.delete(connection.davURL("trashbin/\(connection.userId)/trash/\(item.trashName)"))
    }

    public func emptyTrash() async throws {
        try await dav.delete(connection.davURL("trashbin/\(connection.userId)/trash/"))
    }

    public func trashPreviewURL(fileId: FileID, size: Int) -> URL {
        connection.url(
            "index.php/apps/files_trashbin/preview",
            query: [
                URLQueryItem(name: "fileId", value: String(fileId)), URLQueryItem(name: "x", value: String(size)),
                URLQueryItem(name: "y", value: String(size)), URLQueryItem(name: "a", value: "1"),
            ])
    }

    // MARK: Task processing (Assistant, SPEC §7.20)

    /// Schedules a task and polls every 2 s until it finishes, fails or `timeout` passes.
    public func runTask(type: String, input: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        struct Envelope: Decodable {
            var task: Task
            struct Task: Decodable {
                var id: Int
                var status: String
                var output: JSONValue?
            }
        }
        struct Body: Encodable {
            var type: String
            var appId = "photos"
            var input: [String: JSONValue]
        }
        var envelope: Envelope = try await ocs.request("POST", "ocs/v2.php/taskprocessing/schedule", json: Body(type: type, input: input))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch envelope.task.status {
            case "STATUS_SUCCESSFUL": return envelope.task.output ?? .null
            case "STATUS_FAILED", "STATUS_CANCELLED": throw NetworkError.invalidResponse("task \(envelope.task.status)")
            default: break
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                _ = try? await ocs.raw("POST", "ocs/v2.php/taskprocessing/tasks/\(envelope.task.id)/cancel")
                throw error
            }
            envelope = try await ocs.request("GET", "ocs/v2.php/taskprocessing/task/\(envelope.task.id)")
        }
        _ = try? await ocs.raw("POST", "ocs/v2.php/taskprocessing/tasks/\(envelope.task.id)/cancel")
        throw NetworkError.timedOut
    }

    /// Server OCR (`core:image2text:ocr`).
    public func extractText(fileId: FileID) async throws -> String {
        let output = try await runTask(type: "core:image2text:ocr", input: ["input": .array([.number(Double(fileId))])], timeout: 600)
        return (output["output"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
    }

    /// Server text generation (`core:text2text`).
    public func generateText(_ prompt: String) async throws -> String {
        let output = try await runTask(type: "core:text2text", input: ["input": .string(prompt)], timeout: 180)
        return output["output"]?.string ?? ""
    }

    // MARK: Video renditions (extended servers, SPEC §5.5.3)

    /// Downloads the H.264 rendition of a video; throws `.notFound` while the server is still converting.
    public func videoRendition(fileId: FileID, etag: String) async throws -> URL {
        let url = connection.url("index.php/apps/photos/api/v1/video/\(fileId)", query: [URLQueryItem(name: "etag", value: etag)])
        let (file, _) = try await dav.download(url)
        let target = file.deletingLastPathComponent().appending(path: "\(fileId)-\(etag).mp4")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}
