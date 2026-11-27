// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import Testing

@testable import PhotosAppUI

/// "Apply Edits to the File" against a real server (SPEC §21.6.6): the original is kept as a named version before the
/// edited picture replaces it, editing again keeps that first original, and Restore Original brings back the very bytes
/// of the original. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER, PHOTOS_IT_PASSWORD and PHOTOS_IT_APPLY_PATH (a JPEG
/// in the user's files made for the test — never a photo of a test library) are set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_APPLY_PATH"] != nil), .serialized)
struct ApplyEditsToFileIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func services() throws -> AccountServices {
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let root = FileManager.default.temporaryDirectory.appending(path: "photos-apply-it-\(UUID().uuidString)")
        return try AccountServices(
            account: Account(serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user, displayName: user),
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", http: HTTPClient(trustStore: TrustStore(directory: nil)),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests",
            layout: StorageLayout(container: root), onUnauthorized: {})
    }

    /// The file as it is on the server now: its SHA-256, ETag and file id.
    func current(_ services: AccountServices, path: String) async throws -> (hash: String, etag: String, fileId: FileID) {
        let (file, _) = try await services.dav.download(services.connection.filesURL(path))
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let resource = try #require(
            try await services.dav.propfind(services.connection.filesURL(path), depth: 0, properties: [DAVProp.etag, DAVProp.fileId]).first)
        let etag = try #require(resource.string(DAVProp.etag)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let fileId = try #require(resource.string(DAVProp.fileId).flatMap { FileID($0) })
        return (hash, etag, fileId)
    }

    func item(_ path: String, _ state: (hash: String, etag: String, fileId: FileID)) -> MediaItem {
        MediaItem(fileId: state.fileId, path: path, mimeType: "image/jpeg", etag: state.etag, permissions: Permissions(rawValue: "RGDNVW"))
    }

    @Test func theOriginalSurvivesInTheVersionsAndComesBack() async throws {
        let services = try services()
        let path = try #require(env["PHOTOS_IT_APPLY_PATH"])
        let versions = FileVersions(dav: services.dav)
        let original = try await current(services, path: path)
        print("apply-it: original \(original.hash) etag \(original.etag) fileId \(original.fileId)")

        // 1. The edit goes into the file; the original is a named version first.
        var recipe = EditRecipe()
        recipe.edits.exposure = 0.6
        recipe.edits.curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.95)])
        recipe.edits.colorMixer[.blue] = ColorMixer.Adjustment(saturation: -0.5)
        try await PhotoEditSaving.overwrite(item(path, original), with: recipe, services: services)
        let edited = try await current(services, path: path)
        #expect(edited.hash != original.hash)
        #expect(edited.fileId == original.fileId)
        let kept = try #require(try await versions.original(of: original.fileId))
        print("apply-it: edited \(edited.hash); kept version \(kept.id) label \(kept.label ?? "-") size \(kept.size ?? -1)")
        #expect(kept.label == FileVersions.originalLabel)
        let keptHash = SHA256.hash(data: try await versions.download(original.fileId, version: kept.id)).map { String(format: "%02x", $0) }
            .joined()
        #expect(keptHash == original.hash)

        // 2. Editing again (from the edited file) keeps the first original, and only that one is named.
        var again = EditRecipe()
        again.edits.rotate(clockwise: true)
        try await PhotoEditSaving.overwrite(item(path, edited), with: again, services: services)
        let all = try await versions.versions(of: original.fileId)
        print("apply-it: versions \(all.map { "\($0.id):\($0.label ?? "-")" })")
        #expect(all.filter { FileVersions.isOriginal($0.label) }.map(\.id) == [kept.id])
        #expect(all.count >= 3)

        // 3. A stale ETag replaces nothing (the server's newer version stays).
        await #expect(throws: PhotoEditSaving.Failure.changedOnServer) {
            try await PhotoEditSaving.overwrite(item(path, original), with: recipe, services: services)
        }

        // 4. Restore Original: the bytes of the original are the file again; the edits stay as versions.
        let latest = try await current(services, path: path)
        try await PhotoEditSaving.restoreOriginal(item(path, latest), services: services)
        let restored = try await current(services, path: path)
        print("apply-it: restored \(restored.hash)")
        #expect(restored.hash == original.hash)
        #expect(restored.hash == keptHash)
        let after = try await versions.versions(of: original.fileId)
        #expect(after.count >= all.count)
    }

    @Test func noVersionsMeansNothingIsReplaced() async throws {
        let services = try services()
        // A file id that does not exist: the server lists no versions, so the original could not be kept.
        await #expect(throws: FileVersions.Failure.unavailable) {
            try await FileVersions(dav: services.dav).keepOriginal(of: 999_999_999)
        }
    }
}
