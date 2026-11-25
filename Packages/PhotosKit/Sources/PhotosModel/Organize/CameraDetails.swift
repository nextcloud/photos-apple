// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the camera recorded about a photo (from the EXIF the server extracted: `nc:metadata-photos-exif` and `-ifd0`).
/// The index keeps it for smart album rules on camera, lens and exposure (SPEC §16.4).
public struct CameraDetails: Codable, Hashable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    /// Millimetres.
    public var focalLength: Double?
    /// f-number.
    public var aperture: Double?
    public var iso: Double?

    public init(
        make: String? = nil, model: String? = nil, lens: String? = nil, focalLength: Double? = nil, aperture: Double? = nil,
        iso: Double? = nil
    ) {
        self.make = make
        self.model = model
        self.lens = lens
        self.focalLength = focalLength
        self.aperture = aperture
        self.iso = iso
    }

    /// From the flat `tag → value` EXIF dictionary the server sends (`PhotosAPI.exif`). Values like `28/10` are rationals.
    public init(exif: [String: String]) {
        func text(_ key: String) -> String? {
            guard let value = exif[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        make = text("Make")
        model = text("Model")
        lens = text("LensModel") ?? text("UndefinedTag__0xa434")
        focalLength = text("FocalLength").flatMap(Self.rational)
        aperture = text("FNumber").flatMap(Self.rational)
        iso = (text("ISOSpeedRatings") ?? text("PhotographicSensitivity")).flatMap {
            Self.rational($0.split(separator: ",").first.map(String.init) ?? $0)
        }
    }

    /// `28/10` → 2.8, `35` → 35. Nil for a zero denominator or anything else.
    public static func rational(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        if parts.count == 2, let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
            let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces))
        {
            return denominator == 0 ? nil : numerator / denominator
        }
        return Double(text.trimmingCharacters(in: .whitespaces))
    }

    /// "Canon EOS 450D": the model, with the make in front when the model does not already name it.
    public var cameraName: String? {
        switch (make, model) {
        case (nil, nil): return nil
        case (let make?, nil): return make
        case (nil, let model?): return model
        case (let make?, let model?):
            let firstWord = make.split(separator: " ").first.map(String.init) ?? make
            return model.localizedCaseInsensitiveContains(firstWord) ? model : "\(make) \(model)"
        }
    }

    public var isEmpty: Bool { make == nil && model == nil && lens == nil && focalLength == nil && aperture == nil && iso == nil }
}
