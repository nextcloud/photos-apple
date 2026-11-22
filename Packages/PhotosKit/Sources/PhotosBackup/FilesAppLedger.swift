// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosModel

/// Read-only access to what the Nextcloud Files app uploaded (SPEC §7.18.5).
///
/// Only works when this app is signed by the same team and lists `group.it.twsweb.Crypto-Cloud`.
/// Never opens Files' Realm database. Every failure simply means "no Files data".
public enum FilesAppLedger {
    public static let group = "group.it.twsweb.Crypto-Cloud"

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }

    /// Whether Files' App Group is readable at all.
    public static var isAvailable: Bool {
        guard let container else { return false }
        return FileManager.default.isReadableFile(atPath: container.path(percentEncoded: false))
    }

    /// Files' auto-upload naming and format options (group UserDefaults `Preferences_*`).
    public static func settings() -> FilesAppSettings? {
        guard isAvailable, let defaults = UserDefaults(suiteName: group) else { return nil }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: "Preferences_\(key)") as? Bool ?? fallback
        }
        return FilesAppSettings(
            folder: "/Photos",
            fileNameOriginal: bool("fileNameOriginal", false),
            fileNameType: bool("fileNameType", false),
            fileNameMask: defaults.string(forKey: "Preferences_fileNameMask"),
            formatCompatibility: bool("formatCompatibility", true),
            livePhoto: bool("livePhoto", true)
        )
    }

    /// PhotoKit local identifiers the Files app uploaded for an account (`"<user> <serverURL>"`, the same account id convention).
    public static func uploadedAssets(accountId: AccountID) -> Set<String> {
        guard let container else { return [] }
        let file = container.appending(path: "Library/Application Support/Nextcloud/nextcloud.sqlite")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: file.path(percentEncoded: false), configuration: configuration) else { return [] }
        return
            (try? queue.read { db -> Set<String> in
                var result = Set<String>()
                if try db.tableExists("photoLibraryAsset") {
                    let rows = try String.fetchAll(
                        db,
                        sql:
                            "SELECT assetLocalIdentifier FROM photoLibraryAsset WHERE account = ? AND (photoUploaded = 1 OR videoUploaded = 1)",
                        arguments: [accountId.rawValue])
                    result.formUnion(rows)
                }
                if try db.tableExists("autoUploadResource") {
                    let rows = try String.fetchAll(
                        db, sql: "SELECT assetLocalIdentifier FROM autoUploadResource WHERE account = ? AND uploaded = 1",
                        arguments: [accountId.rawValue])
                    result.formUnion(rows)
                }
                return result
            }) ?? []
    }
}
