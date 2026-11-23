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

    /// Short format name for people ("JPEG", "HEIC", "MOV"), instead of the raw MIME type.
    ///
    /// Container and RAW types that say little on their own use the file extension (`image/x-dcraw` → "CR2").
    public static func formatName(mimeType: String, fileName: String = "") -> String {
        let mime = mimeType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let ext = (fileName as NSString).pathExtension.uppercased()
        switch mime {
        case "image/jpeg", "image/jpg", "image/pjpeg": return "JPEG"
        case "image/png": return "PNG"
        case "image/heic", "image/heic-sequence": return "HEIC"
        case "image/heif", "image/heif-sequence": return "HEIF"
        case "image/webp": return "WebP"
        case "image/avif": return "AVIF"
        case "image/gif": return "GIF"
        case "image/tiff": return "TIFF"
        case "image/bmp": return "BMP"
        case "image/svg+xml": return "SVG"
        case "image/jxl": return "JPEG XL"
        case "image/x-adobe-dng": return "DNG"
        case "image/x-dcraw": return ext.isEmpty ? "RAW" : ext
        case "video/mp4": return "MP4"
        case "video/quicktime": return "MOV"
        case "video/x-m4v": return "M4V"
        case "video/webm": return "WebM"
        case "video/x-matroska": return "MKV"
        case "video/x-msvideo": return "AVI"
        case "video/mpeg": return "MPEG"
        case "video/3gpp": return "3GP"
        default: break
        }
        if !ext.isEmpty && ext.count <= 5 { return ext }
        guard let subtype = mime.split(separator: "/").last, mime.contains("/") else { return mimeType }
        let name = subtype.hasPrefix("x-") ? subtype.dropFirst(2) : subtype
        return name.isEmpty || mime == "application/octet-stream" ? mimeType : name.uppercased()
    }

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
