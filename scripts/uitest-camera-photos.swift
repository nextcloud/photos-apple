// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

// Test photos for `PeopleTourTests.testCameraChip`: three JPEGs with the EXIF of a Fujifilm X100V.
//
//     swift scripts/uitest-camera-photos.swift <folder>
//
// Upload them to the test server (e.g. into `/Photos/r12-camera-test`; the server reads Make/Model on upload), run the
// tour, and remove the folder afterwards.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.6, 0.2), (0.2, 0.55, 0.85), (0.3, 0.7, 0.4)]
for (index, color) in colors.enumerated() {
    let context = CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.8)
    context.fillEllipse(in: CGRect(x: 400, y: 200, width: 400, height: 400))
    let url = out.appendingPathComponent("x100v-\(index + 1).jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X100V"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2025:11:2\(index + 1) 10:00:00", kCGImagePropertyExifLensModel: "23mm F2",
        ],
    ]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    print(url.path)
}
