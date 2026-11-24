// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where backup uploads go, compared with the folders the timeline shows (Photos' `photosSourceFolders`).
///
/// Uploads into a folder outside those never appear in the library: the user would think backup is broken. The Backup
/// screen therefore only offers folders the timeline shows, and warns about a folder chosen earlier that it doesn't show.
public enum BackupFolder {
    /// A user path in one spelling: leading slash, no trailing or doubled slashes, no `.` parts. `""` and `"/"` are the
    /// root.
    public static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return "/" + parts.joined(separator: "/")
    }

    /// True when the timeline shows what is uploaded into `folder`: it is one of the timeline folders or below one of
    /// them. Comparison is by whole path components (`/Photos2` is not below `/Photos`) and case-sensitive, like the
    /// server's paths.
    public static func isShown(_ folder: String, inTimelineFolders timelineFolders: [String]) -> Bool {
        let folder = normalized(folder)
        return timelineFolders.contains { root in
            let root = normalized(root)
            return root == "/" || folder == root || folder.hasPrefix(root + "/")
        }
    }

    /// The folder to propose instead of one the timeline does not show: Photos' upload folder when the timeline shows it,
    /// else the first timeline folder (not the root of all files: backups don't belong there). Nil when there is none.
    public static func suggestion(photosLocation: String, timelineFolders: [String]) -> String? {
        if isShown(photosLocation, inTimelineFolders: timelineFolders) { return normalized(photosLocation) }
        return timelineFolders.map(normalized).first { $0 != "/" }
    }
}
