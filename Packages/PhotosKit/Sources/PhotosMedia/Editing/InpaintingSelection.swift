// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// What the Remove tool can pick by itself (SPEC §21.5): the object under a tap, and people in the background. Vision
/// finds them on the device (foreground instances and person instances); nothing leaves the device.
public enum RetouchSelection {
    /// The object at `point` (fractions of `image`, top left origin): the foreground instance (a person, a pet, a thing
    /// in front) there, else the person there. Nil when Vision finds nothing at that point or cannot run (the simulator).
    /// Synchronous and a few hundred milliseconds: call it off the main thread.
    public static func object(at point: CGPoint, in image: CGImage) -> RetouchStroke? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let people = VNGeneratePersonInstanceMaskRequest()
        try? handler.perform([foreground, people])
        for observation in [foreground.results?.first, people.results?.first].compactMap(\.self) {
            guard let instance = instance(of: observation, at: point),
                let buffer = try? observation.generateMask(forInstances: IndexSet(integer: instance)),
                let (alpha, width, height) = SubjectMasking.alphaBytes(of: buffer),
                let area = RetouchStroke.Area.from(mask: alpha, width: width, height: height)
            else { continue }
            return .area(area)
        }
        return nil
    }

    /// People who are not the photo's subject: everybody much smaller than the largest person (a passer-by behind a
    /// portrait, tourists behind a family). Empty when there is one person or nobody, or Vision cannot run.
    public static func backgroundPeople(in image: CGImage) -> [RetouchStroke] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGeneratePersonInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else { return [] }
        var masks = [(area: RetouchStroke.Area, share: Double)]()
        for instance in observation.allInstances {
            guard let buffer = try? observation.generateMask(forInstances: IndexSet(integer: instance)),
                let (alpha, width, height) = SubjectMasking.alphaBytes(of: buffer),
                let area = RetouchStroke.Area.from(mask: alpha, width: width, height: height)
            else { continue }
            masks.append((area, Double(alpha.lazy.filter { $0 >= 128 }.count) / Double(max(1, width * height))))
        }
        return backgroundShares(masks.map(\.share)).map { .area(masks[$0].area) }
    }

    /// Which of the people (by their share of the picture) are in the background: those under a quarter of the largest,
    /// when the largest is a real subject (at least 2 % of the picture). Indices in the order given.
    static func backgroundShares(_ shares: [Double]) -> [Int] {
        guard shares.count >= 2, let largest = shares.max(), largest >= 0.02 else { return [] }
        return shares.indices.filter { shares[$0] > 0 && shares[$0] < largest / 4 }
    }

    /// The instance label under `point` in Vision's low-resolution instance map; nil for the background (label 0).
    static func instance(of observation: VNInstanceMaskObservation, at point: CGPoint) -> Int? {
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // A small neighbourhood: a tap on the thin edge of an object still picks it.
        let cx = Int(point.x * CGFloat(width))
        let cy = Int(point.y * CGFloat(height))
        var counts = [Int: Int]()
        for dy in -2...2 {
            for dx in -2...2 {
                let x = cx + dx
                let y = cy + dy
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let label = Int(base.advanced(by: y * stride + x).assumingMemoryBound(to: UInt8.self).pointee)
                if label != 0 { counts[label, default: 0] += 1 }
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), observation.allInstances.contains(best.key) else { return nil }
        return best.key
    }
}
