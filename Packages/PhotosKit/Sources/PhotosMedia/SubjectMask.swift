// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import PhotosDomain
import PhotosModel
import UniformTypeIdentifiers
import Vision

/// The subject of a cover photo as a mask, for the depth effect of album covers (SPEC §16.8.2).
public struct SubjectMask: Sendable {
    /// White where the subject is, transparent elsewhere; the size of the photo it was made from.
    public let image: CGImage
    /// Share of the title band of a square cover that the subject hides (`DepthCoverLayout.coverage`).
    public let squareCoverage: Double

    public var placement: DepthCoverLayout.Placement { DepthCoverLayout.placement(coverage: squareCoverage) }
}

/// Lifts the subject of a photo with Vision, on the device.
public enum SubjectMasking {
    /// The subjects (people, pets, objects in front) of `image` as a mask the size of the image. Synchronous and slow (a
    /// few hundred milliseconds): call it off the main thread.
    public static func mask(of image: CGImage) throws -> SubjectMask {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw StickerMaker.Failure.unavailable
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw StickerMaker.Failure.noSubject }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        guard let (alpha, width, height) = alphaBytes(of: buffer) else { throw StickerMaker.Failure.noSubject }
        return try make(alpha: alpha, width: width, height: height)
    }

    /// A mask from alpha bytes (row by row from the top).
    static func make(alpha: [UInt8], width: Int, height: Int) throws -> SubjectMask {
        guard let image = maskImage(alpha: alpha, width: width, height: height) else { throw StickerMaker.Failure.noSubject }
        let visible = DepthCoverLayout.visibleRect(imageWidth: width, imageHeight: height)
        let coverage = DepthCoverLayout.coverage(alpha: alpha, width: width, height: height, visible: visible)
        return SubjectMask(image: image, squareCoverage: coverage)
    }

    /// Vision's mask (one 32-bit float per pixel, 0…1) as bytes.
    static func alphaBytes(of buffer: CVPixelBuffer) -> ([UInt8], Int, Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                alpha[y * width + x] = UInt8(max(0, min(255, (row[x] * 255).rounded())))
            }
        }
        return (alpha, width, height)
    }

    /// White pixels with the mask as their alpha (premultiplied), so a view can use it as a mask directly.
    static func maskImage(alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, alpha.count >= width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let value = alpha[index]
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = value
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The alpha bytes of a mask image read back (8-bit RGBA as `maskImage` makes it, or as a PNG decoder returns it).
    static func alpha(of image: CGImage) -> [UInt8]? {
        let alphaOffset: Int
        switch image.alphaInfo {
        case .premultipliedLast, .last: alphaOffset = 3
        case .premultipliedFirst, .first: alphaOffset = 0
        default: alphaOffset = -1
        }
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8, alphaOffset >= 0, let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return drawnAlpha(of: image) }
        let length = CFDataGetLength(data)
        var alpha = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4 + alphaOffset
                if offset < length { alpha[y * image.width + x] = bytes[offset] }
            }
        }
        return alpha
    }

    /// Any other layout (a PNG decoder may hand back grey and alpha): drawn into an RGBA bitmap on the CPU.
    static func drawnAlpha(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(width * height)).map { bytes[$0 * 4 + 3] }
    }
}

/// Subject masks of cover photos, computed once on the device and kept in the caches folder (SPEC §16.8.2). A photo without
/// a subject is remembered too, so Vision does not run again for it. Masks never leave the device.
public actor SubjectMaskCache {
    public enum Result: Sendable {
        case mask(SubjectMask)
        /// Vision found no subject, or cannot run here (the simulator).
        case none
    }

    public let directory: URL
    private var memory: [String: Result] = [:]
    private var running: [String: Task<Result, Never>] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    nonisolated static func key(fileId: FileID, etag: String) -> String {
        let safe = etag.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "\(fileId)" : "\(fileId)-\(safe)"
    }

    func maskURL(_ key: String) -> URL { directory.appending(path: "\(key).png") }
    func noneURL(_ key: String) -> URL { directory.appending(path: "\(key).none") }

    /// The mask of a photo: from memory, from disk, or made now from the picture `source` gives (a preview).
    public func mask(fileId: FileID, etag: String, source: @escaping @Sendable () async -> CGImage?) async -> Result {
        let key = Self.key(fileId: fileId, etag: etag)
        if let known = memory[key] { return known }
        if let task = running[key] { return await task.value }
        let task = Task { [directory] in
            await Self.load(key: key, directory: directory, source: source)
        }
        running[key] = task
        let result = await task.value
        running[key] = nil
        remember(result, for: key)
        return result
    }

    /// Whether a mask (or the fact that there is none) is known without running Vision.
    public func cached(fileId: FileID, etag: String) -> Result? {
        let key = Self.key(fileId: fileId, etag: etag)
        if let known = memory[key] { return known }
        guard let result = Self.read(key: key, directory: directory) else { return nil }
        remember(result, for: key)
        return result
    }

    /// A few masks stay in memory (a mask is a few megabytes); the rest are read from disk again when needed.
    private func remember(_ result: Result, for key: String) {
        if memory.count >= 24 { memory.removeAll(keepingCapacity: true) }
        memory[key] = result
    }

    static func read(key: String, directory: URL) -> Result? {
        let mask = directory.appending(path: "\(key).png")
        if FileManager.default.fileExists(atPath: directory.appending(path: "\(key).none").path(percentEncoded: false)) {
            return Result.none
        }
        guard let source = CGImageSourceCreateWithURL(mask as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let alpha = SubjectMasking.alpha(of: image),
            let made = try? SubjectMasking.make(alpha: alpha, width: image.width, height: image.height)
        else { return nil }
        return .mask(made)
    }

    static func load(key: String, directory: URL, source: @Sendable () async -> CGImage?) async -> Result {
        if let stored = read(key: key, directory: directory) { return stored }
        guard let picture = await source() else { return .none }
        let result: Result
        let failure: StickerMaker.Failure?
        do {
            result = .mask(try SubjectMasking.mask(of: picture))
            failure = nil
        } catch {
            result = .none
            failure = error as? StickerMaker.Failure
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch result {
        case .mask(let mask):
            if let data = StickerMaker.pngData(mask.image) {
                try? data.write(to: directory.appending(path: "\(key).png"), options: .atomic)
            }
        case .none:
            // "No subject" is a property of the photo; "Vision unavailable" is one of this device: not remembered on disk.
            if failure == .noSubject { try? Data().write(to: directory.appending(path: "\(key).none"), options: .atomic) }
        }
        return result
    }

    /// Removes every stored mask.
    public func removeAll() {
        memory = [:]
        try? FileManager.default.removeItem(at: directory)
    }
}
