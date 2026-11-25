// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a new capture time and position into a photo's own metadata (SPEC §16.4 batch fixes on servers without
/// metadata editing): the file is uploaded again as a new version, and the server reads the new values like those of
/// any photo. Only metadata is rewritten (`CGImageDestinationCopyImageSource`), the image data is not encoded again.
public enum MetadataRewriter {
    /// What to change; nil fields stay as they are.
    public struct Change: Hashable, Sendable {
        public var capturedAt: Date?
        /// UTC offset (seconds) the capture time is written in; nil writes it in UTC without an offset field.
        public var offset: Int?
        public var latitude: Double?
        public var longitude: Double?
        public var altitude: Double?
        public var removeLocation: Bool

        public init(
            capturedAt: Date? = nil, offset: Int? = nil, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil,
            removeLocation: Bool = false
        ) {
            self.capturedAt = capturedAt
            self.offset = offset
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.removeLocation = removeLocation
        }
    }

    /// Formats ImageIO rewrites without encoding the picture again.
    public static let writableTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    public static func canRewrite(fileName: String) -> Bool {
        guard let type = UTType(filenameExtension: (fileName as NSString).pathExtension) else { return false }
        return writableTypes.contains { type.conforms(to: $0) }
    }

    /// `2024:06:14 09:12:00` and `+02:00` for a date in an offset.
    public static func exifStrings(_ date: Date, offset: Int?) -> (date: String, offset: String?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset ?? 0) ?? .gmt
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let offset else { return (formatter.string(from: date), nil) }
        let sign = offset < 0 ? "-" : "+"
        let value = abs(offset)
        return (formatter.string(from: date), String(format: "%@%02d:%02d", sign, value / 3600, (value % 3600) / 60))
    }

    /// A copy of `file` in `directory` with the change written into its metadata; nil when the format cannot take it.
    public static func rewrite(_ file: URL, with change: Change, in directory: URL) -> URL? {
        guard canRewrite(fileName: file.lastPathComponent),
            let source = CGImageSourceCreateWithURL(file as CFURL, nil), let sourceType = CGImageSourceGetType(source)
        else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
            _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFTypeRef)
        }
        if let date = change.capturedAt {
            let strings = exifStrings(date, offset: change.offset)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, strings.date)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, strings.date)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, strings.date)
            if let offset = strings.offset {
                set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offset)
                set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeDigitized, offset)
                set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTime, offset)
            }
        }
        if !change.removeLocation, let latitude = change.latitude, let longitude = change.longitude {
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(latitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, latitude < 0 ? "S" : "N")
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(longitude))
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, longitude < 0 ? "W" : "E")
            if let altitude = change.altitude {
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitude, abs(altitude))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitudeRef, altitude < 0 ? 1 : 0)
            }
        }
        let folder = directory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: file.lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, sourceType, 1, nil) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        if change.removeLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return target
    }

    /// What a file says now (tests and the preview): capture time string, offset string and position.
    public static func read(_ file: URL) -> (date: String?, offset: String?, latitude: Double?, longitude: Double?) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (nil, nil, nil, nil) }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var latitude = gps[kCGImagePropertyGPSLatitude] as? Double
        var longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = latitude.map { -$0 } }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = longitude.map { -$0 } }
        return (
            exif[kCGImagePropertyExifDateTimeOriginal] as? String, exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, latitude,
            longitude
        )
    }
}
