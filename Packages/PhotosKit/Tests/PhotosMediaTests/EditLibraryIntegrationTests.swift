// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import Testing

@testable import PhotosMedia

/// Edit recipes against a real Nextcloud (SPEC §16.3.1): created with `If-None-Match: *`, replaced with `If-Match`, a
/// conflict between two devices, revert. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set
/// and PHOTOS_IT_EDITS=1; it uses a file id no photo has (`fileId`) and removes its recipe again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_EDITS"] != nil), .timeLimit(.minutes(2)))
struct EditLibraryIntegrationTests {
    let env = ProcessInfo.processInfo.environment
    let fileId: FileID = 990_000_000 + FileID.random(in: 0..<1_000_000)

    var dav: DAVClient {
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        return DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
    }

    func remote(_ dav: DAVClient) async throws -> EditRecipe? {
        do {
            return try EditRecipe.decode(try await dav.get(dav.connection.filesURL("\(EditLibrary.folder)/\(fileId).json")).data)
        } catch NetworkError.notFound {
            return nil
        }
    }

    @Test func recipesSyncThroughNextcloud() async throws {
        let dav = dav
        let phone = EditLibrary(dav: dav, file: nil)
        let mac = EditLibrary(dav: dav, file: nil)
        var first = EditRecipe(updatedAt: Date(timeIntervalSince1970: 1000))
        first.edits.rotate(clockwise: true)
        await phone.save(first, for: fileId)
        await phone.waitUntilIdle()
        #expect(await phone.pendingCount() == 0)
        #expect(try await remote(dav) == first)

        await mac.sync()
        #expect(mac.recipe(for: fileId) == first)

        // Both change it from the same version; the later edit wins on both devices.
        var later = first
        later.edits.exposure = 0.7
        later.updatedAt = Date(timeIntervalSince1970: 3000)
        var earlier = first
        earlier.edits.filter = .noir
        earlier.updatedAt = Date(timeIntervalSince1970: 2000)
        await mac.save(later, for: fileId)
        await mac.waitUntilIdle()
        await phone.save(earlier, for: fileId)
        await phone.waitUntilIdle()
        #expect(try await remote(dav) == later)
        #expect(phone.recipe(for: fileId) == later)

        await phone.revert(fileId)
        await phone.waitUntilIdle()
        #expect(try await remote(dav) == nil)
        await mac.sync()
        #expect(mac.recipe(for: fileId) == nil)
    }
}
