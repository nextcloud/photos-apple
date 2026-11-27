// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT
//
// Frames the README's screenshots: each screen gets rounded, device-like corners with a thin dark edge (phone, tablet)
// or keeps its own window corners (window), a soft shadow, and they stand side by side on a soft background card.
// Drawn here with Core Graphics: no device artwork from anyone else.
//
//   swift scripts/frame-screenshots.swift [options] <output.png> <screenshot>[:phone|tablet|window|plain[:height]] …
//
// Options:
//   --height <px>        height of a screen of relative height 1 in the output (default 1000)
//   --gap <fraction>     space between screens, a fraction of --height (default 0.06; negative overlaps them)
//   --margin <fraction>  space around them, a fraction of --height (default 0.08)
//   --background light|dark|none   the card behind the screens (default light; none: only the shadow, transparent)
//   --template <dir>     for a video: draws the first screenshot's frame without its picture and writes
//                        <dir>/background.png, <dir>/mask.png (the screen's rounded shape, white on black, at the
//                        screen's size) and <dir>/geometry.txt ("x y width height" of the screen in the output);
//                        scripts/readme-videos.sh puts the video in with ffmpeg.
//
// `:height` scales one screen relative to the others (an iPhone next to an iPad: 0.8). The output is a PNG with
// transparency outside the card's rounded corners; convert it for the README with cwebp (scripts/readme-videos.sh does).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Kind: String {
    /// iPhone: corners of about 55 pt on a 402 pt wide screen, a thin dark edge.
    case phone
    /// iPad: corners of about 18 pt on a 1032 pt short side, a thin dark edge.
    case tablet
    /// A Mac window (already with its own rounded corners and transparency) or a Vision Pro window: only the shadow.
    case window
    /// A picture without a device (Apple TV, a composition): small rounded corners and the shadow.
    case plain
}

struct Screen {
    var image: CGImage
    var kind: Kind
    var relativeHeight: CGFloat
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(path)") }
    return image
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(path)") }
}

// MARK: - Arguments

var height: CGFloat = 1000
var gap: CGFloat = 0.06
var margin: CGFloat = 0.08
var background = "light"
var templateDirectory: String?
var positional: [String] = []
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(argument) needs a value") }
        return arguments.removeFirst()
    }
    switch argument {
    case "--height": height = CGFloat(Double(value()) ?? 1000)
    case "--gap": gap = CGFloat(Double(value()) ?? 0.06)
    case "--margin": margin = CGFloat(Double(value()) ?? 0.08)
    case "--background": background = value()
    case "--template": templateDirectory = value()
    default: positional.append(argument)
    }
}
guard positional.count >= 2 else {
    fail("usage: frame-screenshots.swift [options] <output.png> <screenshot>[:phone|tablet|window|plain[:height]] …")
}
let output = positional[0]
let screens: [Screen] = positional.dropFirst().map { spec in
    // The path may contain colons only before the kind: split from the end.
    var parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    var relative: CGFloat = 1
    var kind = Kind.phone
    if parts.count >= 3, let number = Double(parts[parts.count - 1]), let parsed = Kind(rawValue: parts[parts.count - 2]) {
        relative = CGFloat(number)
        kind = parsed
        parts.removeLast(2)
    } else if parts.count >= 2, let parsed = Kind(rawValue: parts[parts.count - 1]) {
        kind = parsed
        parts.removeLast()
    }
    return Screen(image: loadImage(parts.joined(separator: ":")), kind: kind, relativeHeight: relative)
}

// MARK: - Geometry

/// A screen placed in the output: the picture's rectangle, its corner radius and the device edge around it.
struct Placement {
    var screen: Screen
    var rect: CGRect
    var radius: CGFloat
    var edge: CGFloat
    var outer: CGRect { rect.insetBy(dx: -edge, dy: -edge) }
}

func placements() -> (size: CGSize, items: [Placement]) {
    var items: [Placement] = []
    var x = height * margin
    var tallest: CGFloat = 0
    for screen in screens {
        let screenHeight = height * screen.relativeHeight
        let scale = screenHeight / CGFloat(screen.image.height)
        let width = CGFloat(screen.image.width) * scale
        let short = min(width, screenHeight)
        let (radius, edge): (CGFloat, CGFloat) =
            switch screen.kind {
            case .phone: (short * 0.137, short * 0.028)
            case .tablet: (short * 0.0175, short * 0.022)
            case .window: (0, 0)
            case .plain: (short * 0.02, 0)
            }
        let rect = CGRect(x: x + edge, y: 0, width: width, height: screenHeight)
        items.append(Placement(screen: screen, rect: rect, radius: radius, edge: edge))
        x += width + 2 * edge + height * gap
        tallest = max(tallest, screenHeight + 2 * edge)
    }
    x += height * (margin - gap)
    // Even sizes: video encoders need them.
    let size = CGSize(width: ceil(x / 2) * 2, height: ceil((tallest + 2 * height * margin) / 2) * 2)
    // Centred vertically.
    for index in items.indices {
        let outerHeight = items[index].rect.height + 2 * items[index].edge
        items[index].rect.origin.y = (size.height - outerHeight) / 2 + items[index].edge
    }
    return (size, items)
}

// MARK: - Drawing

func makeContext(_ size: CGSize) -> CGContext {
    guard
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a \(size) picture") }
    context.interpolationQuality = .high
    return context
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha)
}

func drawCard(_ context: CGContext, size: CGSize) {
    let colors: [CGColor]
    switch background {
    case "none": return
    case "dark": colors = [color(0x2a_3342), color(0x12_161d)]
    default: colors = [color(0xf4_f7_fb), color(0xdd_e5_ef)]
    }
    let card = CGPath(
        roundedRect: CGRect(origin: .zero, size: size), cornerWidth: height * 0.035, cornerHeight: height * 0.035, transform: nil)
    context.saveGState()
    context.addPath(card)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
    // Light from the top left.
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    let radius = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The shadow and the device edge; with `picture` the screenshot too.
func drawScreen(_ context: CGContext, _ item: Placement, picture: Bool) {
    let shadowColor = background == "dark" ? color(0x000000, 0.55) : color(0x1a_2a40, 0.28)
    let outerRadius = item.radius + item.edge
    // Soft shadow under the device (windows bring their own shape: shadow the picture itself).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -height * 0.018), blur: height * 0.06, color: shadowColor)
    if item.screen.kind == .window {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if picture {
            context.draw(item.screen.image, in: item.rect)
        } else {
            context.setFillColor(color(0x000000))
            context.fill(item.rect)
        }
        context.endTransparencyLayer()
    } else {
        context.addPath(roundedPath(item.outer, outerRadius))
        context.setFillColor(item.edge > 0 ? color(0x1c_1c1e) : color(0xffffff))
        context.fillPath()
    }
    context.restoreGState()
    guard item.screen.kind != .window else { return }
    if item.edge > 0 {
        // A lighter rim, as on the metal band of a device.
        context.saveGState()
        context.addPath(roundedPath(item.outer.insetBy(dx: item.edge * 0.12, dy: item.edge * 0.12), outerRadius - item.edge * 0.12))
        context.setStrokeColor(color(0x5a_5c63))
        context.setLineWidth(max(1, item.edge * 0.16))
        context.strokePath()
        context.restoreGState()
    }
    context.saveGState()
    context.addPath(roundedPath(item.rect, item.radius))
    context.clip()
    if picture {
        context.draw(item.screen.image, in: item.rect)
    } else {
        context.clear(item.rect)
    }
    context.restoreGState()
}

let (size, items) = placements()
let context = makeContext(size)
drawCard(context, size: size)
if let directory = templateDirectory {
    guard let first = items.first else { fail("no screenshot") }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    drawScreen(context, first, picture: false)
    writePNG(context.makeImage()!, to: directory + "/background.png")
    // The screen's shape at the screen's size (rounded to even pixels for the video encoder).
    let width = Int(first.rect.width.rounded()) & ~1
    let screenHeight = Int(first.rect.height.rounded()) & ~1
    let mask = makeContext(CGSize(width: width, height: screenHeight))
    mask.setFillColor(color(0x000000))
    mask.fill(CGRect(x: 0, y: 0, width: width, height: screenHeight))
    mask.setFillColor(color(0xffffff))
    mask.addPath(roundedPath(CGRect(x: 0, y: 0, width: width, height: screenHeight), first.radius))
    mask.fillPath()
    writePNG(mask.makeImage()!, to: directory + "/mask.png")
    // ffmpeg's y runs from the top.
    let top = Int((size.height - first.rect.maxY).rounded())
    let geometry = "\(Int(first.rect.minX.rounded())) \(top) \(width) \(screenHeight)\n"
    try? geometry.write(toFile: directory + "/geometry.txt", atomically: true, encoding: .utf8)
} else {
    for item in items { drawScreen(context, item, picture: true) }
}
writePNG(context.makeImage()!, to: output)
print("\(output): \(Int(size.width))×\(Int(size.height))")
