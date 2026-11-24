// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import PhotosCore
import PhotosModel
import PhotosNetworking
import Testing

@testable import PhotosAppUI

/// Image ▸ Rotate's save path against a real server: the photo is replaced by a turned version of itself, and a stale
/// ETag replaces nothing. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER, PHOTOS_IT_PASSWORD and PHOTOS_IT_ROTATE_PATH
/// (a JPEG in the user's files made for the test, e.g. `/Photos/r4-editmac/rotate-me.jpg`) are set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_ROTATE_PATH"] != nil))
struct PhotoEditSavingIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func services() throws -> AccountServices {
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let root = FileManager.default.temporaryDirectory.appending(path: "photos-edit-it-\(UUID().uuidString)")
        return try AccountServices(
            account: Account(serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "")!, userId: user, loginName: user, displayName: user),
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", http: HTTPClient(trustStore: TrustStore(directory: nil)),
            features: ServerFeatures(serverVersion: ServerVersion(major: 33)), userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests",
            layout: StorageLayout(container: root), onUnauthorized: {})
    }

    /// Width and height of the file on the server now.
    func size(_ services: AccountServices, path: String) async throws -> (Int, Int) {
        let (file, _) = try await services.dav.download(services.connection.filesURL(path))
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func rotateReplacesThePhotoAndAStaleVersionIsLeftAlone() async throws {
        let services = try services()
        let path = try #require(env["PHOTOS_IT_ROTATE_PATH"])
        let head = try await services.dav.head(services.connection.filesURL(path))
        let etag = try #require(head.header("etag")).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let before = try await size(services, path: path)
        let item = MediaItem(
            fileId: 1, path: path, mimeType: "image/jpeg", etag: etag, permissions: Permissions(rawValue: "RGDNVW"))
        try await PhotoEditSaving.overwrite(item, with: PhotoRotation.edits(clockwise: true), services: services)
        let after = try await size(services, path: path)
        #expect(after.0 == before.1 && after.1 == before.0)
        // The app's ETag is the old one now: nothing is overwritten.
        await #expect(throws: PhotoEditSaving.Failure.changedOnServer) {
            try await PhotoEditSaving.overwrite(item, with: PhotoRotation.edits(clockwise: false), services: services)
        }
        let unchanged = try await size(services, path: path)
        #expect(unchanged.0 == after.0 && unchanged.1 == after.1)
    }
}
