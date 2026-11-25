// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosMedia

/// The edit recipe's file format (SPEC §16.3.1): small, stable, readable by older and newer versions.
@Suite struct EditRecipeTests {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static var sample: EditRecipe {
        var edits = PhotoEdits()
        edits.rotate(clockwise: true)
        edits.straighten = 2.5
        edits.flip()
        edits.aspect = .fourThree
        edits.aspectLocked = true
        edits.crop = CropRect(x: 0.1, y: 0, width: 0.8, height: 1)
        edits.autoEnhance = true
        edits.exposure = 0.4
        edits.contrast = 1.1
        edits.filter = .noir
        return EditRecipe(
            edits: edits, raw: RAWAdjustments(exposure: 0.5, temperature: 5200, highlightRecovery: true),
            live: LivePhotoEffect(effect: .bounce, keyFrameTime: 1.2),
            original: EditRecipe.Original(name: "IMG_1234.HEIC", etag: "abc", width: 4032, height: 3024), updatedAt: Self.date)
    }

    @Test func roundTrips() throws {
        let recipe = Self.sample
        let decoded = try EditRecipe.decode(try recipe.encoded())
        #expect(decoded == recipe)
        #expect(decoded.edits.rotation == 1 && decoded.edits.flipped)
        #expect(decoded.live?.effect == .bounce)
    }

    /// Only what differs from "unchanged" is written: the file stays small and its meaning does not depend on defaults
    /// that may change.
    @Test func writesOnlyChangedValues() throws {
        var edits = PhotoEdits()
        edits.exposure = 0.3
        let json = try #require(String(data: try EditRecipe(edits: edits, updatedAt: Self.date).encoded(), encoding: .utf8))
        #expect(json.contains("\"format\" : \"nextcloud-photos-edit\""))
        #expect(json.contains("\"version\" : 1"))
        #expect(json.contains("\"exposure\" : 0.3"))
        for absent in ["contrast", "saturation", "filter", "raw", "live", "crop", "rotation"] {
            #expect(!json.contains("\"\(absent)\""), "\(absent)")
        }
        #expect(json.utf8.count < 400)
    }

    @Test func aNewerFormatIsReportedNotMisread() throws {
        let newer = #"{"format": "nextcloud-photos-edit", "version": 7, "geometry": {"rotation": 1}}"#
        #expect(throws: EditRecipe.Failure.newerFormat(7)) { try EditRecipe.decode(Data(newer.utf8)) }
        #expect(throws: EditRecipe.Failure.notARecipe) { try EditRecipe.decode(Data(#"{"hello": 1}"#.utf8)) }
        #expect(throws: EditRecipe.Failure.notARecipe) { try EditRecipe.decode(Data("not json".utf8)) }
    }

    /// Settings this version does not know are left out; broken values do not break the photo.
    @Test func toleratesUnknownAndBrokenValues() throws {
        let json = #"""
            {"format": "nextcloud-photos-edit", "version": 1, "updatedAt": "2026-11-25T10:00:00Z",
             "geometry": {"rotation": 6, "straighten": 99, "crop": {"x": -0.5, "y": 0.2, "width": 3, "height": 0.001}},
             "adjustments": {"exposure": 0.2, "clarity": 0.9, "contrast": "high"},
             "filter": "sepia-future", "live": {"effect": "portal", "keyFrameTime": -3},
             "raw": {"exposure": "x", "temperature": 4000}, "somethingNew": {"a": 1}}
            """#
        let recipe = try EditRecipe.decode(Data(json.utf8))
        #expect(recipe.edits.rotation == 2)
        #expect(recipe.edits.straighten == 45)
        #expect(recipe.edits.exposure == 0.2)
        #expect(recipe.edits.contrast == 1)
        #expect(recipe.edits.filter == .none)
        #expect(recipe.live == LivePhotoEffect(effect: .live, keyFrameTime: nil))
        #expect(recipe.raw == RAWAdjustments(temperature: 4000))
        let crop = try #require(recipe.edits.crop)
        #expect(crop.x == 0 && crop.width == 1)
        #expect(abs(crop.height - CropRect.minimumSide) < 1e-9)
        #expect(crop.y <= 1 - crop.height)
    }

    /// The digest names the rendition in the caches: the same look gives the same digest, whenever it was saved.
    @Test func digestDependsOnlyOnTheLook() {
        var a = Self.sample
        var b = Self.sample
        b.updatedAt = Date()
        b.original = nil
        #expect(a.renderingDigest == b.renderingDigest)
        #expect(a.renderingDigest.count == 12)
        a.edits.exposure = 0.5
        #expect(a.renderingDigest != b.renderingDigest)
    }

    @Test func whatChangesTheStill() {
        #expect(EditRecipe().isIdentity)
        #expect(!EditRecipe().changesStill)
        // Loop and Bounce change how the motion plays, not the still.
        let bounce = EditRecipe(live: LivePhotoEffect(effect: .bounce))
        #expect(!bounce.isIdentity && !bounce.changesStill && bounce.live?.playsByItself == true)
        #expect(EditRecipe(live: LivePhotoEffect(effect: .longExposure)).changesStill)
        #expect(EditRecipe(live: LivePhotoEffect(keyFrameTime: 0.8)).changesStill)
        #expect(EditRecipe(raw: RAWAdjustments(exposure: 1)).changesStill)
        #expect(!EditRecipe(raw: RAWAdjustments()).changesStill)
        var turned = EditRecipe()
        turned.edits.rotate(clockwise: true)
        #expect(turned.changesStill)
    }

    @Test func recognisesRAWFiles() {
        for name in ["IMG_1.DNG", "a.cr3", "b.NEF", "c.arw", "d.raf", "e.orf"] { #expect(EditRendering.isRAW(name: name), "\(name)") }
        for name in ["IMG_1.JPG", "a.heic", "b.png", "c.mov", "noext"] { #expect(!EditRendering.isRAW(name: name), "\(name)") }
    }
}

/// Live Photo effects as arithmetic (SPEC §16.3.3); runs without a GPU.
@Suite struct LivePhotoEffectLogicTests {
    @Test func averagesFrames() {
        var averager = FrameAverager(width: 2, height: 1)
        averager.add([0, 0, 0, 255, 255, 255, 255, 255])
        averager.add([255, 0, 100, 255, 0, 0, 0, 255])
        averager.add([1, 2, 3])  // wrong size: ignored
        #expect(averager.count == 2)
        #expect(averager.average() == [128, 0, 50, 255, 128, 128, 128, 255])
        #expect(FrameAverager(width: 1, height: 1).average() == [0, 0, 0, 0])
    }

    @Test func loopAndBounceFrameOrder() {
        #expect(LivePhotoEffects.frameOrder(frameCount: 4, effect: .loop) == [0, 1, 2, 3])
        #expect(LivePhotoEffects.frameOrder(frameCount: 4, effect: .loop, repeats: 2) == [0, 1, 2, 3, 0, 1, 2, 3])
        // Forward and back without showing the turning frames twice: it loops seamlessly.
        #expect(LivePhotoEffects.frameOrder(frameCount: 4, effect: .bounce) == [0, 1, 2, 3, 2, 1])
        #expect(LivePhotoEffects.frameOrder(frameCount: 4, effect: .bounce, repeats: 2) == [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1])
        #expect(LivePhotoEffects.frameOrder(frameCount: 2, effect: .bounce) == [0, 1])
        #expect(LivePhotoEffects.frameOrder(frameCount: 0, effect: .bounce).isEmpty)
    }

    @Test func sampleTimesSpreadOverTheMotion() {
        #expect(LivePhotoEffects.sampleTimes(duration: 3, count: 3) == [0.5, 1.5, 2.5])
        #expect(LivePhotoEffects.sampleTimes(duration: 3, count: 1) == [1.5])
        #expect(LivePhotoEffects.sampleTimes(duration: 0, count: 5) == [0])
    }
}

/// Rendering recipes (needs Core Image on a GPU: Mac only, see `TestEnvironment`).
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct EditRenditionTests {
    func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func renditionTurnsCropsAndFitsTheBucket() throws {
        var recipe = EditRecipe()
        recipe.edits.rotate(clockwise: true)
        let turned = try #require(EditRendering.rendition(of: image(width: 400, height: 300), recipe: recipe, maxPixelSize: 200))
        #expect(turned.width == 150 && turned.height == 200)
        recipe.edits.aspect = .square
        let square = try #require(EditRendering.rendition(of: image(width: 400, height: 300), recipe: recipe, maxPixelSize: 1024))
        #expect(square.width == square.height)
    }

    @Test func rendersAnEditedCopyWithTheOriginalsMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "edit-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appending(path: "IMG_1.jpg")
        let data = try #require(ImageDecoding.jpegData(image(width: 64, height: 48)))
        try data.write(to: original)
        var recipe = EditRecipe()
        recipe.edits.rotate(clockwise: false)
        let output = folder.appending(path: "out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = try EditRendering.renderFile(recipe, original: original, name: "IMG_1.jpg", to: output)
        #expect(file.lastPathComponent == "IMG_1 (edited).jpg")
        let rendered = try #require(ImageDecoding.decode(url: file, maxPixelSize: 4096))
        #expect(rendered.width == 48 && rendered.height == 64)
    }
}
