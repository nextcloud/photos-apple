// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import Vision

/// Finds the photos of a "Then and now" spot that show the same view (SPEC §15.6): Vision feature prints of small
/// previews, compared on the device. Nothing is sent anywhere; previews come from the cache or the user's server.
public enum ViewMatcher {
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "then-and-now")

    /// The spot with each year leading with the photo most like the anchor's view. `image` loads a small preview (nil
    /// when it cannot); at most `concurrency` load at once. Without usable feature prints the spot stays as it is.
    public static func align(
        _ spot: ThenAndNowSpot, anchorYear: Int? = nil, concurrency: Int = 4,
        image: @escaping @Sendable (FileID) async -> CGImage?
    ) async -> ThenAndNowSpot {
        // Fewer photos per year when there are many years (a garden photographed every year for twenty years).
        let perYear = spot.years.count > 8 ? 6 : ThenAndNow.comparedPerYear
        let anchorIndex = spot.years.firstIndex { $0.year == (anchorYear ?? spot.years.last?.year) } ?? spot.years.count - 1
        var ids: [FileID] = []
        for (index, year) in spot.years.enumerated() {
            ids += index == anchorIndex ? Array(year.items.prefix(4)) : ThenAndNow.compared(year, limit: perYear)
        }
        let prints = await featurePrints(ids, concurrency: concurrency, image: image)
        guard !Task.isCancelled, prints.count >= 2 else { return spot }
        logger.debug("compared \(prints.count) of \(ids.count) photos of \(spot.id, privacy: .public)")
        return ThenAndNow.alignedYears(spot, anchorYear: anchorYear) { a, b in
            guard let first = prints[a], let second = prints[b] else { return nil }
            return try? first.distance(to: second)
        }
    }

    static func featurePrints(
        _ ids: [FileID], concurrency: Int, image: @escaping @Sendable (FileID) async -> CGImage?
    ) async -> [FileID: FeaturePrintObservation] {
        await withTaskGroup(of: (FileID, FeaturePrintObservation?).self) { group in
            var result: [FileID: FeaturePrintObservation] = [:]
            var pending = ids[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    guard !Task.isCancelled, let picture = await image(id) else { return (id, nil) }
                    return (id, try? await GenerateImageFeaturePrintRequest().perform(on: picture))
                }
            }
            for _ in 0..<max(1, concurrency) { addNext() }
            while let (id, print) = await group.next() {
                if let print { result[id] = print }
                addNext()
            }
            return result
        }
    }
}

/// Writes a "Then and now" time-lapse as a short video (H.264 in an MP4): the photos aspect-filled, cross-faded and
/// slowly zoomed as `TimeLapsePlan` says, each with its year in the corner.
public enum TimeLapseVideo {
    public struct Frame: Sendable {
        public var image: CGImage
        public var caption: String

        public init(image: CGImage, caption: String) {
            self.image = image
            self.caption = caption
        }
    }

    public enum Failure: Error {
        case noFrames
        case cannotWrite
    }

    /// The video's size for some photos: 1080 × 1920 when most are portrait, else 1920 × 1080.
    public static func size(for images: [CGImage]) -> CGSize {
        let portrait = images.filter { $0.height > $0.width }.count
        return portrait * 2 > images.count ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
    }

    /// Writes the video to `url` (replaced). `progress` is told the share of frames written.
    public static func write(
        _ frames: [Frame], to url: URL, plan: TimeLapsePlan? = nil, size: CGSize? = nil, framesPerSecond: Int = 30,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !frames.isEmpty else { throw Failure.noFrames }
        let plan = plan ?? TimeLapsePlan(count: frames.count)
        let size = size ?? Self.size(for: frames.map(\.image))
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: Int(size.width), height: Int(size.height)))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        // Scaled to the video once (each frame then only moves and slightly grows them), not once per frame.
        let frames = frames.map { Frame(image: prepared($0.image, for: size) ?? $0.image, caption: $0.caption) }
        let times = plan.frameTimes(framesPerSecond: framesPerSecond)
        do {
            for (index, time) in times.enumerated() {
                try Task.checkCancellation()
                let buffer: CVMutablePixelBuffer
                if let pool = receiver.pixelBufferPool {
                    buffer = try pool.makeMutablePixelBuffer()
                } else {
                    buffer = try CVMutablePixelBuffer(attributes)
                }
                let moment = plan.moment(at: time)
                buffer.withUnsafeBuffer { pixels in render(moment, frames: frames, into: pixels, size: size) }
                let presentation = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
                try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: presentation)
                progress(Double(index + 1) / Double(times.count))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.cannotWrite }
    }

    static func render(_ moment: TimeLapsePlan.Moment, frames: [Frame], into buffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        draw(moment, frames: frames, in: context, size: size)
    }

    /// One moment of the time-lapse: black, the photo, the next one faded in over it, the caption of the more visible one.
    static func draw(_ moment: TimeLapsePlan.Moment, frames: [Frame], in context: CGContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .medium
        if frames.indices.contains(moment.from) {
            context.setAlpha(1)
            context.draw(frames[moment.from].image, in: filled(frames[moment.from].image, in: bounds, scale: moment.fromScale))
        }
        if moment.mix > 0, frames.indices.contains(moment.to) {
            context.setAlpha(moment.mix)
            context.draw(frames[moment.to].image, in: filled(frames[moment.to].image, in: bounds, scale: moment.toScale))
        }
        context.setAlpha(1)
        if frames.indices.contains(moment.captioned) { caption(frames[moment.captioned].caption, in: context, size: size) }
    }

    /// An image scaled to aspect-fill a video of `size` (nil when it cannot be drawn).
    static func prepared(_ image: CGImage, for size: CGSize) -> CGImage? {
        let rect = filled(image, in: CGRect(origin: .zero, size: size), scale: 1)
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The rectangle that aspect-fills `bounds` with an image, grown by `scale` around the middle.
    static func filled(_ image: CGImage, in bounds: CGRect, scale: Double) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let fill = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) * CGFloat(scale)
        let width = CGFloat(image.width) * fill
        let height = CGFloat(image.height) * fill
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// The year, large and white with a soft shadow, in the lower left corner.
    static func caption(_ text: String, in context: CGContext, size: CGSize) {
        let fontSize = min(size.width, size.height) * 0.09
        let font =
            CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let margin = min(size.width, size.height) * 0.06
        context.saveGState()
        context.setShadow(offset: .zero, blur: fontSize * 0.35, color: CGColor(gray: 0, alpha: 0.7))
        context.textPosition = CGPoint(x: margin, y: margin)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
