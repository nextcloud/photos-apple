// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Per-resource state in the `backupAsset` table (SPEC §7.18.3).
public enum BackupItemState: String, Codable, Sendable {
    case pending, uploaded, matched, failed, skipped
}

public struct BackupLedgerEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "backupAsset"
    public var localIdentifier: String
    public var resourceKind: String
    public var fingerprint: String?
    public var state: String
    public var serverPath: String?
    public var serverFileId: Int64?
    public var serverEtag: String?
    public var matchedBy: String?
    public var attempts: Int
    public var lastError: String?
    public var assetCreatedAt: Double?
    public var assetModifiedAt: Double?
    public var updatedAt: Double
    /// What the library said about the resource (`BackupResource` as JSON) while it is not on the server: later passes
    /// upload it from here without reading the library again. Nil once it is uploaded or matched.
    public var resource: String? = nil
    /// When the server was last asked about the resource and did not have it (SPEC §7.18.4 layer 4).
    public var checkedAt: Double? = nil

    /// The stored resource, when there is one and it can be read.
    func storedResource(_ decoder: JSONDecoder) -> BackupResource? {
        guard let resource else { return nil }
        return try? decoder.decode(BackupResource.self, from: Data(resource.utf8))
    }
}

extension BackupResource {
    /// The form `BackupLedgerEntry.resource` keeps it in.
    func json(_ encoder: JSONEncoder) -> String? {
        (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }
}
