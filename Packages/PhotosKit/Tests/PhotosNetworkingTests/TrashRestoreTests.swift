// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosNetworking

/// Restoring from the trash bin ("Recently deleted", undo of a delete).
@Suite struct TrashRestoreTests {
    /// Nextcloud's restore folder reports every name as existing: a MOVE with `Overwrite: F` is answered with 412.
    @Test func restoreMovesIntoTheRestoreFolderWithOverwrite() async throws {
        let server = UploadStubServer()
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: server.dav.http.session.configuration)
        let api = PhotosAPI(dav: server.dav, ocs: OCSClient(http: http, connection: server.connection))
        let item = TrashedItem(
            trashName: "a.jpg.d1790000000", fileId: 5, originalName: "a.jpg", originalLocation: "Photos/a.jpg", deletedAt: nil,
            mimeType: "image/jpeg", size: 1)
        try? await api.restore(item)
        let move = try #require(server.requests.first { $0.method == "MOVE" })
        #expect(move.path == "/trashbin/alice/trash/a.jpg.d1790000000")
        let headers = Dictionary(move.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(headers["overwrite"] == "T")
        #expect(headers["destination"]?.hasSuffix("/remote.php/dav/trashbin/alice/restore/a.jpg.d1790000000") == true)
    }
}
