// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// A non-destructive edit of one photo (SPEC §16.3.1): everything the editor did, as a small versioned JSON document that
/// is stored in the user's own Nextcloud (`.nextcloud-photos/edits/<fileId>.json`) and synced between devices. The
/// original file is never changed; every view renders the edited version from the original (or its preview) and this.
public struct EditRecipe: Hashable, Sendable {
    /// The newest format this app reads and writes. A recipe of a newer format (written by a newer app) is not applied
    /// and not overwritten without asking (`EditRecipe.Failure.newerFormat`).
    ///
    /// Version 2 (SPEC §21.6) added curves, the colour mixer, masks, noise reduction and RAW colour noise and detail, and
    /// removed objects (`retouch`, SPEC §21.5). A
    /// recipe is written with the lowest version that can show it (`requiredVersion`): an edit that uses none of these is
    /// still version 1, so older apps keep showing it; one that does is version 2, so an older app shows the original
    /// and says the photo was edited with a newer version instead of showing half of the edit.
    public static let currentVersion = 2
    /// `format` of every recipe: what the file is, for anybody who finds it in their files.
    public static let format = "nextcloud-photos-edit"

    /// What the original was when the edit was made. Informational (diagnostics, other clients): the edit is still
    /// applied when the original changed, as fractions and angles fit any size.
    public struct Original: Hashable, Sendable, Codable {
        public var name: String
        public var etag: String?
        public var width: Int?
        public var height: Int?

        public init(name: String, etag: String? = nil, width: Int? = nil, height: Int? = nil) {
            self.name = name
            self.etag = etag
            self.width = width
            self.height = height
        }
    }

    /// The format version the recipe was read with (1 for a new one). What a file gets is `requiredVersion`.
    public var version = 1
    /// When the user last changed the edit: of two versions of a recipe the newer one wins (`EditLibrary`).
    public var updatedAt: Date
    /// Crop, turns, straighten, mirror, auto-enhance, filter and adjustments.
    public var edits: PhotoEdits
    /// RAW decoding settings (SPEC §16.3.2); nil for a photo that is not developed from RAW.
    public var raw: RAWAdjustments?
    /// Live Photo effect and key photo (SPEC §16.3.3); nil for none.
    public var live: LivePhotoEffect?
    /// Objects removed with the Remove tool (SPEC §21.5); nil for none.
    public var retouch: RetouchSteps?
    public var original: Original?

    public init(
        edits: PhotoEdits = PhotoEdits(), raw: RAWAdjustments? = nil, live: LivePhotoEffect? = nil, original: Original? = nil,
        updatedAt: Date = Date(), retouch: RetouchSteps? = nil
    ) {
        self.edits = edits
        self.raw = raw
        self.live = live
        self.retouch = retouch
        self.original = original
        self.updatedAt = updatedAt
    }

    /// Nothing is changed: the recipe would show the original.
    public var isIdentity: Bool {
        edits.isIdentity && (raw?.isIdentity ?? true) && (live?.isIdentity ?? true) && (retouch?.isIdentity ?? true)
    }

    /// The lowest format version that shows this edit completely: what `encoded()` writes.
    public var requiredVersion: Int {
        let edits = edits.normalized
        let usesVersion2 =
            edits.noiseReduction != 0 || edits.colorNoiseReduction != 0 || !edits.curves.isIdentity || !edits.colorMixer.isIdentity
            || !edits.masks.isEmpty || raw?.colorNoiseReduction != nil || raw?.detail != nil
            || retouch?.isIdentity == false
        return usesVersion2 ? 2 : 1
    }

    /// The still picture differs from the original (the tile and the viewer show a rendition). Loop and Bounce alone
    /// change only how the motion plays.
    public var changesStill: Bool {
        !edits.isIdentity || !(raw?.isIdentity ?? true) || live?.changesStill == true || !(retouch?.isIdentity ?? true)
    }

    /// A short, stable fingerprint of what the recipe renders (not of when or where it was made): the key of the cached
    /// renditions, so that a changed edit never shows an old picture.
    public var renderingDigest: String {
        var stripped = self
        stripped.updatedAt = Date(timeIntervalSince1970: 0)
        stripped.original = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stripped)) ?? Data()
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public enum Failure: Error, Equatable {
        /// Not an edit recipe of this app.
        case notARecipe
        /// Written by a newer version of the app, in a format this one does not know.
        case newerFormat(Int)
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EditRecipe {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The header first: a newer format is reported as such, not as a broken file.
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format else { throw Failure.notARecipe }
        guard header.version <= currentVersion else { throw Failure.newerFormat(header.version) }
        return try decoder.decode(EditRecipe.self, from: data)
    }

    private struct Header: Decodable {
        var format: String
        var version: Int
    }
}

/// RAW development settings, applied by Core Image's RAW decoder (`CIRAWFilter`) when the original is a RAW file.
/// Nil values keep what the camera recorded ("as shot").
public struct RAWAdjustments: Hashable, Sendable, Codable {
    /// Exposure in EV, on top of the camera's baseline.
    public var exposure: Double = 0
    /// White balance: colour temperature in Kelvin; nil keeps the camera's.
    public var temperature: Double?
    /// White balance: tint (green −150 … magenta +150); nil keeps the camera's.
    public var tint: Double?
    /// Brings back detail in blown highlights (where the camera and OS support it).
    public var highlightRecovery = false
    /// Lifts the shadows (0 … 1; the decoder's shadow boost).
    public var shadowBoost: Double = 0
    /// Luminance noise reduction (0 … 1); nil keeps the decoder's default.
    public var noiseReduction: Double?
    /// Colour noise reduction (0 … 1); nil keeps the decoder's default. Format version 2.
    public var colorNoiseReduction: Double?
    /// Detail the decoder brings out (0 … 1, its `detailAmount`); nil keeps the decoder's default. Format version 2.
    public var detail: Double?

    public init(
        exposure: Double = 0, temperature: Double? = nil, tint: Double? = nil, highlightRecovery: Bool = false, shadowBoost: Double = 0,
        noiseReduction: Double? = nil, colorNoiseReduction: Double? = nil, detail: Double? = nil
    ) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.highlightRecovery = highlightRecovery
        self.shadowBoost = shadowBoost
        self.noiseReduction = noiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.detail = detail
    }

    public var isIdentity: Bool { self == RAWAdjustments() }
}

/// What a Live Photo does (SPEC §16.3.3): its effect and the frame that is its still picture.
public struct LivePhotoEffect: Hashable, Sendable, Codable {
    public enum Effect: String, CaseIterable, Sendable, Codable {
        /// Plays its motion as usual (pressed).
        case live
        /// Plays over and over, seamlessly.
        case loop
        /// Plays forward and backward.
        case bounce
        /// The frames averaged into one picture: water turns silky, lights draw lines.
        case longExposure
    }

    public var effect: Effect = .live
    /// The key photo: the time in seconds in the motion whose frame is the still; nil for the photo the camera took.
    public var keyFrameTime: Double?

    public init(effect: Effect = .live, keyFrameTime: Double? = nil) {
        self.effect = effect
        self.keyFrameTime = keyFrameTime
    }

    public var isIdentity: Bool { effect == .live && keyFrameTime == nil }

    /// The still is not the photo the camera took: a long exposure, or another key photo.
    public var changesStill: Bool { effect == .longExposure || keyFrameTime != nil }

    /// The motion plays by itself in the viewer (Loop, Bounce), not only while pressed.
    public var playsByItself: Bool { effect == .loop || effect == .bounce }
}

// MARK: - JSON

/// The recipe's file: only values that differ from "unchanged" are written, so a recipe stays a few hundred bytes and
/// adding a setting later does not change what older recipes mean.
///
/// ```json
/// { "format": "nextcloud-photos-edit", "version": 1, "updatedAt": "2026-11-25T10:00:00Z",
///   "original": { "name": "IMG_1234.HEIC", "etag": "…", "width": 4032, "height": 3024 },
///   "geometry": { "rotation": 1, "straighten": 2.5, "flipped": true, "aspect": "4:3", "aspectLocked": true,
///                 "crop": { "x": 0.1, "y": 0, "width": 0.8, "height": 1 } },
///   "adjustments": { "autoEnhance": true, "exposure": 0.4, "contrast": 1.1 },
///   "filter": "noir",
///   "raw": { "exposure": 0.5, "temperature": 5200, "highlightRecovery": true },
///   "live": { "effect": "bounce", "keyFrameTime": 1.2 } }
/// ```
///
/// Version 2 adds (docs/EDIT-FORMAT.md):
///
/// ```json
/// { "adjustments": { "noiseReduction": 0.3, "colorNoiseReduction": 0.5 },
///   "curves": { "rgb": [[0, 0], [0.25, 0.2], [0.75, 0.82], [1, 1]], "blue": [[0, 0.05], [1, 1]] },
///   "colorMixer": { "blue": { "saturation": 0.3, "luminance": -0.2 }, "orange": { "hue": -0.1 } },
///   "masks": [ { "target": "sky", "adjustments": { "exposure": -0.4, "saturation": 1.2 } },
///              { "target": "subject", "inverted": false, "adjustments": { "exposure": 0.3 } } ],
///   "raw": { "colorNoiseReduction": 0.4, "detail": 0.6 } }
/// ```
extension EditRecipe: Codable {
    private enum Keys: String, CodingKey {
        case format, version, updatedAt, original, geometry, adjustments, filter, raw, live, curves, colorMixer, masks, retouch
    }

    private enum MaskKeys: String, CodingKey {
        case target, inverted, adjustments
    }

    private enum MixerKeys: String, CodingKey {
        case hue, saturation, luminance
    }

    private enum GeometryKeys: String, CodingKey {
        case rotation, straighten, flipped, aspect, aspectLocked, crop
    }

    private enum CropKeys: String, CodingKey {
        case x, y, width, height
    }

    /// Adjustments by name with the value that means "unchanged".
    static var adjustments: [(name: String, keyPath: WritableKeyPath<PhotoEdits, Double>, neutral: Double)] {
        [
            ("exposure", \.exposure, 0), ("contrast", \.contrast, 1), ("brightness", \.brightness, 0), ("highlights", \.highlights, 1),
            ("shadows", \.shadows, 0), ("saturation", \.saturation, 1), ("vibrance", \.vibrance, 0), ("warmth", \.warmth, 0),
            ("tint", \.tint, 0), ("sharpness", \.sharpness, 0), ("vignette", \.vignette, 0),
            ("noiseReduction", \.noiseReduction, 0), ("colorNoiseReduction", \.colorNoiseReduction, 0),
        ]
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(requiredVersion, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(original, forKey: .original)
        let defaults = PhotoEdits()
        var geometry = container.nestedContainer(keyedBy: GeometryKeys.self, forKey: .geometry)
        if edits.rotation % 4 != 0 { try geometry.encode(((edits.rotation % 4) + 4) % 4, forKey: .rotation) }
        if edits.straighten != 0 { try geometry.encode(edits.straighten, forKey: .straighten) }
        if edits.flipped { try geometry.encode(true, forKey: .flipped) }
        if edits.aspect != defaults.aspect { try geometry.encode(edits.aspect.rawValue, forKey: .aspect) }
        if edits.aspectLocked { try geometry.encode(true, forKey: .aspectLocked) }
        if let crop = edits.crop, !crop.isFull {
            var nested = geometry.nestedContainer(keyedBy: CropKeys.self, forKey: .crop)
            try nested.encode(crop.x, forKey: .x)
            try nested.encode(crop.y, forKey: .y)
            try nested.encode(crop.width, forKey: .width)
            try nested.encode(crop.height, forKey: .height)
        }
        var adjustments = container.nestedContainer(keyedBy: AnyKey.self, forKey: .adjustments)
        if edits.autoEnhance { try adjustments.encode(true, forKey: AnyKey("autoEnhance")) }
        for adjustment in Self.adjustments where edits[keyPath: adjustment.keyPath] != adjustment.neutral {
            try adjustments.encode(edits[keyPath: adjustment.keyPath], forKey: AnyKey(adjustment.name))
        }
        if edits.filter != .none { try container.encode(edits.filter.rawValue, forKey: .filter) }
        let normalized = edits.normalized
        if !normalized.curves.isIdentity {
            var curves = container.nestedContainer(keyedBy: AnyKey.self, forKey: .curves)
            for channel in ToneCurves.Channel.allCases where !normalized.curves[channel].isIdentity {
                try curves.encode(normalized.curves[channel].points.map { [$0.x, $0.y] }, forKey: AnyKey(channel.rawValue))
            }
        }
        if !normalized.colorMixer.isIdentity {
            var mixer = container.nestedContainer(keyedBy: AnyKey.self, forKey: .colorMixer)
            for band in ColorMixer.Band.allCases where !normalized.colorMixer[band].isIdentity {
                let adjustment = normalized.colorMixer[band]
                var nested = mixer.nestedContainer(keyedBy: MixerKeys.self, forKey: AnyKey(band.rawValue))
                if adjustment.hue != 0 { try nested.encode(adjustment.hue, forKey: .hue) }
                if adjustment.saturation != 0 { try nested.encode(adjustment.saturation, forKey: .saturation) }
                if adjustment.luminance != 0 { try nested.encode(adjustment.luminance, forKey: .luminance) }
            }
        }
        if !normalized.masks.isEmpty {
            var masks = container.nestedUnkeyedContainer(forKey: .masks)
            for mask in normalized.masks {
                var nested = masks.nestedContainer(keyedBy: MaskKeys.self)
                try nested.encode(mask.target.rawValue, forKey: .target)
                if mask.inverted { try nested.encode(true, forKey: .inverted) }
                var values = nested.nestedContainer(keyedBy: AnyKey.self, forKey: .adjustments)
                for adjustment in MaskAdjustment.adjustments where mask[keyPath: adjustment.keyPath] != adjustment.neutral {
                    try values.encode(mask[keyPath: adjustment.keyPath], forKey: AnyKey(adjustment.name))
                }
            }
        }
        if let raw, !raw.isIdentity { try container.encode(raw, forKey: .raw) }
        if let live, !live.isIdentity { try container.encode(live, forKey: .live) }
        if let retouch, !retouch.isIdentity { try container.encode(retouch, forKey: .retouch) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        original = try? container.decodeIfPresent(Original.self, forKey: .original)
        var edits = PhotoEdits()
        if let geometry = try? container.nestedContainer(keyedBy: GeometryKeys.self, forKey: .geometry) {
            edits.rotation = (((try? geometry.decodeIfPresent(Int.self, forKey: .rotation)) ?? 0) % 4 + 4) % 4
            edits.straighten = min(45, max(-45, (try? geometry.decodeIfPresent(Double.self, forKey: .straighten)) ?? 0))
            edits.flipped = (try? geometry.decodeIfPresent(Bool.self, forKey: .flipped)) ?? false
            if let aspect = try? geometry.decodeIfPresent(String.self, forKey: .aspect) {
                edits.aspect = PhotoEdits.Aspect(rawValue: aspect) ?? .free
            }
            edits.aspectLocked = (try? geometry.decodeIfPresent(Bool.self, forKey: .aspectLocked)) ?? false
            if let crop = try? geometry.nestedContainer(keyedBy: CropKeys.self, forKey: .crop) {
                let rect = CropRect(
                    x: (try? crop.decode(Double.self, forKey: .x)) ?? 0, y: (try? crop.decode(Double.self, forKey: .y)) ?? 0,
                    width: (try? crop.decode(Double.self, forKey: .width)) ?? 1,
                    height: (try? crop.decode(Double.self, forKey: .height)) ?? 1)
                edits.crop = Self.sanitized(rect)
            }
        }
        if let adjustments = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .adjustments) {
            edits.autoEnhance = (try? adjustments.decodeIfPresent(Bool.self, forKey: AnyKey("autoEnhance"))) ?? false
            for adjustment in Self.adjustments {
                if let value = try? adjustments.decodeIfPresent(Double.self, forKey: AnyKey(adjustment.name)), value.isFinite {
                    edits[keyPath: adjustment.keyPath] = value
                }
            }
        }
        // A filter this version does not know shows the photo without it.
        if let filter = try? container.decodeIfPresent(String.self, forKey: .filter) {
            edits.filter = PhotoEdits.Filter(rawValue: filter) ?? .none
        }
        edits.noiseReduction = min(1, max(0, edits.noiseReduction))
        edits.colorNoiseReduction = min(1, max(0, edits.colorNoiseReduction))
        if let curves = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .curves) {
            for channel in ToneCurves.Channel.allCases {
                guard let pairs = try? curves.decodeIfPresent([[Double]].self, forKey: AnyKey(channel.rawValue)) else { continue }
                let points = pairs.filter { $0.count >= 2 }.map { CurvePoint(x: $0[0], y: $0[1]) }
                edits.curves[channel] = ToneCurve(points: points)
            }
        }
        if let mixer = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .colorMixer) {
            for band in ColorMixer.Band.allCases {
                guard let nested = try? mixer.nestedContainer(keyedBy: MixerKeys.self, forKey: AnyKey(band.rawValue)) else { continue }
                let adjustment = ColorMixer.Adjustment(
                    hue: (try? nested.decodeIfPresent(Double.self, forKey: .hue)) ?? 0,
                    saturation: (try? nested.decodeIfPresent(Double.self, forKey: .saturation)) ?? 0,
                    luminance: (try? nested.decodeIfPresent(Double.self, forKey: .luminance)) ?? 0)
                edits.colorMixer[band] = adjustment.clamped()
            }
        }
        if var masks = try? container.nestedUnkeyedContainer(forKey: .masks) {
            while !masks.isAtEnd {
                // A mask of a kind this version does not know is left out; the others still apply.
                guard let nested = try? masks.nestedContainer(keyedBy: MaskKeys.self) else {
                    _ = try? masks.decode(JSONValueSkip.self)
                    continue
                }
                let name = (try? nested.decodeIfPresent(String.self, forKey: .target)) ?? nil
                guard let target = name.flatMap(MaskAdjustment.Target.init(rawValue:)) else { continue }
                var mask = MaskAdjustment(target: target, inverted: (try? nested.decodeIfPresent(Bool.self, forKey: .inverted)) ?? false)
                if let values = try? nested.nestedContainer(keyedBy: AnyKey.self, forKey: .adjustments) {
                    for adjustment in MaskAdjustment.adjustments {
                        if let value = try? values.decodeIfPresent(Double.self, forKey: AnyKey(adjustment.name)), value.isFinite {
                            mask[keyPath: adjustment.keyPath] = value
                        }
                    }
                }
                if !mask.isIdentity && edits.masks.count < Self.maximumMasks { edits.masks.append(mask) }
            }
        }
        self.edits = edits
        raw = try? container.decodeIfPresent(RAWAdjustments.self, forKey: .raw)
        live = try? container.decodeIfPresent(LivePhotoEffect.self, forKey: .live)
        retouch = (try? container.decodeIfPresent(RetouchSteps.self, forKey: .retouch)).flatMap { $0.isIdentity ? nil : $0 }
    }

    /// Most masks a recipe applies (each runs a segmentation): more in a file are ignored.
    public static let maximumMasks = 8

    /// Skips one value of any kind in an unkeyed container.
    private struct JSONValueSkip: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    /// A crop from a file is kept inside the picture and never smaller than the crop tool allows.
    static func sanitized(_ crop: CropRect) -> CropRect? {
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite) else { return nil }
        let width = min(1, max(CropRect.minimumSide, crop.width))
        let height = min(1, max(CropRect.minimumSide, crop.height))
        let x = min(1 - width, max(0, crop.x))
        let y = min(1 - height, max(0, crop.y))
        let result = CropRect(x: x, y: y, width: width, height: height)
        return result.isFull ? nil : result
    }
}

extension LivePhotoEffect {
    private enum Keys: String, CodingKey { case effect, keyFrameTime }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        // An effect this version does not know plays as a plain Live Photo.
        let name: String? = try? container.decodeIfPresent(String.self, forKey: .effect)
        effect = name.flatMap { Effect(rawValue: $0) } ?? .live
        let time: Double? = try? container.decodeIfPresent(Double.self, forKey: .keyFrameTime)
        keyFrameTime = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

extension RAWAdjustments {
    private enum Keys: String, CodingKey {
        case exposure, temperature, tint, highlightRecovery, shadowBoost, noiseReduction, colorNoiseReduction, detail
    }

    /// Missing or broken values keep the camera's development.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        func value(_ key: Keys) -> Double? {
            let number: Double? = try? container.decodeIfPresent(Double.self, forKey: key)
            return number.flatMap { $0.isFinite ? $0 : nil }
        }
        exposure = value(.exposure) ?? 0
        temperature = value(.temperature)
        tint = value(.tint)
        let recovery: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .highlightRecovery)
        highlightRecovery = recovery ?? false
        shadowBoost = value(.shadowBoost) ?? 0
        noiseReduction = value(.noiseReduction)
        colorNoiseReduction = value(.colorNoiseReduction).map { min(1, max(0, $0)) }
        detail = value(.detail).map { min(1, max(0, $0)) }
    }
}
