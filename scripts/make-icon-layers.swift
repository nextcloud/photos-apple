// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT
//
// Makes the layered app icons that Icon Composer does not cover, from `icon/Photos App Icon.icon`:
//   - tvOS: the App Icon (400×240 pt) and App Store icon (1280×768), each with three layers, and both Top Shelf images;
//   - visionOS: `AppIcon.solidimagestack` with three 1024 px layers.
// Back is the icon's gradient, Middle the hills and Front the sun, as in the `.icon` file, so they part when the icon
// tilts (Apple TV focus, Vision Pro gaze).
//
// Run from the repository root: `swift scripts/make-icon-layers.swift`

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconAssets = root.appending(path: "icon/Photos App Icon.icon/Assets")
let sun = NSImage(contentsOf: iconAssets.appending(path: "Photos-white-1.svg"))!
let hills = NSImage(contentsOf: iconAssets.appending(path: "Photos-white-2.svg"))!

/// The `.icon` file's fill: light blue at the top, Nextcloud blue (#0082c9) from 70 % of the height down.
let top = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.1098, 0.6863, 1, 1])!
let bottom = CGColor(srgbRed: 0, green: 130 / 255, blue: 201 / 255, alpha: 1)

enum Layer { case back, middle, front, flat }

/// One layer, `width`×`height` pixels, with the 24-pt glyph grid of side `grid` px centred.
func render(_ layer: Layer, width: Int, height: Int, grid: CGFloat) -> Data {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let size = CGSize(width: width, height: height)
    if layer == .back || layer == .flat {
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 0.7])!
        // Core Graphics' y axis points up: the top of the picture is at `height`.
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    let glyphs: [NSImage] =
        switch layer {
        case .back: []
        case .middle: [hills]
        case .front: [sun]
        case .flat: [hills, sun]
        }
    let box = CGRect(x: (size.width - grid) / 2, y: (size.height - grid) / 2, width: grid, height: grid)
    for glyph in glyphs { draw(glyph, in: box, on: context, canvas: size) }
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

/// A white glyph as a glass layer of the `.icon` file: slightly translucent towards the bottom, with a soft shadow.
func draw(_ glyph: NSImage, in box: CGRect, on context: CGContext, canvas: CGSize) {
    // The glyph alone first, so that its fade does not touch what is below it.
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let layer = CGContext(
        data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: layer, flipped: false)
    glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    layer.setBlendMode(.destinationIn)
    let fade = CGGradient(
        colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.82)] as CFArray, locations: [0, 1])!
    layer.drawLinearGradient(fade, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    let unit = box.width / 24
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -unit * 0.35), blur: unit * 1.2, color: CGColor(gray: 0, alpha: 0.28))
    context.draw(layer.makeImage()!, in: CGRect(origin: .zero, size: canvas))
    context.restoreGState()
}

func write(_ data: Data, to path: String) {
    let url = root.appending(path: path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func writeJSON(_ object: Any, to path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    write(data + Data("\n".utf8), to: path)
}

let info: [String: Any] = ["author": "xcode", "version": 1]
/// The glyph grid relative to the shorter side: the `.icon` file draws the 24-pt grid at 31.6 × on 1024 px (74 %).
let iconGrid: CGFloat = 0.74

// MARK: tvOS

let brand = "App/TV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
let layers: [(name: String, layer: Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
for stack in [
    (name: "App Icon", width: 400, height: 240, scales: [1, 2]), (name: "App Icon - App Store", width: 1280, height: 768, scales: [1]),
] {
    let folder = "\(brand)/\(stack.name).imagestack"
    try? FileManager.default.removeItem(at: root.appending(path: folder))
    writeJSON(["layers": layers.map { ["filename": "\($0.name).imagestacklayer"] }, "info": info], to: "\(folder)/Contents.json")
    for (name, layer) in layers {
        let base = "\(folder)/\(name).imagestacklayer"
        writeJSON(["info": info], to: "\(base)/Contents.json")
        var images: [[String: Any]] = []
        for scale in stack.scales {
            let file = scale == 1 ? "image.png" : "image@\(scale)x.png"
            let width = stack.width * scale
            let height = stack.height * scale
            write(render(layer, width: width, height: height, grid: CGFloat(height) * iconGrid), to: "\(base)/Content.imageset/\(file)")
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        writeJSON(["images": images, "info": info], to: "\(base)/Content.imageset/Contents.json")
    }
}
// The Top Shelf: the whole icon, smaller, on the gradient across the width.
for shelf in [(name: "Top Shelf Image", width: 1920), (name: "Top Shelf Image Wide", width: 2320)] {
    for scale in [1, 2] {
        let file = scale == 1 ? "image.png" : "image@\(scale)x.png"
        let height = 720 * scale
        write(
            render(.flat, width: shelf.width * scale, height: height, grid: CGFloat(height) * 0.5),
            to: "\(brand)/\(shelf.name).imageset/\(file)")
    }
}

// MARK: visionOS

// A circle: the glyph grid smaller than on the square icons, so the sun stays clear of the edge.
let vision = "App/Resources/Assets.xcassets/AppIcon.solidimagestack"
try? FileManager.default.removeItem(at: root.appending(path: vision))
writeJSON(["layers": layers.map { ["filename": "\($0.name).solidimagestacklayer"] }, "info": info], to: "\(vision)/Contents.json")
for (name, layer) in layers {
    let base = "\(vision)/\(name).solidimagestacklayer"
    writeJSON(["info": info], to: "\(base)/Contents.json")
    write(render(layer, width: 1024, height: 1024, grid: 1024 * 0.62), to: "\(base)/Content.imageset/\(name.lowercased()).png")
    writeJSON(
        ["images": [["filename": "\(name.lowercased()).png", "idiom": "vision", "scale": "2x"]], "info": info],
        to: "\(base)/Content.imageset/Contents.json")
}
print("tvOS and visionOS icon layers written")
