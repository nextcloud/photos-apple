// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Tags through the outbox and into the search index, against a real server. Runs only when PHOTOS_IT_SERVER,
/// PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set. Creates its own folder, file and tag (`r3-E2-…`) and removes them.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil), .timeLimit(.minutes(5)))
struct LabelsIntegrationTests {
    let connection: ServerConnection
    let http = HTTPClient(trustStore: TrustStore(directory: nil))

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
    }

    var api: PhotosAPI {
        PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    static func jpeg() -> Data {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func tagsGoThroughTheOutboxIntoTheSearchIndex() async throws {
        let api = self.api
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let folder = "/Photos/r3-E2-it-\(suffix)"
        let path = "\(folder)/photo.jpg"
        let tagName = "r3-E2-tag-\(suffix)"
        try await api.dav.mkcolRecursive(userPath: folder)
        var tagId: Int?
        do {
            try await run(folder: folder, path: path, tagName: tagName, tagId: &tagId)
        } catch {
            await cleanUp(folder: folder, tagId: tagId)
            throw error
        }
        await cleanUp(folder: folder, tagId: tagId)
    }

    func cleanUp(folder: String, tagId: Int?) async {
        try? await api.dav.delete(api.connection.filesURL(folder))
        if let tagId { try? await api.dav.delete(api.connection.davURL("systemtags/\(tagId)")) }
    }

    func run(folder: String, path: String, tagName: String, tagId: inout Int?) async throws {
        let api = self.api
        _ = try await api.dav.send(
            "PUT", api.connection.filesURL(path), headers: ["Content-Type": "image/jpeg"], body: Self.jpeg())
        guard
            let fileId = try await api.dav.propfind(api.connection.filesURL(path), depth: 0, properties: [DAVProp.fileId]).first?
                .int64(DAVProp.fileId)
        else {
            Issue.record("uploaded file has no id")
            return
        }

        // A new tag; creating it again returns the same one (409 on the server).
        let tag = try await api.createTag(tagName)
        tagId = tag.id
        #expect(try await api.createTag(tagName).id == tag.id)

        let database = try AccountDatabase.temporary()
        let library = LibraryStore(database: database)
        try library.upsert([MediaItem(fileId: fileId, path: path, mimeType: "image/jpeg", etag: "x")])
        let outbox = Outbox(api: api, database: database, retryDelay: { _ in 3600 })

        try await outbox.enqueue([.tag(TagChange(fileId: fileId, tagId: tag.id, tagName: tag.name, assign: true))])
        #expect(try await library.search(LibrarySearch(texts: [tagName])).map(\.fileId) == [fileId])
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(try await api.tags(of: fileId).map(\.id).contains(tag.id))
        #expect(try await api.tagMemberIds(tag.id) == [fileId])

        // The refresh reads the tag's files again (its count was marked unknown) and keeps the membership.
        let labels = LabelSync(api: api, database: database)
        try await labels.refresh(tags: true, people: false, peopleKey: nil)
        #expect(try LabelStore(database: database).fileIds(withTag: tag.id) == [fileId])
        #expect(try await library.search(LibrarySearch(texts: [tagName])).map(\.fileId) == [fileId])

        try await outbox.enqueue([.tag(TagChange(fileId: fileId, tagId: tag.id, tagName: tag.name, assign: false))])
        #expect(try await library.search(LibrarySearch(texts: [tagName])).isEmpty)
        await outbox.waitUntilIdle()
        #expect(try await outbox.failedOperations().isEmpty)
        #expect(try await !api.tags(of: fileId).map(\.id).contains(tag.id))
    }
}
