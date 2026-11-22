// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Backup options (SPEC §7.18.2).
public struct BackupSettings: Codable, Hashable, Sendable {
    public enum Subfolders: String, Codable, Sendable, CaseIterable {
        case none, year, yearMonth, yearMonthDay
    }

    public enum Naming: Codable, Hashable, Sendable {
        /// `IMG_1234.HEIC` (the asset's original file name).
        case original
        /// Like the Nextcloud Files app: `yy-MM-dd HH-mm-ss NNNN.ext`, optional "Photo "/"Video " prefix, or a custom mask.
        case filesApp(typePrefix: Bool, mask: String?)
    }

    public enum Format: String, Codable, Sendable, CaseIterable {
        /// HEIC, HEVC, ProRAW as they are.
        case original
        /// JPEG / H.264.
        case mostCompatible
    }

    public enum Edits: String, Codable, Sendable, CaseIterable {
        case originalAndEdited, editedOnly, originalOnly
    }

    /// How the user relates to the Files app's auto upload (SPEC §7.18.1).
    public enum FilesAppMode: String, Codable, Sendable {
        case notUsed
        case switchedFromFiles
        case keepFiles
    }

    public var isEnabled = false
    public var accountId: AccountID?
    public var folder = "/Photos"
    public var subfolders: Subfolders = .yearMonth
    public var naming: Naming = .original
    public var format: Format = .original
    public var edits: Edits = .originalAndEdited
    public var livePhotos = true
    public var photos = true
    public var videos = true
    /// Only assets created on or after this date (nil = whole library).
    public var since: Date?
    /// Local identifiers of device albums to back up (empty = whole library).
    public var albumIdentifiers: [String] = []
    public var includeSharedLibrary = true
    public var wifiOnlyForVideos = true
    public var wifiOnly = false
    public var allowLowDataMode = false
    public var pauseInLowPowerMode = true
    public var downloadFromICloud = true
    public var filesAppMode: FilesAppMode = .notUsed

    public init() {}

    /// The Files app's default folder layout and naming, used when switching from Files (SPEC §7.18.5).
    public mutating func adoptFilesAppDefaults(_ files: FilesAppSettings) {
        folder = files.folder ?? "/Photos"
        subfolders = .yearMonth
        naming = files.fileNameOriginal ? .original : .filesApp(typePrefix: files.fileNameType, mask: files.fileNameMask)
        format = files.formatCompatibility ? .mostCompatible : .original
        livePhotos = files.livePhoto
    }

    public static func load(from url: URL) -> BackupSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else {
            return BackupSettings()
        }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// What the Nextcloud Files app uses for auto upload (read from its App Group defaults when available).
public struct FilesAppSettings: Hashable, Sendable {
    public var folder: String?
    public var fileNameOriginal = false
    public var fileNameType = false
    public var fileNameMask: String?
    public var formatCompatibility = true
    public var livePhoto = true

    public init(
        folder: String? = nil, fileNameOriginal: Bool = false, fileNameType: Bool = false, fileNameMask: String? = nil,
        formatCompatibility: Bool = true, livePhoto: Bool = true
    ) {
        self.folder = folder
        self.fileNameOriginal = fileNameOriginal
        self.fileNameType = fileNameType
        self.fileNameMask = fileNameMask
        self.formatCompatibility = formatCompatibility
        self.livePhoto = livePhoto
    }
}
