// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import Foundation
import Synchronization
import Testing

@testable import PhotosMedia

/// The Erase tool (SPEC §21.5): its strokes in the edit recipe, where a brushed point lies on the original, and the fill.
@Suite struct InpaintingTests {
    static let brush = RetouchStroke.brush(
        RetouchStroke.Brush(radius: 0.05, points: [RetouchPoint(x: 0.4, y: 0.5), RetouchPoint(x: 0.6, y: 0.5)]))

    static func area() -> RetouchStroke {
        var mask = [UInt8](repeating: 0, count: 40 * 30)
        for y in 10..<20 { for x in 5..<15 { mask[y * 40 + x] = 255 } }
        return .area(RetouchStroke.Area.from(mask: mask, width: 40, height: 30)!)
    }

    // MARK: Recipe

    @Test func strokesRoundTripInTheRecipe() throws {
        let recipe = EditRecipe(
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), retouch: RetouchSteps(strokes: [Self.brush, Self.area()]))
        let data = try recipe.encoded()
        let decoded = try EditRecipe.decode(data)
        #expect(decoded.retouch == recipe.retouch && decoded.edits == recipe.edits && decoded.updatedAt == recipe.updatedAt)
        #expect(decoded.version == 2)
        #expect(!decoded.isIdentity && decoded.changesStill)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"retouch\"") && text.contains("\"runs\""))
    }

    /// Removals need format version 2 (an older app shows the original instead of the object), and they belong to one
    /// photo: Copy Edits and presets leave them out, Paste Edits keeps the target's own.
    @Test func strokesAreVersion2AndNotPartOfALook() throws {
        let steps = RetouchSteps(strokes: [Self.brush])
        var recipe = EditRecipe(retouch: steps)
        recipe.edits.exposure = 0.5
        #expect(recipe.requiredVersion == 2)
        #expect(try EditRecipe.decode(try recipe.encoded()).retouch == steps)
        #expect(recipe.look.retouch == nil)
        let other = EditRecipe(retouch: RetouchSteps(strokes: [Self.area()]))
        #expect(other.withLook(recipe, developsRAW: false).retouch == other.retouch)
        #expect(EditRecipe(edits: recipe.edits).requiredVersion == 1)
    }

    @Test func noStrokesIsNoEditAndIsNotWritten() throws {
        let recipe = EditRecipe(retouch: RetouchSteps())
        #expect(recipe.isIdentity && !recipe.changesStill)
        #expect(!String(decoding: try recipe.encoded(), as: UTF8.self).contains("retouch"))
        #expect(try EditRecipe.decode(try recipe.encoded()).retouch == nil)
    }

    /// A newer app's stroke kind, or a broken stroke, is skipped; the others are still removed.
    @Test func unknownAndBrokenStrokesAreSkipped() throws {
        let json = """
            { "format": "nextcloud-photos-edit", "version": 1, "retouch": { "strokes": [
              { "lasso": { "points": [[0, 0]] } },
              { "area": { "width": 2, "height": 2, "runs": [1, 5] } },
              { "brush": { "radius": 0.02, "points": [[0.5, 0.5], [2, -1]] } } ] } }
            """
        let recipe = try EditRecipe.decode(Data(json.utf8))
        #expect(recipe.retouch?.strokes.count == 1)
        guard case .brush(let brush) = recipe.retouch?.strokes.first else {
            Issue.record("no brush")
            return
        }
        // Points off the picture are kept on its edge.
        #expect(brush.points == [RetouchPoint(x: 0.5, y: 0.5), RetouchPoint(x: 1, y: 0)])
    }

    @Test func areasAreSmallRunLengthsOfTheMask() throws {
        var mask = [UInt8](repeating: 0, count: 1000 * 500)
        for y in 100..<200 { for x in 300..<500 { mask[y * 1000 + x] = 200 } }
        let area = try #require(RetouchStroke.Area.from(mask: mask, width: 1000, height: 500))
        #expect(area.width == RetouchStroke.Area.maxSide && area.height == 96)
        #expect(area.runs.count == 1 + 2 * 20)
        let bounds = try #require(area.bounds)
        #expect(abs(bounds.minX - 0.3) < 0.01 && abs(bounds.maxX - 0.5) < 0.01)
        #expect(abs(bounds.minY - 0.2) < 0.02 && abs(bounds.maxY - 0.4) < 0.02)
        #expect(RetouchStroke.Area.from(mask: [UInt8](repeating: 0, count: 100), width: 10, height: 10) == nil)
        #expect(RetouchStroke.Area(width: 2, height: 2, runs: [1, 2]).cells == nil)
    }

    @Test func strokesAreStoredRounded() {
        guard
            case .brush(let brush) = RetouchStroke.brush(
                RetouchStroke.Brush(radius: 0.0123456789, points: [RetouchPoint(x: 1 / 3, y: 2 / 3)]))
        else { return }
        #expect(brush.radius == 0.01235 && brush.points[0].x == 0.33333)
    }

    // MARK: Geometry

    /// A white dot on black at `point` (fractions, top left) of a 400 × 300 picture.
    static func dot(at point: CGPoint) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let dot = CIImage(color: .white).cropped(to: CGRect(x: point.x * 400 - 3, y: (1 - point.y) * 300 - 3, width: 6, height: 6))
        return dot.composited(over: black)
    }

    /// The middle of the white pixels, in fractions with the origin at the top left.
    static func whiteCentre(_ image: CIImage) -> CGPoint? {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        PhotoEditor.context.render(
            image, toBitmap: &bytes, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var sx = 0.0
        var sy = 0.0
        var count = 0.0
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4] > 128 {
                sx += Double(x) + 0.5
                sy += Double(y) + 0.5
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CGPoint(x: sx / count / Double(width), y: sy / count / Double(height))
    }

    static var geometries: [PhotoEdits] {
        var turned = PhotoEdits()
        turned.rotate(clockwise: true)
        var flipped = PhotoEdits()
        flipped.flip()
        flipped.rotate(clockwise: false)
        var straightened = PhotoEdits()
        straightened.straighten = 7
        var cropped = PhotoEdits()
        cropped.crop = CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        var everything = straightened
        everything.rotate(clockwise: true)
        everything.flip()
        everything.crop = CropRect(x: 0.15, y: 0.05, width: 0.7, height: 0.8)
        var preset = PhotoEdits()
        preset.aspect = .square
        return [PhotoEdits(), turned, flipped, straightened, cropped, everything, preset]
    }

    /// The mapping follows `PhotoEditor.apply` exactly: a dot on the original lands where the mapping says.
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU), arguments: geometries)
    func pointsFollowTheEditorsGeometry(_ edits: PhotoEdits) throws {
        let point = CGPoint(x: 0.45, y: 0.4)
        let rendered = PhotoEditor.apply(edits, to: Self.dot(at: point))
        let seen = try #require(Self.whiteCentre(rendered))
        let size = CGSize(width: 400, height: 300)
        let mapped = RetouchGeometry.editedPoint(point, edits: edits, originalSize: size)
        let (_, edited) = RetouchGeometry.transform(edits, originalSize: size)
        #expect(abs(edited.width - rendered.extent.width) < 1.5 && abs(edited.height - rendered.extent.height) < 1.5)
        #expect(abs(mapped.x - seen.x) * edited.width < 1.5, "x: \(mapped.x) vs \(seen.x)")
        #expect(abs(mapped.y - seen.y) * edited.height < 1.5, "y: \(mapped.y) vs \(seen.y)")
        let back = try #require(RetouchGeometry.originalPoint(mapped, edits: edits, originalSize: size))
        #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
    }

    @Test func pointsCutOffByTheCropAreNotOnThePicture() {
        var edits = PhotoEdits()
        edits.straighten = 20
        // The corners of a straightened picture are still on the original; a point beside the picture is not.
        #expect(RetouchGeometry.originalPoint(CGPoint(x: 0, y: 0), edits: edits, originalSize: CGSize(width: 400, height: 300)) != nil)
        #expect(
            RetouchGeometry.originalPoint(CGPoint(x: -0.5, y: 0.5), edits: PhotoEdits(), originalSize: CGSize(width: 4, height: 3)) == nil)
    }

    // MARK: Filling

    /// Fills every masked pixel with pure red and counts its calls.
    final class RedFill: InpaintingEngine, Sendable {
        let identifier: String
        let side = 256
        let calls = Mutex(0)
        init(_ identifier: String = "red-\(UUID().uuidString)") { self.identifier = identifier }

        func fill(image: CGImage, mask: CGImage) throws -> CGImage {
            calls.withLock { $0 += 1 }
            let holes = try #require(DiffusionFill.grey(mask, side: side))
            var pixels = try #require(DiffusionFill.rgba(image, side: side))
            for index in holes.indices where holes[index] != 0 {
                pixels[index * 4] = 255
                pixels[index * 4 + 1] = 0
                pixels[index * 4 + 2] = 0
                pixels[index * 4 + 3] = 255
            }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            return try #require(
                CGImage(
                    width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: Inpainting.sRGB,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
        }
    }

    static func grey(_ value: CGFloat, width: CGFloat = 1000, height: CGFloat = 600) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Two RGBA pixels that differ by at most one level per channel.
    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    }

    static func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        PhotoEditor.context.render(
            image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
            colorSpace: Inpainting.sRGB)
        return bytes
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func onlyTheStrokeIsFilled() {
        let engine = RedFill()
        let input = Self.grey(0.5)
        let output = Inpainting.apply(RetouchSteps(strokes: [Self.brush]), to: input, engine: engine)
        #expect(output.extent == input.extent)
        // The stroke runs from 40 % to 60 % across, in the middle (y 300 of 600 from the bottom too).
        let inside = Self.pixel(output, x: 500, y: 300)
        #expect(inside[0] > 240 && inside[1] < 15)
        let grey = Self.pixel(input, x: 0, y: 0)
        // Untouched, up to one level of rounding in the compositing (CI's GPU gave 127 for 128).
        let outside = Self.pixel(output, x: 100, y: 300)
        #expect(Self.alike(outside, grey), "\(outside) vs \(grey)")
        let below = Self.pixel(output, x: 500, y: 200)
        #expect(Self.alike(below, grey), "\(below) vs \(grey)")
    }

    /// Adjusting colours, undo and the next rendition reuse the filled areas; another picture fills again.
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func filledAreasAreReused() {
        let engine = RedFill()
        let input = Self.grey(0.5)
        let one = RetouchSteps(strokes: [Self.brush])
        let two = one.adding(Self.area())
        _ = Inpainting.apply(two, to: input, engine: engine)
        #expect(engine.calls.withLock { $0 } == 2)
        _ = Inpainting.apply(two, to: input, engine: engine)
        _ = Inpainting.apply(one, to: input, engine: engine)
        #expect(engine.calls.withLock { $0 } == 2)
        _ = Inpainting.apply(one, to: Self.grey(0.3), engine: engine)
        #expect(engine.calls.withLock { $0 } == 3)
        // Another picture of the same size on the main thread may use the area made for the first (no wait), elsewhere not.
        _ = Inpainting.apply(one, to: Self.grey(0.2), engine: engine, allowStale: true)
        #expect(engine.calls.withLock { $0 } == 3)
    }

    @Test func windowsGiveContextAndStayOnThePicture() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        // A small object: a window of the engine's side at full resolution.
        let small = Inpainting.window(around: CGRect(x: 10, y: 10, width: 50, height: 40), in: extent, side: 800)
        #expect(small == CGRect(x: 0, y: 0, width: 800, height: 800))
        // A large one: 2.2 times its size, scaled down for the engine.
        let large = Inpainting.window(around: CGRect(x: 1000, y: 1000, width: 1000, height: 500), in: extent, side: 800)
        #expect(large.width == 2200 && large.height == 2200 && large.minX == 400 && large.minY == 150)
        // Larger than the picture: the whole picture.
        let huge = Inpainting.window(around: CGRect(x: 0, y: 0, width: 3900, height: 2900), in: extent, side: 800)
        #expect(huge == extent)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func theBasicFillContinuesTheSurroundings() throws {
        // A black square on white: filled, it is white again.
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let square = CIImage(color: .black).cropped(to: CGRect(x: 280, y: 180, width: 40, height: 40))
        let input = square.composited(over: white)
        let stroke = RetouchStroke.brush(RetouchStroke.Brush(radius: 0.08, points: [RetouchPoint(x: 0.5, y: 0.5)]))
        let output = Inpainting.apply(RetouchSteps(strokes: [stroke]), to: input, engine: DiffusionFill())
        #expect(Self.pixel(output, x: 300, y: 200)[0] > 245)
        // A gradient stays a gradient: the fill lies between its sides.
        let left = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let right = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 300, y: 0, width: 300, height: 400))
        let split = left.composited(over: right)
        let filled = Inpainting.apply(RetouchSteps(strokes: [stroke]), to: split, engine: DiffusionFill())
        let middle = Self.pixel(filled, x: 300, y: 200)[0]
        #expect(middle > 110 && middle < 220)
    }

    /// The step runs inside `EditRendering.apply`: the recipe's strokes are removed in every rendition.
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU))
    func renditionsRemoveTheStrokes() throws {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let dot = CIImage(color: .black).cropped(to: CGRect(x: 290, y: 190, width: 20, height: 20))
        let stroke = RetouchStroke.brush(RetouchStroke.Brush(radius: 0.06, points: [RetouchPoint(x: 0.5, y: 0.5)]))
        var recipe = EditRecipe(retouch: RetouchSteps(strokes: [stroke]))
        recipe.edits.rotate(clockwise: true)
        let output = EditRendering.apply(recipe, to: dot.composited(over: white))
        #expect(output.extent.size == CGSize(width: 400, height: 600))
        #expect(Self.pixel(output, x: 200, y: 300)[0] > 230)
    }

    @Test func peopleMuchSmallerThanTheSubjectAreTheBackground() {
        #expect(RetouchSelection.backgroundShares([0.3, 0.02, 0.1, 0.05]) == [1, 3])
        #expect(RetouchSelection.backgroundShares([0.3]).isEmpty)
        #expect(RetouchSelection.backgroundShares([0.01, 0.001]).isEmpty)
    }
}

/// Before and after pictures for SPEC §21.5's quality evidence, with the Erase tool's fill: run with
/// `TEST_RUNNER_PHOTOS_INPAINTING_EVAL=<folder>` holding `eval.json` (`[{"file", "taps": [[x, y]], "brushes":
/// [{"radius", "points": [[x, y]]}], "backgroundPeople": bool}]`, fractions from the top left) and the photos. Writes
/// `<file>-after.jpg`, `<file>-mask.jpg` and `timings.txt` there.
@Suite struct InpaintingEvaluation {
    struct Case: Decodable {
        var file: String
        var taps: [[Double]]?
        var brushes: [Brush]?
        var backgroundPeople: Bool?
        struct Brush: Decodable {
            var radius: Double
            var points: [[Double]]
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_INPAINTING_EVAL"] != nil))
    func beforeAndAfter() throws {
        let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["PHOTOS_INPAINTING_EVAL"]))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: folder.appending(path: "eval.json")))
        let engine = Inpainting.engine
        var log = ""
        for item in cases {
            let input = try #require(PhotoEditor.load(folder.appending(path: item.file)))
            let small = try #require(Self.small(input))
            var strokes = [RetouchStroke]()
            for tap in item.taps ?? [] {
                if let stroke = RetouchSelection.object(at: CGPoint(x: tap[0], y: tap[1]), in: small) {
                    strokes.append(stroke)
                } else {
                    log += "\(item.file): nothing at \(tap)\n"
                }
            }
            for brush in item.brushes ?? [] {
                let points = brush.points.map { RetouchPoint(x: $0[0], y: $0[1]) }
                strokes.append(.brush(RetouchStroke.Brush(radius: brush.radius, points: points)))
            }
            if item.backgroundPeople == true {
                let people = RetouchSelection.backgroundPeople(in: small)
                log += "\(item.file): \(people.count) people in the background\n"
                strokes += people
            }
            let steps = RetouchSteps(strokes: strokes)
            Inpainting.cache.removeAll()
            let start = Date()
            let output = Inpainting.apply(steps, to: input, engine: engine)
            let cg = try #require(PhotoEditor.context.createCGImage(output, from: output.extent))
            let seconds = Date().timeIntervalSince(start)
            log += String(
                format: "%@: %d strokes, %.0f × %.0f, %.2f s\n", item.file, strokes.count, input.extent.width, input.extent.height, seconds)
            try Self.writeJPEG(CIImage(cgImage: cg), to: folder.appending(path: "\(item.file)-after.jpg"))
            // The strokes in red over the photo: what was asked to go.
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.55)).cropped(to: input.extent)
            var shown = input
            for stroke in strokes {
                let mask = RedMask(stroke: stroke)
                shown = Inpainting.apply(RetouchSteps(strokes: [stroke]), to: shown, engine: mask)
            }
            _ = red
            try Self.writeJPEG(shown, to: folder.appending(path: "\(item.file)-mask.jpg"))
        }
        try log.write(to: folder.appending(path: "timings.txt"), atomically: true, encoding: .utf8)
    }

    /// Paints the masked area red: shows the strokes as they are filled.
    struct RedMask: InpaintingEngine {
        let stroke: RetouchStroke
        var identifier: String { "mask-\(UUID().uuidString)" }
        let side = 800
        func fill(image: CGImage, mask: CGImage) throws -> CGImage {
            let holes = try #require(DiffusionFill.grey(mask, side: side))
            var pixels = try #require(DiffusionFill.rgba(image, side: side))
            for index in holes.indices where holes[index] != 0 {
                pixels[index * 4] = UInt8(min(255, Int(pixels[index * 4]) / 2 + 128))
                pixels[index * 4 + 1] /= 2
                pixels[index * 4 + 2] /= 2
            }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            return try #require(
                CGImage(
                    width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: Inpainting.sRGB,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
        }
    }

    static func small(_ image: CIImage) -> CGImage? {
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return PhotoEditor.context.createCGImage(scaled, from: scaled.extent.integral)
    }

    static func writeJPEG(_ image: CIImage, to url: URL) throws {
        try PhotoEditor.context.writeJPEGRepresentation(
            of: image, to: url, colorSpace: Inpainting.sRGB,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    }
}
