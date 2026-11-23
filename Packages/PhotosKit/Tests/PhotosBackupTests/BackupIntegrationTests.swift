// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Checks the reconciliation SEARCH against a real server (PHOTOS_IT_SERVER/USER/PASSWORD).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct BackupIntegrationTests {
    @Test func reconciliationSearchFindsKnownFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"]!)!, userId: user, loginName: user, appPassword: env["PHOTOS_IT_PASSWORD"] ?? "",
            userAgent: "tests")
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        // A known photo from the index.
        let page = try await api.indexPage(
            sourceFolders: ["/"], mimeTypes: MimeTypes.defaultImages, properties: DAVProp.mediaIndex, before: nil, limit: 200)
        let photo = try #require(page.items.first { $0.capturedAt != nil && $0.width != nil && BackupNaming.number(in: $0.name) != nil })
        let captured = try #require(photo.capturedAt)

        let database = try AccountDatabase.temporary()
        let remote = PhotosBackupRemote(api: api, library: LibraryStore(database: database), database: database)
        let candidates = try await remote.candidates(from: captured.addingTimeInterval(-2), to: captured.addingTimeInterval(2))
        #expect(candidates.contains { $0.fileId == photo.fileId })

        // The device copy of that photo would be matched (same second, same dimensions, only candidate) or by its number.
        let local = LocalResource(
            localIdentifier: "x", kind: .image, createdAt: captured, originalName: photo.name, pixelWidth: photo.width,
            pixelHeight: photo.height)
        let match = BackupMatcher.match(local, candidates: candidates, localSiblings: [local])
        #expect(match != nil)
    }
}
