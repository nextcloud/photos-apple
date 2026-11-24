// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What a Google Takeout JSON sidecar says about a photo or video.
public struct TakeoutMetadata: Hashable, Sendable {
    /// `photoTakenTime.timestamp`: the capture time Google Photos shows.
    public var takenAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    /// The caption the user wrote in Google Photos.
    public var description: String?

    public init(
        takenAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil, description: String? = nil
    ) {
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.description = description
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// Matches media files of a Takeout export to their JSON sidecars and reads them. The same rules as the Photos server's
/// `occ photos:import-takeout-metadata` (`TakeoutSidecarService`): truncated sidecar names, `(1)` copy suffixes after the
/// extension, `.supplemental-metadata` (also cut short), edited copies and Live Photo videos sharing the picture's sidecar.
public enum TakeoutSidecars {
    /// Sidecars are small; anything bigger is not one.
    static let maxSidecarSize: UInt64 = 1 << 20
    static let supplementalSuffix = "supplemental-metadata"
    /// Takeout cuts sidecar names longer than about 46 characters; the exact limit varied between exports.
    static let minTruncatedLength = 40
    /// Suffixes Google Photos appends to edited copies, per language.
    static let editedSuffixes = [
        "-edited", "-effects", "-smile", "-mix", "-bearbeitet", "-bewerkt", "-modifié", "-modificato", "-ha editado", "-editat",
        "-edytowane", "-編集済み",
    ]
    static let livePhotoExtensions = ["HEIC", "heic", "JPG", "jpg", "JPEG", "jpeg"]
    static let videoExtensions: Set<String> = ["mp4", "mov"]

    /// Sidecar names of one folder, by copy suffix (`""`, `"(1)"` …) and by the name of the file they describe (as far
    /// as it survived truncation).
    public typealias Index = [String: [String: String]]

    public static func isSidecarName(_ name: String) -> Bool { name.lowercased().hasSuffix(".json") }

    public static func index(_ names: some Sequence<String>) -> Index {
        var sidecars: Index = [:]
        for name in names where isSidecarName(name) {
            var described = String(name.dropLast(5))
            var copySuffix = ""
            if let match = described.wholeMatch(of: /(.+)(\(\d+\))/) {
                described = String(match.1)
                copySuffix = String(match.2)
            }
            // "IMG_1234.jpg.supplemental-metadata", possibly cut down to "IMG_1234.jpg.s".
            if let dot = described.lastIndex(of: ".") {
                let tail = described[described.index(after: dot)...]
                if !tail.isEmpty && supplementalSuffix.hasPrefix(tail) { described = String(described[..<dot]) }
            }
            if sidecars[copySuffix]?[described] == nil { sidecars[copySuffix, default: [:]][described] = name }
        }
        return sidecars
    }

    /// The name of the sidecar of a media file in the same folder, when there is one.
    public static func sidecar(for mediaName: String, in sidecars: Index) -> String? {
        var described = describedNames(mediaName)
        // Exact names first: a truncated name may be shared by several files.
        for (name, copySuffix) in described {
            if let sidecar = sidecars[copySuffix]?[name] { return sidecar }
        }
        // Truncation may have cut off the copy suffix of the media name; the sidecar's suffix tells copies apart.
        described = described.filter { !$0.1.isEmpty } + described.filter { $0.1.isEmpty }
        for (name, copySuffix) in described {
            if let sidecar = shortenedSidecar(sidecars[copySuffix] ?? [:], name) { return sidecar }
        }
        return nil
    }

    /// The names whose sidecar may describe a media file, most specific first, with their copy suffix.
    ///
    /// Copies have the suffix in the media name (`IMG_1234(1).jpg`) but after the extension in the sidecar's name
    /// (`IMG_1234.jpg(1).json`). Edited pictures and the videos of Live Photos share the original picture's sidecar.
    static func describedNames(_ mediaName: String) -> [(String, String)] {
        var candidates = [(mediaName, "")]
        let ext = (mediaName as NSString).pathExtension
        var base = ext.isEmpty ? mediaName : String(mediaName.dropLast(ext.count + 1))
        let dotExt = ext.isEmpty ? "" : "." + ext
        var copySuffix = ""
        if let match = base.wholeMatch(of: /(.+)(\(\d+\))/) {
            base = String(match.1)
            copySuffix = String(match.2)
            candidates.append((base + dotExt, copySuffix))
        }
        for suffix in editedSuffixes where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            candidates.append((base + dotExt, copySuffix))
            break
        }
        if videoExtensions.contains(ext.lowercased()) {
            for pictureExtension in livePhotoExtensions { candidates.append((base + "." + pictureExtension, copySuffix)) }
        }
        return candidates
    }

    static func shortenedSidecar(_ sidecars: [String: String], _ described: String) -> String? {
        let characters = Array(described)
        var length = characters.count - 1
        while length >= minTruncatedLength {
            if let sidecar = sidecars[String(characters[..<length])] { return sidecar }
            length -= 1
        }
        // Some exports leave the extension out: "IMG_1234.json".
        let withoutExtension = (described as NSString).deletingPathExtension
        if withoutExtension != described, let sidecar = sidecars[withoutExtension] { return sidecar }
        return nil
    }

    /// Reads a sidecar. Nil when it holds neither a capture time, a position nor a description.
    public static func parse(_ data: Data) -> TakeoutMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var metadata = TakeoutMetadata()
        if let taken = object["photoTakenTime"] as? [String: Any], let seconds = timestamp(taken["timestamp"]) {
            metadata.takenAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if let position = coordinates(object["geoData"]) ?? coordinates(object["geoDataExif"]) {
            metadata.latitude = position.latitude
            metadata.longitude = position.longitude
            metadata.altitude = position.altitude
        }
        if let text = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            metadata.description = text
        }
        return metadata.takenAt == nil && !metadata.hasLocation && metadata.description == nil ? nil : metadata
    }

    static func timestamp(_ value: Any?) -> Int64? {
        let number: Int64?
        if let string = value as? String {
            number = Int64(string)
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.int64Value
        } else {
            number = nil
        }
        guard let number, number > 0 else { return nil }
        return number
    }

    /// Takeout writes 0.0 for both coordinates of media without a position.
    static func coordinates(_ value: Any?) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        guard let geo = value as? [String: Any], let latitude = number(geo["latitude"]), let longitude = number(geo["longitude"]) else {
            return nil
        }
        if (latitude == 0 && longitude == 0) || abs(latitude) > 90 || abs(longitude) > 180 { return nil }
        let altitude = number(geo["altitude"]).flatMap { $0 == 0 ? nil : $0 }
        return (latitude, longitude, altitude)
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    /// The title of an album folder from its `metadata.json` (`{"title": "Trip to Lisbon", …}`).
    public static func albumTitle(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return title
    }
}
