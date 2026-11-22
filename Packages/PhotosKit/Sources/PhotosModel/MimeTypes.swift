// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum MimeTypes {
    /// Images the Photos server app shows on upstream master (`Application::IMAGE_MIMES`).
    public static let defaultImages = ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/avif"]
    /// Videos the Photos server app shows on upstream master (`Application::VIDEO_MIMES`).
    public static let defaultVideos = ["video/mp4", "video/quicktime"]
    /// Added by the extended server (more-media-formats branch).
    public static let extendedImages = ["image/gif"]
    public static let extendedVideos = ["video/webm", "video/x-m4v", "video/x-matroska"]
    /// Shown by the app in addition to the server list (SPEC §5.3, "Show RAW files").
    public static let appleExtras = ["image/tiff", "image/x-dcraw"]

    public static func kind(of mime: String) -> MediaKind? {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        return nil
    }

    /// Formats AVFoundation can't play; they need the server rendition or a download.
    public static let unplayableVideos: Set<String> = ["video/webm", "video/x-matroska", "video/x-msvideo"]

    public static func isRaw(_ mime: String) -> Bool { mime == "image/x-dcraw" || mime == "image/x-adobe-dng" }

    /// MIME type for a file extension, for uploads.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "gif": "image/gif"
        case "tif", "tiff": "image/tiff"
        case "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2": "image/x-dcraw"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        case "webm": "video/webm"
        case "mkv": "video/x-matroska"
        default: "application/octet-stream"
        }
    }
}
