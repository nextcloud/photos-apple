// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

// MARK: - EXIF facts

/// What Insights knows of a photo's capture (SPEC §16.5.1): read from the server's EXIF (`nc:metadata-photos-exif` and
/// `-ifd0`, a flat `tag → value` map) and kept in the local index (`InsightsStore`).
public struct ExifFacts: Hashable, Sendable, Codable {
    /// "Nikon D700", "iPhone 14 Pro" (`ExifFacts.cameraName`).
    public var camera: String?
    public var lens: String?
    /// The real focal length in millimetres.
    public var focalLength: Double?
    /// The 35 mm equivalent, when the camera wrote it.
    public var focalLength35: Double?
    /// The f-number (2.8 for ƒ/2.8).
    public var aperture: Double?
    public var iso: Int?
    /// Exposure time in seconds.
    public var exposure: Double?
    /// The hour of the day on the camera's clock (0–23): the local time where the photo was taken.
    public var hour: Int?

    public init(
        camera: String? = nil, lens: String? = nil, focalLength: Double? = nil, focalLength35: Double? = nil, aperture: Double? = nil,
        iso: Int? = nil, exposure: Double? = nil, hour: Int? = nil
    ) {
        self.camera = camera
        self.lens = lens
        self.focalLength = focalLength
        self.focalLength35 = focalLength35
        self.aperture = aperture
        self.iso = iso
        self.exposure = exposure
        self.hour = hour
    }

    /// The focal length the charts use: the 35 mm equivalent where the camera wrote one (phones, compacts), else the
    /// real one (most interchangeable-lens cameras write only that).
    public var chartFocalLength: Double? { focalLength35 ?? focalLength }

    public var isEmpty: Bool { self == ExifFacts() }

    /// The facts in a server's EXIF tags. Values come as rationals ("28/10"), numbers, or text; anything that does not
    /// make sense (0, negative, absurd) is left out rather than shown.
    public static func parse(_ tags: [String: String]) -> ExifFacts {
        var facts = ExifFacts()
        facts.camera = cameraName(make: tags["Make"], model: tags["Model"])
        facts.lens = lensName(first(tags, ["LensModel", "UndefinedTag:0xA434", "UndefinedTag_0xA434", "Lens"]))
        if let value = number(tags["FocalLength"]), value > 0.5, value < 5000 { facts.focalLength = value }
        if let value = number(first(tags, ["FocalLengthIn35mmFilm", "FocalLengthIn35mmFormat"])), value >= 5, value < 5000 {
            facts.focalLength35 = value
        }
        if let value = number(tags["FNumber"]), value >= 0.5, value <= 128 {
            facts.aperture = value
        } else if let apex = number(tags["ApertureValue"]), apex > -2, apex < 20 {
            // APEX: N = 2^(Av/2).
            let value = pow(2, apex / 2)
            if value >= 0.5, value <= 128 { facts.aperture = value }
        }
        if let raw = first(tags, ["ISOSpeedRatings", "PhotographicSensitivity", "ISOSpeed"]), let value = number(raw), value >= 1,
            value < 10_000_000
        {
            facts.iso = Int(value.rounded())
        }
        if let value = number(tags["ExposureTime"]), value > 0, value <= 3600 {
            facts.exposure = value
        } else if let apex = number(tags["ShutterSpeedValue"]), apex > -12, apex < 20 {
            // APEX: t = 2^-Tv.
            facts.exposure = pow(2, -apex)
        }
        facts.hour = first(tags, ["DateTimeOriginal", "DateTimeDigitized", "DateTime"]).flatMap(hour(ofExifDate:))
        return facts
    }

    static func first(_ tags: [String: String], _ names: [String]) -> String? {
        for name in names {
            if let value = tags[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    /// `"28/10"` → 2.8, `"100"` → 100; nil for "0/0" and text.
    public static func number(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)), denominator != 0
            else { return nil }
            let value = numerator / denominator
            return value.isFinite ? value : nil
        }
        guard let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    /// The hour of `"2024:06:14 09:12:30"` (EXIF's local time without zone).
    static func hour(ofExifDate raw: String) -> Int? {
        guard let match = raw.firstMatch(of: /^\d{4}[:\-]\d{2}[:\-]\d{2}[ T](\d{2}):(\d{2})/), let hour = Int(match.1), hour < 24
        else { return nil }
        // Cameras whose clock was never set write "0000:00:00 00:00:00"; that hour means nothing.
        if raw.hasPrefix("0000") { return nil }
        return hour
    }

    /// Makers as people say them, for the names cameras write ("NIKON CORPORATION", "OLYMPUS IMAGING CORP.").
    static let brands: [String: String] = [
        "nikon": "Nikon", "canon": "Canon", "sony": "Sony", "fujifilm": "Fujifilm", "fuji": "Fujifilm", "olympus": "Olympus",
        "om": "OM System", "panasonic": "Panasonic", "leica": "Leica", "ricoh": "Ricoh", "pentax": "Pentax",
        "samsung": "Samsung", "google": "Google", "huawei": "Huawei", "xiaomi": "Xiaomi", "oneplus": "OnePlus", "dji": "DJI",
        "gopro": "GoPro", "hasselblad": "Hasselblad", "sigma": "Sigma", "kodak": "Kodak", "motorola": "Motorola",
        "nokia": "Nokia", "lg": "LG", "htc": "HTC", "minolta": "Minolta", "konica": "Konica Minolta", "casio": "Casio",
        "apple": "Apple", "phase": "Phase One", "blackmagic": "Blackmagic", "insta360": "Insta360", "nothing": "Nothing",
        "oppo": "OPPO", "vivo": "vivo", "realme": "realme", "honor": "HONOR",
    ]

    /// "Nikon D700" from "NIKON CORPORATION" / "NIKON D700"; "iPhone 14 Pro" from "Apple" / "iPhone 14 Pro"; "Sony
    /// ILCE-7RM3" from "SONY" / "ILCE-7RM3". The maker is said once, in its usual spelling.
    public static func cameraName(make rawMake: String?, model rawModel: String?) -> String? {
        let make = (rawMake ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        var model = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let makeWord = make.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" }).first.map { String($0).lowercased() }
        let brand: String? = makeWord.map { brands[$0] ?? make }
        guard !model.isEmpty else { return brand.flatMap { $0.isEmpty ? nil : $0 } }
        // A model that repeats the maker: the maker's word becomes its usual spelling ("NIKON D700" → "Nikon D700").
        let modelWord = model.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        if let known = brands[modelWord], makeWord == nil || makeWord == modelWord || brands[makeWord ?? ""] == known {
            model = known + model.dropFirst(modelWord.count)
            return model
        }
        guard let brand, !brand.isEmpty else { return model }
        // Apple's models name themselves ("iPhone 14 Pro", "iPad Air").
        if brand == "Apple" { return model }
        if model.range(of: brand, options: [.caseInsensitive, .anchored]) != nil { return model }
        if let makeWord, modelWord == makeWord { return model }
        return "\(brand) \(model)"
    }

    /// A lens name, or nil for the placeholders some cameras write ("----", "0", "Unknown").
    static func lensName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard trimmed.count >= 2, trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let placeholders: Set<String> = ["0", "----", "unknown", "n/a", "none", "lens"]
        guard !placeholders.contains(trimmed.lowercased()), !trimmed.allSatisfy({ $0 == "-" || $0 == "0" }) else { return nil }
        return trimmed
    }
}

// MARK: - Scales

/// The steps a photographer thinks in: focal lengths of common lenses, f-stops in thirds, ISO and shutter speeds in
/// full stops. A value belongs to the nearest step on a logarithmic scale (the way exposure works), so 1/320 s counts
/// as 1/250 s and ƒ/1.7 as ƒ/1.8.
public struct StopScale: Sendable, Hashable {
    public let stops: [Double]

    public init(stops: [Double]) {
        self.stops = stops.sorted()
    }

    /// The step a value belongs to.
    public func stop(for value: Double) -> Double {
        stops[index(for: value)]
    }

    func index(for value: Double) -> Int {
        guard value > 0 else { return 0 }
        let target = log(value)
        var best = 0
        var distance = Double.infinity
        for (index, stop) in stops.enumerated() {
            let current = abs(log(stop) - target)
            if current < distance {
                distance = current
                best = index
            }
        }
        return best
    }

    /// The values that belong to a step: from the geometric middle to the step below to the one to the step above
    /// (lower bound included). The first step takes everything below it, the last everything above.
    public func range(of stop: Double) -> (lower: Double, upper: Double) {
        let index = index(for: stop)
        let lower = index == 0 ? 0 : (stops[index - 1] * stops[index]).squareRoot()
        let upper = index == stops.count - 1 ? Double.infinity : (stops[index] * stops[index + 1]).squareRoot()
        return (lower, upper)
    }

    /// Focal lengths in millimetres: phone lenses (4–6 mm real), then the classic primes and zoom ends.
    public static let focalLength = StopScale(stops: [
        2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 35, 40, 50, 60, 70, 85, 105, 135, 150, 200, 300, 400, 500, 600, 800, 1200,
    ])
    /// f-numbers in thirds of a stop, as cameras set them.
    public static let aperture = StopScale(stops: [
        0.95, 1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22,
        25, 29, 32, 45, 64,
    ])
    /// ISO in full stops.
    public static let iso = StopScale(stops: [25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102_400])
    /// Shutter speeds in full stops, in seconds (1/8000 s … 30 s).
    public static let shutter = StopScale(stops: [
        1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8,
        1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 15, 30,
    ])
}

// MARK: - Filters

/// What a tap on a bar of Insights opens: the photos with that camera, lens, focal length… (SPEC §16.5.1).
public enum InsightsFilter: Hashable, Sendable, Codable {
    case camera(String)
    case lens(String)
    /// A step of `StopScale.focalLength` (35 for "35 mm"), on `ExifFacts.chartFocalLength`.
    case focalLength(Double)
    case aperture(Double)
    case iso(Double)
    case shutter(Double)
    case hour(Int)
    /// The keepers (`PhotoInsights.isKeeper`) taken with a lens (or, for photos without a lens name, a camera).
    case keepers(lens: String?, camera: String?)

    /// Whether a photo with these facts and this mark belongs to the filter (`InsightsStore` asks the database the
    /// same).
    public func matches(_ facts: ExifFacts, mark: CullingMark = .none) -> Bool {
        func inside(_ value: Double?, _ scale: StopScale, _ stop: Double) -> Bool {
            guard let value else { return false }
            let range = scale.range(of: stop)
            return value >= range.lower && value < range.upper
        }
        switch self {
        case .camera(let name): return facts.camera == name
        case .lens(let name): return facts.lens == name
        case .focalLength(let stop): return inside(facts.chartFocalLength, .focalLength, stop)
        case .aperture(let stop): return inside(facts.aperture, .aperture, stop)
        case .iso(let stop): return inside(facts.iso.map(Double.init), .iso, stop)
        case .shutter(let stop): return inside(facts.exposure, .shutter, stop)
        case .hour(let hour): return facts.hour == hour
        case .keepers(let lens, let camera):
            guard PhotoInsights.isKeeper(mark) else { return false }
            if let lens { return facts.lens == lens }
            return facts.lens == nil && facts.camera == camera
        }
    }
}

// MARK: - Summary

/// One bar of a chart: a camera, a lens or a step of a scale, and how many photos it has.
public struct InsightsBar<Key: Hashable & Sendable>: Hashable, Sendable, Identifiable {
    public var key: Key
    public var count: Int
    public var id: Key { key }

    public init(key: Key, count: Int) {
        self.key = key
        self.count = count
    }
}

/// How many of the photos taken with a lens (or a camera) were kept.
public struct KeeperRate: Hashable, Sendable, Identifiable {
    /// The lens, or nil for the photos of `camera` without a lens name (phones, compacts, older cameras).
    public var lens: String?
    public var camera: String?
    public var total: Int
    public var keepers: Int
    public var id: String { "\(lens ?? "")|\(camera ?? "")" }

    public init(lens: String?, camera: String?, total: Int, keepers: Int) {
        self.lens = lens
        self.camera = camera
        self.total = total
        self.keepers = keepers
    }

    public var rate: Double { total == 0 ? 0 : Double(keepers) / Double(total) }

    public var filter: InsightsFilter { .keepers(lens: lens, camera: lens == nil ? camera : nil) }
}

/// A photo of the library as Insights sees it.
public struct InsightsRow: Hashable, Sendable {
    public var facts: ExifFacts
    public var mark: CullingMark

    public init(facts: ExifFacts, mark: CullingMark = .none) {
        self.facts = facts
        self.mark = mark
    }
}

/// Everything the Insights screen shows.
public struct InsightsSummary: Hashable, Sendable {
    /// Photos whose EXIF was read (with or without camera data).
    public var analysed = 0
    /// Photos with any camera data at all.
    public var withCameraData = 0
    /// Rated or flagged photos.
    public var reviewed = 0
    public var keepers = 0
    /// Most used first.
    public var cameras: [InsightsBar<String>] = []
    public var lenses: [InsightsBar<String>] = []
    /// In the order of the scale (short to long, open to closed, low to high, fast to slow).
    public var focalLengths: [InsightsBar<Double>] = []
    public var apertures: [InsightsBar<Double>] = []
    public var isos: [InsightsBar<Double>] = []
    public var shutterSpeeds: [InsightsBar<Double>] = []
    /// 24 counts, midnight first.
    public var hours: [Int] = Array(repeating: 0, count: 24)
    /// Best rate first; only lenses with enough photos to say something (`PhotoInsights.minimumForRate`).
    public var keeperRates: [KeeperRate] = []

    public init() {}

    public var isEmpty: Bool { withCameraData == 0 }
}

public enum PhotoInsights {
    /// The lens, or for photos without a lens name the camera, that a keeper rate is about.
    struct RateKey: Hashable {
        var lens: String?
        var camera: String?
    }

    /// A keeper: picked, or rated three stars or more without being rejected (SPEC §16.5.1).
    public static func isKeeper(_ mark: CullingMark) -> Bool {
        mark.flag == .pick || (mark.flag != .reject && mark.rating >= 3)
    }

    /// Below this many photos a lens's keeper rate is noise.
    public static let minimumForRate = 5

    public static func summarize(_ rows: some Sequence<InsightsRow>) -> InsightsSummary {
        var summary = InsightsSummary()
        var cameras: [String: Int] = [:]
        var lenses: [String: Int] = [:]
        var focal: [Double: Int] = [:]
        var aperture: [Double: Int] = [:]
        var iso: [Double: Int] = [:]
        var shutter: [Double: Int] = [:]
        var rates: [RateKey: (total: Int, keepers: Int)] = [:]
        for row in rows {
            summary.analysed += 1
            let facts = row.facts
            let keeper = isKeeper(row.mark)
            if !row.mark.isEmpty { summary.reviewed += 1 }
            if keeper { summary.keepers += 1 }
            let hasCameraData =
                facts.camera != nil || facts.lens != nil || facts.chartFocalLength != nil || facts.aperture != nil || facts.iso != nil
                || facts.exposure != nil
            if hasCameraData { summary.withCameraData += 1 }
            if let camera = facts.camera { cameras[camera, default: 0] += 1 }
            if let lens = facts.lens { lenses[lens, default: 0] += 1 }
            if let value = facts.chartFocalLength { focal[StopScale.focalLength.stop(for: value), default: 0] += 1 }
            if let value = facts.aperture { aperture[StopScale.aperture.stop(for: value), default: 0] += 1 }
            if let value = facts.iso { iso[StopScale.iso.stop(for: Double(value)), default: 0] += 1 }
            if let value = facts.exposure { shutter[StopScale.shutter.stop(for: value), default: 0] += 1 }
            if let hour = facts.hour, (0..<24).contains(hour) { summary.hours[hour] += 1 }
            if facts.lens != nil || facts.camera != nil {
                let key = RateKey(lens: facts.lens, camera: facts.lens == nil ? facts.camera : nil)
                var value = rates[key] ?? (0, 0)
                value.total += 1
                if keeper { value.keepers += 1 }
                rates[key] = value
            }
        }
        func byCount(_ counts: [String: Int]) -> [InsightsBar<String>] {
            counts.map { InsightsBar(key: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        }
        func byStop(_ counts: [Double: Int]) -> [InsightsBar<Double>] {
            counts.map { InsightsBar(key: $0.key, count: $0.value) }.sorted { $0.key < $1.key }
        }
        summary.cameras = byCount(cameras)
        summary.lenses = byCount(lenses)
        summary.focalLengths = byStop(focal)
        summary.apertures = byStop(aperture)
        summary.isos = byStop(iso)
        summary.shutterSpeeds = byStop(shutter)
        // Only where something was reviewed at all: a rate of 0 % for a library nobody culled says nothing.
        if summary.reviewed > 0 {
            summary.keeperRates = rates.filter { $0.value.total >= minimumForRate }
                .map { KeeperRate(lens: $0.key.lens, camera: $0.key.camera, total: $0.value.total, keepers: $0.value.keepers) }
                .sorted {
                    if $0.rate != $1.rate { return $0.rate > $1.rate }
                    if $0.total != $1.total { return $0.total > $1.total }
                    return $0.id < $1.id
                }
        }
        return summary
    }
}
