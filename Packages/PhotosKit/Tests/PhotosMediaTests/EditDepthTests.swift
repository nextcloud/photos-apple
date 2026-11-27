// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import PhotosMedia

/// Editing depth (SPEC §21.6): curves, colour mixer, masks, noise reduction, presets and format version 2.
@Suite struct EditDepthTests {
    // MARK: Helpers

    /// A picture of one sRGB colour.
    static func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 4) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: space)!).cropped(
            to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// The sRGB colour of the picture's middle pixel, 0 … 1.
    static func colour(_ image: CIImage) -> (Double, Double, Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let extent = image.extent
        let point = CGRect(x: extent.midX.rounded(.down), y: extent.midY.rounded(.down), width: 1, height: 1)
        PhotoEditor.context.render(
            image, toBitmap: &bytes, rowBytes: 4, bounds: point, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    // MARK: Curves

    @Test func aCurveIsSortedClampedAndMerged() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 1.2, y: 1), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 0, y: -0.1), CurvePoint(x: 0.505, y: 0.7),
            CurvePoint(x: .nan, y: 0.3),
        ])
        #expect(curve.points.map(\.x) == [0, 0.505, 1])
        #expect(curve.points.first?.y == 0)
        #expect(curve.points[1].y == 0.7)
        #expect(ToneCurve(points: [CurvePoint(x: 0.3, y: 0.3)]) == .identity)
        #expect(ToneCurve.identity.isIdentity)
        #expect(!curve.isIdentity)
    }

    @Test func theSplineGoesThroughItsPointsAndNeverOvershoots() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.2, y: 0.05), CurvePoint(x: 0.25, y: 0.9), CurvePoint(x: 1, y: 1),
        ])
        for point in curve.points { #expect(abs(curve.value(at: point.x) - point.y) < 1e-9) }
        // Monotone data gives a monotone curve: never below a point before it (a Catmull-Rom curve dips here).
        let table = curve.table(count: 512)
        for index in 1..<table.count { #expect(table[index] >= table[index - 1] - 1e-9) }
        #expect(table.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func endPointsSetBlackAndWhitePoints() {
        let curve = ToneCurve(points: [CurvePoint(x: 0.1, y: 0), CurvePoint(x: 0.9, y: 1)])
        #expect(curve.value(at: 0.05) == 0)
        #expect(curve.value(at: 0.95) == 1)
        #expect(abs(curve.value(at: 0.5) - 0.5) < 1e-9)
        #expect(curve.removing(at: 0) == curve)
    }

    @Test func channelCurvesFollowTheRGBCurve() {
        var curves = ToneCurves()
        curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 1, y: 1)])
        curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.5)])
        let table = curves.table()
        // Input 0: the RGB curve gives 0.2; red then halves it, green and blue keep it.
        #expect(abs(Double(table[0]) - 0.1) < 0.001)
        #expect(abs(Double(table[1]) - 0.2) < 0.001)
        #expect(abs(Double(table[2]) - 0.2) < 0.001)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func curvesRenderInSRGBValues() {
        var curves = ToneCurves()
        curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.75), CurvePoint(x: 1, y: 1)])
        curves.blue = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0)])
        let (r, g, b) = Self.colour(curves.apply(to: Self.solid(0.5, 0.5, 0.5)))
        #expect(abs(r - 0.75) < 0.02)
        #expect(abs(g - 0.75) < 0.02)
        #expect(b < 0.02)
    }

    // MARK: Colour mixer

    @Test func rangeWeightsAddUpToOne() {
        for hue in stride(from: 0.0, to: 360, by: 7.5) {
            let weights = ColorMixer.weights(hue: hue)
            #expect(abs(weights.map(\.1).reduce(0, +) - 1) < 1e-9)
        }
        #expect(ColorMixer.weights(hue: 225).first { $0.0 == .blue }?.1 == 1)
        // Between purple (270) and magenta (315).
        let between = ColorMixer.weights(hue: 292.5)
        #expect(between.contains { $0.0 == .purple && abs($0.1 - 0.5) < 1e-9 })
        #expect(between.contains { $0.0 == .magenta && abs($0.1 - 0.5) < 1e-9 })
        // Between magenta and red, across 360°.
        #expect(ColorMixer.weights(hue: 350).contains { $0.0 == .red && $0.1 > 0.7 })
    }

    @Test func theMixerChangesOnlyItsColours() {
        var mixer = ColorMixer()
        mixer[.blue] = ColorMixer.Adjustment(saturation: -1)
        // Pure blue (hue 240, between blue 225 and purple 270) loses most of its colour.
        let blue = mixer.map(red: 0.1, green: 0.2, blue: 0.9)
        let (_, saturationBefore, _) = ColorMixer.hsl(0.1, 0.2, 0.9)
        let (_, saturationAfter, _) = ColorMixer.hsl(blue.0, blue.1, blue.2)
        #expect(saturationAfter < saturationBefore * 0.5)
        // Red and grey stay as they are.
        let red = mixer.map(red: 0.9, green: 0.1, blue: 0.1)
        #expect(abs(red.0 - 0.9) < 1e-9 && abs(red.1 - 0.1) < 1e-9)
        let grey = mixer.map(red: 0.4, green: 0.4, blue: 0.4)
        #expect(grey == (0.4, 0.4, 0.4))
    }

    @Test func hueAndLuminanceMoveTheColour() {
        var mixer = ColorMixer()
        mixer[.green] = ColorMixer.Adjustment(hue: 1, luminance: -1)
        let (r, g, b) = mixer.map(red: 0.2, green: 0.8, blue: 0.2)
        let (hue, _, lightness) = ColorMixer.hsl(r, g, b)
        let (_, _, before) = ColorMixer.hsl(0.2, 0.8, 0.2)
        #expect(abs(hue - 150) < 0.5)
        #expect(lightness < before)
        #expect(ColorMixer([.red: ColorMixer.Adjustment()]).isIdentity)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func theMixerRendersThroughItsLookupTable() {
        var mixer = ColorMixer()
        mixer[.red] = ColorMixer.Adjustment(saturation: -1)
        let red = Self.colour(mixer.apply(to: Self.solid(0.8, 0.1, 0.1)))
        #expect(abs(red.0 - red.1) < 0.06 && abs(red.1 - red.2) < 0.06)
        let blue = Self.colour(mixer.apply(to: Self.solid(0.1, 0.1, 0.8)))
        #expect(blue.2 > 0.7 && blue.0 < 0.2)
    }

    // MARK: Noise

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func colourNoiseReductionSmoothsColourButKeepsBrightness() throws {
        // Grey with blotches of red and green in a checkerboard of 2-pixel squares.
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                let even = ((x / 2) + (y / 2)) % 2 == 0
                pixels[offset] = even ? 150 : 110
                pixels[offset + 1] = even ? 110 : 150
                pixels[offset + 2] = 128
                pixels[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(
            CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = CIImage(cgImage: cgImage)
        // At this size the radius is too small to matter: the strength is relative to the picture.
        let tiny = NoiseReduction.apply(luminance: 0, color: 1, to: input)
        let output = NoiseReduction.apply(luminance: 0, color: 1, to: input.transformed(by: CGAffineTransform(scaleX: 16, y: 16)))
        let (r, g, _) = Self.colour(output)
        #expect(abs(r - g) < 0.08)
        #expect(tiny.extent == input.extent)
        #expect(NoiseReduction.apply(luminance: 0, color: 0, to: input) === input)
    }

    // MARK: Sky

    /// A synthetic landscape: a smooth blue gradient in the upper half, a textured green field below.
    static func landscape(width: Int = 96, height: Int = 64) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if y < height / 2 {
                    pixels[offset] = UInt8(70 + y)
                    pixels[offset + 1] = UInt8(130 + y)
                    pixels[offset + 2] = 230
                } else {
                    let noise = (x * 37 + y * 91) % 5 == 0 ? 60 : 0
                    pixels[offset] = UInt8(40 + noise)
                    pixels[offset + 1] = UInt8(120 + noise)
                    pixels[offset + 2] = UInt8(30 + noise / 2)
                }
            }
        }
        return pixels
    }

    @Test func theSkyIsFoundAboveTheHorizon() throws {
        let width = 96
        let height = 64
        let mask = try #require(EditMasks.skyMask(rgba: Self.landscape(width: width, height: height), width: width, height: height))
        let top = (0..<(height / 2 - 2)).flatMap { y in (0..<width).map { mask[y * width + $0] } }
        let bottom = ((height / 2 + 2)..<height).flatMap { y in (0..<width).map { mask[y * width + $0] } }
        #expect(Double(top.filter { $0 > 200 }.count) / Double(top.count) > 0.95)
        #expect(bottom.allSatisfy { $0 == 0 })
    }

    @Test func blueThatDoesNotTouchTheTopIsNotSky() {
        // A blue square (a car, a shirt) in the middle of a textured picture.
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let inside = x > 20 && x < 44 && y > 20 && y < 44
                let noise = (x * 13 + y * 7) % 3 == 0 ? 70 : 0
                pixels[offset] = inside ? 60 : UInt8(90 + noise)
                pixels[offset + 1] = inside ? 110 : UInt8(70 + noise)
                pixels[offset + 2] = inside ? 230 : UInt8(50 + noise)
            }
        }
        #expect(EditMasks.skyMask(rgba: pixels, width: width, height: height) == nil)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func aMaskAdjustsOnlyItsPart() throws {
        let width = 96
        let height = 64
        let pixels = Self.landscape(width: width, height: height)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = CIImage(cgImage: cgImage)
        let small = try #require(EditMasks.workImage(input, longEdge: EditMasks.skySize))
        let alpha = try #require(
            EditMasks.rgba(of: small).flatMap { EditMasks.skyMask(rgba: $0, width: small.width, height: small.height) })
        #expect(alpha.contains(255))
        // The adjustment of a sky mask darkens the sky and leaves the field (the mask comes from the heuristic here; Vision's
        // scene classification may veto a synthetic picture, which the editor reports as "No sky found").
        let mask = try #require(EditMasks.greyImage(alpha, width: small.width, height: small.height))
        let upsample = CIFilter(name: "CIEdgePreserveUpsampleFilter")!
        upsample.setValue(input, forKey: kCIInputImageKey)
        upsample.setValue(CIImage(cgImage: mask), forKey: "inputSmallImage")
        let full = try #require(upsample.outputImage)
        var sky = MaskAdjustment(target: .sky)
        sky.exposure = -1
        let adjusted = PhotoEditor.applyAdjustments(sky.edits, to: input)
        let blend = CIFilter(name: "CIBlendWithRedMask")!
        blend.setValue(adjusted, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        blend.setValue(full, forKey: kCIInputMaskImageKey)
        let output = try #require(blend.outputImage).cropped(to: input.extent)
        let skyBefore = Self.colour(input.cropped(to: CGRect(x: 40, y: 50, width: 4, height: 4)))
        let skyAfter = Self.colour(output.cropped(to: CGRect(x: 40, y: 50, width: 4, height: 4)))
        let fieldBefore = Self.colour(input.cropped(to: CGRect(x: 40, y: 8, width: 4, height: 4)))
        let fieldAfter = Self.colour(output.cropped(to: CGRect(x: 40, y: 8, width: 4, height: 4)))
        #expect(skyAfter.2 < skyBefore.2 - 0.15)
        #expect(abs(fieldAfter.1 - fieldBefore.1) < 0.03)
    }

    @Test func maskFingerprintsTellPicturesApart() {
        let red = EditMasks.fingerprint(Self.solid(1, 0, 0, size: 32))
        let blue = EditMasks.fingerprint(Self.solid(0, 0, 1, size: 32))
        #expect(red != nil && red != blue)
        #expect(red == EditMasks.fingerprint(Self.solid(1, 0, 0, size: 32)))
        #expect(red != EditMasks.fingerprint(Self.solid(1, 0, 0, size: 64)))
    }

    // MARK: Format version 2

    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static var deep: EditRecipe {
        var edits = PhotoEdits()
        edits.rotate(clockwise: true)
        edits.noiseReduction = 0.3
        edits.colorNoiseReduction = 0.5
        edits.curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 1, y: 1)])
        edits.curves.blue = ToneCurve(points: [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)])
        edits.colorMixer[.blue] = ColorMixer.Adjustment(saturation: 0.3, luminance: -0.2)
        edits.colorMixer[.orange] = ColorMixer.Adjustment(hue: -0.1)
        var sky = MaskAdjustment(target: .sky)
        sky.exposure = -0.4
        sky.saturation = 1.2
        var people = MaskAdjustment(target: .people, inverted: true)
        people.warmth = 0.2
        edits.masks = [sky, people]
        return EditRecipe(
            edits: edits, raw: RAWAdjustments(exposure: 0.2, colorNoiseReduction: 0.4, detail: 0.6), updatedAt: Self.date)
    }

    @Test func aRecipeIsWrittenWithTheLowestVersionThatShowsIt() throws {
        var simple = EditRecipe(updatedAt: Self.date)
        simple.edits.exposure = 0.4
        #expect(simple.requiredVersion == 1)
        #expect(String(decoding: try simple.encoded(), as: UTF8.self).contains("\"version\" : 1"))
        #expect(Self.deep.requiredVersion == 2)
        #expect(String(decoding: try Self.deep.encoded(), as: UTF8.self).contains("\"version\" : 2"))
        var maskWithoutChange = simple
        maskWithoutChange.edits.masks = [MaskAdjustment(target: .sky)]
        #expect(maskWithoutChange.requiredVersion == 1)
        var rawDetail = simple
        rawDetail.raw = RAWAdjustments(detail: 0.5)
        #expect(rawDetail.requiredVersion == 2)
    }

    @Test func version2RoundTrips() throws {
        let decoded = try EditRecipe.decode(try Self.deep.encoded())
        #expect(decoded.edits == Self.deep.edits)
        #expect(decoded.raw == Self.deep.raw)
        #expect(decoded.version == 2)
        #expect(decoded.renderingDigest == Self.deep.renderingDigest)
    }

    @Test func version2IsReadAsDocumented() throws {
        let json = """
            { "format": "nextcloud-photos-edit", "version": 2, "updatedAt": "2026-11-26T10:00:00Z",
              "adjustments": { "noiseReduction": 3, "colorNoiseReduction": 0.5 },
              "curves": { "rgb": [[0, 0], [0.25, 0.2], [0.75, 0.82], [1, 1]], "blue": [[0, 0.05], [1, 1]], "alpha": [[0, 1]],
                          "red": [[0.5]] },
              "colorMixer": { "blue": { "saturation": 0.3, "luminance": -7 }, "teal": { "hue": 1 } },
              "masks": [ { "target": "sky", "adjustments": { "exposure": -0.4, "saturation": 1.2 } },
                         { "target": "dog", "adjustments": { "exposure": 1 } },
                         { "target": "subject", "inverted": true, "adjustments": {} },
                         { "target": "people", "inverted": true, "adjustments": { "warmth": 0.2 } } ],
              "raw": { "colorNoiseReduction": 0.4, "detail": 1.6 } }
            """
        let recipe = try EditRecipe.decode(Data(json.utf8))
        #expect(recipe.edits.noiseReduction == 1)
        #expect(recipe.edits.colorNoiseReduction == 0.5)
        #expect(recipe.edits.curves.rgb.points.count == 4)
        #expect(recipe.edits.curves.blue.points.first == CurvePoint(x: 0, y: 0.05))
        #expect(recipe.edits.curves.red.isIdentity)
        #expect(recipe.edits.colorMixer[.blue] == ColorMixer.Adjustment(saturation: 0.3, luminance: -1))
        #expect(recipe.edits.colorMixer.bands.count == 1)
        // An unknown mask kind and a mask without adjustments are left out; the others apply.
        #expect(recipe.edits.masks.map(\.target) == [.sky, .people])
        #expect(recipe.edits.masks[1].inverted)
        #expect(recipe.raw?.detail == 1)
    }

    @Test func aVersion3RecipeIsNotApplied() {
        let json = #"{ "format": "nextcloud-photos-edit", "version": 3, "adjustments": { "exposure": 1 } }"#
        #expect(throws: EditRecipe.Failure.newerFormat(3)) { try EditRecipe.decode(Data(json.utf8)) }
    }

    @Test func version1RecipesReadAsBefore() throws {
        let json = #"{ "format": "nextcloud-photos-edit", "version": 1, "adjustments": { "exposure": 0.5 }, "filter": "mono" }"#
        let recipe = try EditRecipe.decode(Data(json.utf8))
        #expect(recipe.edits.exposure == 0.5)
        #expect(recipe.edits.curves.isIdentity && recipe.edits.colorMixer.isIdentity && recipe.edits.masks.isEmpty)
        #expect(recipe.requiredVersion == 1)
    }

    @Test func tooManyMasksAreCut() throws {
        let masks = (0..<20).map { _ in #"{ "target": "sky", "adjustments": { "exposure": -0.1 } }"# }.joined(separator: ",")
        let json = #"{ "format": "nextcloud-photos-edit", "version": 2, "masks": ["# + masks + "] }"
        #expect(try EditRecipe.decode(Data(json.utf8)).edits.masks.count == EditRecipe.maximumMasks)
    }

    // MARK: Looks and presets

    @Test func aLookLeavesTheGeometryBehind() {
        let look = Self.deep.look
        #expect(look.edits.rotation == 0)
        #expect(look.edits.masks.count == 2)
        #expect(look.raw == Self.deep.raw)
        #expect(Self.deep.hasLook)
        var turned = EditRecipe()
        turned.edits.rotate(clockwise: false)
        #expect(!turned.hasLook)
    }

    @Test func pastingKeepsTheTargetsCropAndTurns() {
        var target = EditRecipe()
        target.edits.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        target.edits.rotate(clockwise: true)
        target.edits.exposure = 1
        let pasted = target.withLook(Self.deep, developsRAW: false)
        #expect(pasted.edits.crop == target.edits.crop)
        #expect(pasted.edits.rotation == target.edits.rotation)
        #expect(pasted.edits.exposure == 0)
        #expect(pasted.edits.curves == Self.deep.edits.curves)
        #expect(pasted.raw == nil)
        #expect(target.withLook(Self.deep, developsRAW: true).raw == Self.deep.raw)
    }

    @Test func theClipboardKeepsOnlyTheLook() {
        EditClipboard.look = Self.deep
        #expect(EditClipboard.look?.edits.rotation == 0)
        EditClipboard.look = nil
        #expect(EditClipboard.look == nil)
    }

    @Test func builtInPresetsChangeSomethingAndNeedNoGeometry() {
        for preset in EditPreset.BuiltIn.allCases {
            #expect(preset.recipe.hasLook, "\(preset)")
            #expect(preset.preset.isBuiltIn)
        }
    }

    @Test func presetsMergePresetByPreset() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let local = [
            EditPreset(id: "a", name: "A here", recipe: Self.deep, updatedAt: new),
            EditPreset(id: "b", name: "B", recipe: Self.deep, updatedAt: old),
        ]
        let remote = [
            EditPreset(id: "a", name: "A there", recipe: Self.deep, updatedAt: old),
            EditPreset(id: "b", name: "", recipe: EditRecipe(), updatedAt: new, deleted: true),
            EditPreset(id: "c", name: "C", recipe: Self.deep, updatedAt: old),
        ]
        let merged = EditPresetLibrary.merge(local, remote)
        #expect(merged.first { $0.id == "a" }?.name == "A here")
        #expect(merged.first { $0.id == "b" }?.deleted == true)
        #expect(merged.first { $0.id == "c" }?.name == "C")
    }

    @Test func thePresetFileRoundTrips() throws {
        let presets = [
            EditPreset(id: "a", name: "Evening", recipe: Self.deep, updatedAt: Self.date),
            EditPreset(id: "b", name: "", recipe: EditRecipe(), updatedAt: Self.date, deleted: true),
        ]
        let data = try EditPresetFile(presets).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("nextcloud-photos-edit-presets"))
        let decoded = try #require(EditPresetFile.decode(data))
        #expect(decoded.count == 2)
        #expect(decoded[0].recipe.edits == Self.deep.look.edits)
        #expect(decoded[1].deleted)
    }

    @Test func presetsSyncThroughTheUsersFiles() async throws {
        let server = EditDAVServer()
        let first = EditPresetLibrary(dav: server.dav, file: nil)
        await first.save(EditPreset(id: "p1", name: "Evening", recipe: Self.deep))
        let second = EditPresetLibrary(dav: server.dav, file: nil)
        await second.sync()
        #expect(second.userPresets().map(\.name) == ["Evening"])
        await second.delete(id: "p1")
        await first.sync()
        #expect(first.userPresets().isEmpty)
    }
}
