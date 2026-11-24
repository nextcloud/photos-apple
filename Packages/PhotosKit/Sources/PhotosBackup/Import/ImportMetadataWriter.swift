// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Puts what an export knows about a photo into the photo's own metadata when the file lacks it (SPEC §15.7): the
/// capture time (EXIF `DateTimeOriginal` with its offset), the position (GPS) and the caption (IPTC `Caption/Abstract`,
/// and `ImageDescription` where the format keeps it).
/// Facebook and Instagram remove these from their copies; Google and Apple keep them, so their files mostly stay as
/// they are. The server reads them like those of any photo, and they travel with the file wherever it goes.
///
/// Only metadata is rewritten (`CGImageDestinationCopyImageSource`): the image data is not encoded again. Formats ImageIO
/// cannot write that way (WebP, GIF, videos) are uploaded unchanged; the capture time still arrives as the file's time.
enum ImportMetadataWriter {
    /// What a file's metadata already has.
    struct Present: Equatable {
        var captureDate: Date?
        var hasCaptureTime: Bool
        var hasLocation: Bool
        var hasDescription: Bool
        var pixelWidth: Int?
        var pixelHeight: Int?
    }

    static let writableTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    static func present(in file: URL) -> Present? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        // ImageIO keeps a JPEG's caption in IPTC (`Caption/Abstract`); TIFF-based formats also in `ImageDescription`.
        let description =
            ((tiff[kCGImagePropertyTIFFImageDescription] as? String) ?? (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String))?
            .trimmingCharacters(in: .whitespaces)
        return Present(
            captureDate: original.flatMap { exifDate($0, offset: offset) }, hasCaptureTime: original != nil,
            hasLocation: gps[kCGImagePropertyGPSLatitude] != nil && gps[kCGImagePropertyGPSLongitude] != nil,
            hasDescription: description?.isEmpty == false, pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int)
    }

    /// `2023:10:07 16:52:20` with `+02:00`; without an offset in the device's time zone (as the server reads it).
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, let zone = timeZone(offset) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = .current
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    static func timeZone(_ offset: String) -> TimeZone? {
        guard let match = offset.wholeMatch(of: /([+-])(\d{2}):?(\d{2})/), let hours = Int(match.2), let minutes = Int(match.3) else {
            return nil
        }
        return TimeZone(secondsFromGMT: (match.1 == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    /// `+02:00` for an offset in seconds.
    static func offsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let value = abs(seconds)
        return String(format: "%@%02d:%02d", sign, value / 3600, (value % 3600) / 60)
    }

    /// A copy of `file` in `directory` with what is missing added, or nil when nothing is missing or the format cannot
    /// take it. The capture time is written only when it is one (not a posting time).
    static func addMissing(to file: URL, metadata: ImportMetadata, in directory: URL, timeZone: TimeZone = .current) -> URL? {
        guard let type = UTType(filenameExtension: file.pathExtension), writableTypes.contains(where: { type.conforms(to: $0) }),
            let present = present(in: file)
        else { return nil }
        let addTime = !present.hasCaptureTime && metadata.isCaptureTime
        let addLocation = !present.hasLocation && metadata.hasLocation
        let addCaption = !present.hasDescription && metadata.caption != nil
        guard addTime || addLocation || addCaption else { return nil }
        let added = CGImageMetadataCreateMutable()
        func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
            _ = CGImageMetadataSetValueMatchingImageProperty(added, dictionary, key, value as CFTypeRef)
        }
        if addTime, let date = metadata.takenAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let text = formatter.string(from: date)
            let offset = offsetString(timeZone.secondsFromGMT(for: date))
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, text)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, text)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offset)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeDigitized, offset)
        }
        if addLocation, let latitude = metadata.latitude, let longitude = metadata.longitude {
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(latitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, latitude < 0 ? "S" : "N")
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(longitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, longitude < 0 ? "W" : "E")
            if let altitude = metadata.altitude {
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitude, abs(altitude))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitudeRef, altitude < 0 ? 1 : 0)
            }
        }
        if addCaption, let caption = metadata.caption {
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, caption)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, caption)
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let sourceType = CGImageSourceGetType(source) else { return nil }
        let folder = directory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: file.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, sourceType, 1, nil) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: added, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return target
    }
}
