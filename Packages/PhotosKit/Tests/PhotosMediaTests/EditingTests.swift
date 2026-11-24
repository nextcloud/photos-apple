// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosMedia

@Suite struct EditingTests {
    let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))

    @Test func identityKeepsSize() {
        #expect(PhotoEditor.apply(PhotoEdits(), to: image).extent.size == CGSize(width: 400, height: 300))
    }

    @Test func rotationSwapsDimensions() {
        var edits = PhotoEdits()
        edits.rotation = 1
        let out = PhotoEditor.apply(edits, to: image).extent
        #expect(Int(out.width.rounded()) == 300 && Int(out.height.rounded()) == 400)
        #expect(out.origin == .zero)
    }

    @Test func squareCrop() {
        var edits = PhotoEdits()
        edits.aspect = .square
        let out = PhotoEditor.apply(edits, to: image).extent
        #expect(Int(out.width) == 300 && Int(out.height) == 300)
    }

    @Test func blurHashDecodes() {
        let decoded = BlurHash.decode("LdH:5yIWWXt7X=M{a#j]I^tSoKWC", width: 8, height: 8)
        #expect(decoded?.width == 8)
        #expect(BlurHash.decode("short") == nil)
    }
}

/// Free-form crop, the turn and mirror order, and writing the result (SPEC §7.16.1, §7.16.2).
@Suite struct CropAndSaveTests {
    let size = CGSize(width: 400, height: 300)

    /// A 400×300 picture, blue with a red quarter at the top left (as shown).
    var marked: CIImage {
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 150, width: 200, height: 150))
        return red.composited(over: blue)
    }

    /// The colour at `x`, `y` counted from the top left, as shown.
    func isRed(_ image: CIImage, x: Int, y: Int) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let extent = image.extent
        let bounds = CGRect(x: extent.minX + CGFloat(x), y: extent.maxY - 1 - CGFloat(y), width: 1, height: 1)
        PhotoEditor.context.render(
            image, toBitmap: &pixel, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel[0] > 200 && pixel[2] < 60
    }

    @Test func turnsFollowWhatIsShown() {
        var edits = PhotoEdits()
        edits.rotate(clockwise: true)
        let turned = PhotoEditor.apply(edits, to: marked)
        #expect(turned.extent.size == CGSize(width: 300, height: 400))
        // The red corner went from the top left to the top right.
        #expect(isRed(turned, x: 290, y: 10))
        #expect(!isRed(turned, x: 10, y: 10))
    }

    /// The bug: the mirror was applied before the turns, so after a turn "Flip" mirrored top to bottom.
    @Test func flipMirrorsLeftToRightAfterATurn() {
        var edits = PhotoEdits()
        edits.rotate(clockwise: true)
        edits.flip()
        let out = PhotoEditor.apply(edits, to: marked)
        #expect(isRed(out, x: 10, y: 10))
        #expect(!isRed(out, x: 10, y: 390))
        #expect(!isRed(out, x: 290, y: 10))
    }

    @Test func aTurnOnAMirroredPictureTurnsTheWayShown() {
        var edits = PhotoEdits()
        edits.flip()  // red at the top right
        edits.rotate(clockwise: false)  // shown: the top right goes to the top left
        let out = PhotoEditor.apply(edits, to: marked)
        #expect(out.extent.size == CGSize(width: 300, height: 400))
        #expect(isRed(out, x: 10, y: 10))
        #expect(!isRed(out, x: 290, y: 10))
    }

    @Test func freeCropKeepsTheChosenArea() {
        var edits = PhotoEdits()
        edits.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let out = PhotoEditor.apply(edits, to: marked)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 200, height: 150))
        #expect(isRed(out, x: 100, y: 75))
        edits.crop = CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        #expect(!isRed(PhotoEditor.apply(edits, to: marked), x: 100, y: 75))
    }

    @Test func cropTurnsAndMirrorsWithThePicture() {
        var edits = PhotoEdits()
        // The red quarter.
        edits.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        edits.rotate(clockwise: true)
        #expect(edits.crop.map { close($0, CropRect(x: 0.5, y: 0, width: 0.5, height: 0.5)) } == true)
        edits.flip()
        #expect(edits.crop.map { close($0, CropRect(x: 0, y: 0, width: 0.5, height: 0.5)) } == true)
        edits.rotate(clockwise: false)
        let out = PhotoEditor.apply(edits, to: marked)
        // Still exactly the red quarter, whatever the turns.
        #expect(isRed(out, x: 2, y: 2) && isRed(out, x: Int(out.extent.width) - 3, y: Int(out.extent.height) - 3))
    }

    func close(_ a: CropRect, _ b: CropRect) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test func rotatingFourTimesGivesTheSameCrop() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        var turned = crop
        for _ in 0..<4 { turned = turned.rotatedClockwise() }
        #expect(abs(turned.x - crop.x) < 1e-9 && abs(turned.y - crop.y) < 1e-9)
        #expect(close(crop.rotatedClockwise().rotatedCounterclockwise(), crop))
        #expect(close(crop.flippedHorizontally().flippedHorizontally(), crop))
    }

    @Test func presetsAreCenteredAndFollowTheOrientation() {
        let square = CropRect.centered(aspect: 1, in: size)
        #expect(abs(square.width - 0.75) < 1e-9 && square.height == 1 && abs(square.x - 0.125) < 1e-9)
        #expect(PhotoEdits.Aspect.fourThree.pixelAspect(for: CGSize(width: 300, height: 400)) == 3.0 / 4)
        #expect(PhotoEdits.Aspect.original.pixelAspect(for: size) == 4.0 / 3)
        #expect(PhotoEdits.Aspect.free.pixelAspect(for: size) == nil)
        var edits = PhotoEdits()
        edits.aspect = .sixteenNine
        let area = PhotoEditor.cropArea(edits, size: size)
        #expect(area.map { abs($0.pixelAspect(in: size) - 16.0 / 9) < 1e-9 } == true)
        // An own crop wins over the preset's middle.
        edits.crop = CropRect(x: 0, y: 0, width: 1, height: 0.5)
        #expect(PhotoEditor.cropArea(edits, size: size) == edits.crop)
    }

    @Test func dragsMoveTheEdgesAndStayOnThePicture() {
        let start = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let corner = start.dragged(.bottomRight, dx: 0.1, dy: -0.1, in: size)
        #expect(abs(corner.maxX - 0.9) < 1e-9 && abs(corner.maxY - 0.7) < 1e-9 && corner.x == 0.2 && corner.y == 0.2)
        // Past the picture's edge: stops at it.
        let wide = start.dragged(.left, dx: -0.5, dy: 0, in: size)
        #expect(wide.x == 0 && abs(wide.maxX - 0.8) < 1e-9 && abs(wide.height - start.height) < 1e-9)
        // Onto the opposite edge: a minimum size is kept.
        let thin = start.dragged(.top, dx: 0, dy: 0.9, in: size)
        #expect(abs(thin.height - CropRect.minimumSide) < 1e-9 && abs(thin.maxY - 0.8) < 1e-9)
        // Moving keeps the size and stays inside.
        let moved = start.dragged(.move, dx: 0.5, dy: -0.5, in: size)
        #expect(moved.width == start.width && abs(moved.maxX - 1) < 1e-9 && moved.y == 0)
    }

    @Test func aLockedDragKeepsTheAspect() {
        let start = CropRect.centered(aspect: 1, in: size).scaled(by: 0.5)
        let aspect = start.pixelAspect(in: size)
        for handle in CropRect.Handle.allCases where handle != .move {
            let out = start.dragged(handle, dx: 0.07, dy: 0.03, lockedAspect: aspect, in: size)
            #expect(abs(out.pixelAspect(in: size) - aspect) < 1e-9, "\(handle)")
            #expect(out.x >= -1e-9 && out.y >= -1e-9 && out.maxX <= 1 + 1e-9 && out.maxY <= 1 + 1e-9, "\(handle)")
        }
        // A corner keeps the opposite one in place.
        let grown = start.dragged(.topLeft, dx: -0.05, dy: -0.05, lockedAspect: aspect, in: size)
        #expect(abs(grown.maxX - start.maxX) < 1e-9 && abs(grown.maxY - start.maxY) < 1e-9 && grown.width > start.width)
        // As far as the picture goes, still in the aspect.
        let huge = start.dragged(.bottomRight, dx: 5, dy: 5, lockedAspect: aspect, in: size)
        #expect(abs(huge.maxY - 1) < 1e-9 && abs(huge.pixelAspect(in: size) - aspect) < 1e-9)
    }

    @Test func scalingStaysOnThePicture() {
        let crop = CropRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        let larger = crop.scaled(by: 5)
        #expect(abs(larger.width - 1) < 1e-9 && abs(larger.x) < 1e-9 && abs(larger.y) < 1e-9)
        // Larger around its middle, pushed back onto the picture.
        let bit = crop.scaled(by: 2)
        #expect(abs(bit.width - 0.6) < 1e-9 && abs(bit.maxX - 1) < 1e-9)
        let smaller = crop.scaled(by: 0.01)
        #expect(abs(smaller.width - CropRect.minimumSide) < 1e-9)
    }

    @Test func aLockOrAWholeCropIsNoEdit() {
        var edits = PhotoEdits()
        edits.aspectLocked = true
        edits.crop = .full
        #expect(edits.isIdentity)
        edits.aspect = .free
        #expect(edits.isIdentity)
        edits.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(!edits.isIdentity)
    }

    func writePNG(width: Int, height: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The cached original has a cache name, not the photo's.
        let url = folder.appending(path: "123-abcdef.png")
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        try PhotoEditor.context.writePNGRepresentation(
            of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return url
    }

    /// The bugs: "Overwrite original" wrote JPEG data over a PNG, and the copy was named after the cache file.
    @Test func replacingKeepsFormatAndNameCopiesAreNamedAfterThePhoto() throws {
        let original = try writePNG(width: 40, height: 30)
        let folder = original.deletingLastPathComponent()
        var edits = PhotoEdits()
        edits.rotate(clockwise: true)
        let replaced = try PhotoEditor.render(edits, original: original, name: "Sunset.png", replacingOriginal: true, to: folder)
        #expect(replaced.lastPathComponent == "Sunset.png")
        let source = try #require(CGImageSourceCreateWithURL(replaced as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 30)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 40)
        let copy = try PhotoEditor.render(edits, original: original, name: "Sunset.png", to: folder)
        #expect(copy.lastPathComponent == "Sunset (edited).jpg")
    }

    @Test func onlyWritableFormatsAreReplaced() {
        #expect(PhotoEditor.canRewrite(fileName: "a.JPG"))
        #expect(PhotoEditor.canRewrite(fileName: "a.heic"))
        #expect(PhotoEditor.canRewrite(fileName: "a.png"))
        #expect(!PhotoEditor.canRewrite(fileName: "a.dng"))
        #expect(!PhotoEditor.canRewrite(fileName: "a.gif"))
        #expect(!PhotoEditor.canRewrite(fileName: "noextension"))
    }
}
