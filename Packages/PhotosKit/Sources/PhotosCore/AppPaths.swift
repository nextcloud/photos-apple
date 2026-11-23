// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// File locations. Uses the App Group container when available (shared with extensions), else Application Support.
public enum AppPaths {
    /// From Info.plist (`group.$(PHOTOS_BUNDLE_ID)`), so local builds with their own bundle id use their own group.
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PhotosAppGroup") as? String ?? "group.com.nextcloud.photos"

    public static let container: URL = {
        // macOS returns a group path even without the entitlement (unsigned development builds); only use it when writable.
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup), isWritable(group) {
            return group
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "NextcloudPhotos")
    }()

    static func isWritable(_ directory: URL) -> Bool {
        let probe = directory.appending(path: "Library/.write-probe")
        do {
            try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// The layout of the app's own container.
    public static var layout: StorageLayout { StorageLayout(container: container) }

    public static var accountsFile: URL { layout.accountsFile }

    public static var certificates: URL { layout.certificates }

    public static func accountDirectory(_ id: AccountID) -> URL { layout.accountDirectory(id) }

    public static func database(_ id: AccountID) -> URL { layout.database(id) }

    public static func featuresFile(_ id: AccountID) -> URL { layout.featuresFile(id) }

    public static func previews(_ id: AccountID) -> URL { layout.previews(id) }

    public static func originals(_ id: AccountID) -> URL { layout.originals(id) }

    public static func offline(_ id: AccountID) -> URL { layout.offline(id) }

    public static var logs: URL { layout.logs }
}

/// Where things live below a container directory. The app uses `AppPaths.layout`; tests use a temporary directory.
public struct StorageLayout: Sendable, Hashable {
    public let container: URL

    public init(container: URL) {
        self.container = container
    }

    public var accountsFile: URL { container.appending(path: "Library/Application Support/accounts.json") }

    /// Server certificates the user trusted (`<host>.der`).
    public var certificates: URL { container.appending(path: "Library/Application Support/Certificates") }

    /// Backup options; they belong to one account (`BackupSettings.accountId`).
    public var backupSettingsFile: URL { container.appending(path: "Library/Application Support/backup.json") }

    public func accountDirectory(_ id: AccountID) -> URL {
        container.appending(path: "Library/Application Support/Accounts/\(id.storageKey)")
    }

    public func database(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "library.sqlite") }

    public func featuresFile(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "features.json") }

    public func previews(_ id: AccountID) -> URL {
        container.appending(path: "Library/Caches/Previews/\(id.storageKey)")
    }

    public func originals(_ id: AccountID) -> URL {
        container.appending(path: "Library/Caches/Originals/\(id.storageKey)")
    }

    public func offline(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "Offline") }

    public var logs: URL { container.appending(path: "Library/Logs") }
}
