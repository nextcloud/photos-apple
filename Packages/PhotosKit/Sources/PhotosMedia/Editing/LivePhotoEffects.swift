// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Averages frames of equal size, pixel by pixel: the long exposure of a Live Photo (SPEC §16.3.3). Pure arithmetic on
/// RGBA bytes, so it runs (and is tested) without a GPU.
public struct FrameAverager: Sendable {
    public let width: Int
    public let height: Int
    private var sums: [UInt32]
    public private(set) var count = 0

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        sums = [UInt32](repeating: 0, count: width * height * 4)
    }

    /// Adds a frame of `width × height` RGBA bytes (rows without padding). Frames of another size are ignored.
    public mutating func add(_ pixels: [UInt8]) {
        guard pixels.count == sums.count else { return }
        pixels.withUnsafeBufferPointer { source in
            sums.withUnsafeMutableBufferPointer { target in
                for index in 0..<target.count { target[index] &+= UInt32(source[index]) }
            }
        }
        count += 1
    }

    /// The average of the frames added (rounded), as RGBA bytes.
    public func average() -> [UInt8] {
        guard count > 0 else { return [UInt8](repeating: 0, count: sums.count) }
        let divisor = UInt32(count)
        let half = divisor / 2
        return sums.map { UInt8(min(255, ($0 + half) / divisor)) }
    }
}

/// Live Photo effects (SPEC §16.3.3) from the motion part of a Live Photo: the key photo, a long exposure, and Loop and
/// Bounce as videos and GIFs.
public enum LivePhotoEffects {
    /// Frames of a long exposure: enough for smooth trails on the 1.5 + 1.5 s of a Live Photo.
    public static let longExposureFrames = 48
    /// Frame rate of exported Loop/Bounce videos and the Bounce played in the viewer.
    static let videoFrameRate: Int32 = 30
    /// GIFs are smaller and play everywhere at this rate.
    static let gifFrameRate = 15.0

    /// The motion's length in seconds.
    public static func duration(of video: URL) async throws -> Double {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        return max(0, duration.seconds.isFinite ? duration.seconds : 0)
    }

    static func generator(_ video: URL, maxPixelSize: Int, exact: Bool = true) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        return generator
    }

    /// The frame at `time` seconds: another key photo.
    public static func frame(of video: URL, at time: Double, maxPixelSize: Int) async throws -> CGImage {
        let generator = generator(video, maxPixelSize: maxPixelSize)
        return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Evenly spread times over `duration` for `count` frames.
    public static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [0] }
        if count == 1 { return [duration / 2] }
        let step = duration / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * step }
    }

    /// The frames averaged into one picture: moving water turns silky, lights draw lines.
    public static func longExposure(of video: URL, maxPixelSize: Int, frames: Int = longExposureFrames) async throws -> CGImage {
        let times = sampleTimes(duration: try await duration(of: video), count: frames)
        let generator = generator(video, maxPixelSize: maxPixelSize, exact: false)
        var averager: FrameAverager?
        for time in times {
            try Task.checkCancellation()
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            if averager == nil { averager = FrameAverager(width: image.width, height: image.height) }
            guard let averager0 = averager, let pixels = rgba(image, width: averager0.width, height: averager0.height) else { continue }
            averager?.add(pixels)
        }
        guard let averager, averager.count > 0,
            let image = cgImage(rgba: averager.average(), width: averager.width, height: averager.height)
        else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    /// The picture's pixels as RGBA bytes at the given size.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func cgImage(rgba pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Loop and Bounce

    /// The order in which the motion's frames are shown: Loop plays them `repeats` times forward; Bounce forward and
    /// back (the turning frames once, so the motion does not stall), `repeats` times.
    public static func frameOrder(frameCount: Int, effect: LivePhotoEffect.Effect, repeats: Int = 1) -> [Int] {
        guard frameCount > 0 else { return [] }
        let forward = Array(0..<frameCount)
        let cycle: [Int]
        switch effect {
        case .bounce:
            cycle = forward + (frameCount > 2 ? Array(forward.dropFirst().dropLast().reversed()) : [])
        default:
            cycle = forward
        }
        return Array((0..<max(1, repeats)).map { _ in cycle }.joined())
    }

    /// A video of the effect (H.264 MP4, no sound): what the viewer plays for Bounce, and what Export writes for Loop and
    /// Bounce. `edits` (crop, filter, adjustments) are applied to every frame.
    public static func writeVideo(
        of video: URL, effect: LivePhotoEffect.Effect, edits: EditRecipe?, maxPixelSize: Int = 1280, repeats: Int = 1, to target: URL
    ) async throws {
        let duration = try await duration(of: video)
        let count = max(2, Int((duration * Double(videoFrameRate)).rounded()))
        let times = sampleTimes(duration: duration, count: count)
        let generator = generator(video, maxPixelSize: maxPixelSize, exact: false)
        // The frames are read once and kept small; Bounce needs them again backwards.
        var frames: [CGImage] = []
        for time in times {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append(render(image, edits: edits))
            }
        }
        guard let first = frames.first else { throw CocoaError(.fileReadCorruptFile) }
        let order = frameOrder(frameCount: frames.count, effect: effect, repeats: repeats)
        // Encoders want even sizes.
        let width = first.width & ~1
        let height = first.height & ~1
        try? FileManager.default.removeItem(at: target)
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
            ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        let receiver = writer.inputPixelBufferReceiver(
            for: input, pixelBufferAttributes: VideoFrames.attributes(width: width, height: height))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        do {
            for (index, frame) in order.enumerated() {
                try Task.checkCancellation()
                guard let pool = receiver.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                let buffer = try pool.makeMutablePixelBuffer()
                buffer.withUnsafeBuffer { buffer in
                    PhotoEditor.context.render(
                        CIImage(cgImage: frames[frame]), to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
                // Waits while the encoder is busy (what `isReadyForMoreMediaData` was polled for).
                try await receiver.append(
                    CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(index), timescale: videoFrameRate))
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// An animated GIF of the effect that loops for ever (Loop, Bounce; a plain Live Photo plays forward).
    public static func writeGIF(
        of video: URL, effect: LivePhotoEffect.Effect, edits: EditRecipe?, maxPixelSize: Int = 480, to target: URL
    ) async throws {
        let duration = try await duration(of: video)
        let count = max(2, Int((duration * gifFrameRate).rounded()))
        let generator = generator(video, maxPixelSize: maxPixelSize, exact: false)
        var frames: [CGImage] = []
        for time in sampleTimes(duration: duration, count: count) {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append(render(image, edits: edits))
            }
        }
        let order = frameOrder(frameCount: frames.count, effect: effect)
        guard !order.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try? FileManager.default.removeItem(at: target)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.gif.identifier as CFString, order.count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFrameRate]] as CFDictionary
        for index in order { CGImageDestinationAddImage(destination, frames[index], frameProperties) }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A frame with the recipe's look (crop, filter, adjustments); the frame itself without one.
    static func render(_ frame: CGImage, edits: EditRecipe?) -> CGImage {
        guard let edits, !edits.edits.isIdentity || !(edits.raw?.isIdentity ?? true) else { return frame }
        let output = EditRendering.apply(edits, to: CIImage(cgImage: frame))
        return PhotoEditor.context.createCGImage(output, from: output.extent.integral) ?? frame
    }
}
