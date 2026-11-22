// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// File locations. Uses the App Group container when available (shared with extensions), else Application Support.
public enum AppPaths {
    public static let appGroup = "group.com.nextcloud.photos"

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

    public static var accountsFile: URL { container.appending(path: "Library/Application Support/accounts.json") }

    public static var certificates: URL { container.appending(path: "Library/Application Support/Certificates") }

    public static func accountDirectory(_ id: AccountID) -> URL {
        container.appending(path: "Library/Application Support/Accounts/\(id.storageKey)")
    }

    public static func database(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "library.sqlite") }

    public static func featuresFile(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "features.json") }

    public static func previews(_ id: AccountID) -> URL {
        container.appending(path: "Library/Caches/Previews/\(id.storageKey)")
    }

    public static func originals(_ id: AccountID) -> URL {
        container.appending(path: "Library/Caches/Originals/\(id.storageKey)")
    }

    public static func offline(_ id: AccountID) -> URL { accountDirectory(id).appending(path: "Offline") }

    public static var logs: URL { container.appending(path: "Library/Logs") }
}
