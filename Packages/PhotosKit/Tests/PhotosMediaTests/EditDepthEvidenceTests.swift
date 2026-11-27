// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

/// Before / mask / after pictures of real photos for SPEC §21.6 (the quality evidence of masks and presets), and the time
/// a mask takes. Runs only when PHOTOS_EDIT_EVIDENCE names a folder with JPEGs in `in/`; writes `out/`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_EDIT_EVIDENCE"] != nil))
struct EditDepthEvidenceTests {
    static func strip(_ images: [CIImage], height: CGFloat = 480) -> CIImage {
        var x: CGFloat = 0
        var result = CIImage.empty()
        for image in images {
            let scale = height / image.extent.height
            let placed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: x - image.extent.minX * scale, y: -image.extent.minY * scale))
            result = placed.composited(over: result)
            x += placed.extent.width + 8
        }
        return result.cropped(to: CGRect(x: 0, y: 0, width: x - 8, height: height))
    }

    static func tinted(_ mask: CIImage?, over image: CIImage) -> CIImage {
        guard let mask else { return image }
        let tint = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.55)).cropped(to: image.extent)
        let filter = CIFilter(name: "CIBlendWithRedMask")!
        filter.setValue(tint.composited(over: image), forKey: kCIInputImageKey)
        filter.setValue(image, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage!.cropped(to: image.extent)
    }

    static func write(_ image: CIImage, to url: URL) throws {
        let cgImage = try #require(PhotoEditor.context.createCGImage(image, from: image.extent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func masksAndPresetsOnRealPhotos() throws {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["PHOTOS_EDIT_EVIDENCE"]))
        let output = root.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: root.appending(path: "in"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
        var lines: [String] = []
        for file in files {
            guard let original = PhotoEditor.load(file) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            for target in MaskAdjustment.Target.allCases where target != .background {
                let start = Date()
                let mask = EditMasks.mask(target, for: original)
                let first = Date().timeIntervalSince(start)
                let again = Date()
                _ = EditMasks.mask(target, for: original)
                let cached = Date().timeIntervalSince(again)
                lines.append(
                    "\(name) \(target.rawValue): \(mask == nil ? "none" : "found") in \(Int(first * 1000)) ms, cached \(Int(cached * 1000)) ms"
                )
                guard mask != nil else { continue }
                let preset: EditPreset.BuiltIn = target == .sky ? .dramaticSky : .portrait
                var recipe = preset.recipe
                if target == .people {
                    var people = MaskAdjustment(target: .people)
                    people.exposure = 0.35
                    people.vibrance = 0.2
                    var others = MaskAdjustment(target: .people, inverted: true)
                    others.saturation = 0.4
                    others.exposure = -0.3
                    recipe = EditRecipe(
                        edits: {
                            var edits = PhotoEdits(); edits.masks = [people, others]; return edits
                        }())
                }
                let after = EditRendering.apply(recipe, to: original)
                try Self.write(
                    Self.strip([original, Self.tinted(mask, over: original), after]),
                    to: output.appending(path: "\(name)-\(target.rawValue).jpg"))
            }
            // Curves and colour mixer: an S curve, oranges warmer, blues deeper.
            var look = PhotoEdits()
            look.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0.03), .init(x: 0.25, y: 0.2), .init(x: 0.75, y: 0.82), .init(x: 1, y: 1)])
            look.colorMixer[.blue] = ColorMixer.Adjustment(saturation: 0.4, luminance: -0.3)
            look.colorMixer[.orange] = ColorMixer.Adjustment(hue: -0.2, saturation: 0.3)
            var mono = PhotoEdits()
            mono.colorMixer = ColorMixer(
                Dictionary(
                    uniqueKeysWithValues: ColorMixer.Band.allCases.filter { $0 != .red }.map { ($0, ColorMixer.Adjustment(saturation: -1)) }
                ))
            try Self.write(
                Self.strip([original, PhotoEditor.apply(look, to: original), PhotoEditor.apply(mono, to: original)]),
                to: output.appending(path: "\(name)-curves-mixer.jpg"))
        }
        try lines.joined(separator: "\n").write(to: output.appending(path: "timings.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}
