// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosStore
import Vision

/// Measures what the best shot of a burst or series is chosen by (SPEC §21.4, `BestShot`), on this device, with Apple's
/// frameworks only (no model is bundled):
///
/// - *Sharpness*: variance of the Laplacian of the grey picture (Accelerate), of the whole picture and of its subject —
///   the largest face, else the most salient object (Vision's attention saliency). Motion blur and missed focus lower it.
/// - *Exposure*: the share of blown-out and crushed pixels and where the mid-tones sit (a histogram).
/// - *Faces*: Vision's face rectangles (yaw and pitch: looking at the camera), landmarks (how open the eyes are) and face
///   capture quality; Core Image's face detector for smiles and closed eyes, which Vision does not report.
/// - *Aesthetics*: Vision's `CalculateImageAestheticsScoresRequest` (overall score, and whether it is a utility picture
///   such as a document or a screenshot).
///
/// Always measured on the 1024 px preview scaled to `longEdge`, so the photos of one group are measured alike.
public enum BestShotAnalysis {
    /// The preview bucket analysed: sharpness needs more pixels than the 256 px grid tiles have.
    public static let bucket = 1024
    /// Long edge of the picture measured, in pixels.
    public static let longEdge = 768

    /// Analyses one picture.
    public static func analyze(_ image: CGImage) async throws -> BestShot.Signals {
        #if targetEnvironment(simulator)
            // Vision's models fail on the simulator's GPU and return nonsense on its CPU (as for "Show Similar").
            throw SimulatorUnsupported()
        #else
            guard let picture = GreyPicture(image, longEdge: longEdge) else { throw Undecodable() }
            let laplacian = picture.laplacian()
            let exposure = picture.exposure()
            let faces = await Self.faces(in: image)
            var subject: Float?
            if let largest = faces.first {
                let box = CGRect(
                    x: CGFloat(largest.x), y: CGFloat(largest.y), width: CGFloat(largest.width), height: CGFloat(largest.height))
                subject = picture.sharpness(of: laplacian, in: box)
            } else if let salient = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image).salientObjects
                .max(by: { $0.confidence < $1.confidence })
            {
                subject = picture.sharpness(of: laplacian, in: salient.boundingBox.cgRect)
            }
            let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image)
            return BestShot.Signals(
                sharpness: picture.sharpness(of: laplacian, in: CGRect(x: 0, y: 0, width: 1, height: 1)), subjectSharpness: subject,
                exposure: exposure.score, highlights: exposure.highlights, shadows: exposure.shadows, faces: faces,
                aesthetics: aesthetics?.overallScore, isUtility: aesthetics?.isUtility ?? false)
        #endif
    }

    struct SimulatorUnsupported: Error {}
    struct Undecodable: Error {}

    /// The faces of a picture: Vision for where they are, how they are turned, their landmarks and quality; Core Image for
    /// smiles and blinks. Largest first, at most 12.
    static func faces(in image: CGImage) async -> [BestShot.Face] {
        guard var found = try? await DetectFaceRectanglesRequest().perform(on: image), !found.isEmpty else { return [] }
        found.sort { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        found = Array(found.prefix(12))
        var landmarksRequest = DetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = found
        let withLandmarks = (try? await landmarksRequest.perform(on: image)) ?? []
        var qualityRequest = DetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = found
        let withQuality = (try? await qualityRequest.perform(on: image)) ?? []
        let expressions = Self.expressions(in: image)
        let size = CGSize(width: image.width, height: image.height)
        return found.map { observation in
            let box = observation.boundingBox.cgRect
            var face = BestShot.Face(
                x: Float(box.minX), y: Float(box.minY), width: Float(box.width), height: Float(box.height),
                yaw: Float(observation.yaw.converted(to: .degrees).value), pitch: Float(observation.pitch.converted(to: .degrees).value))
            if let landmarks = Self.match(box, in: withLandmarks)?.landmarks {
                let left = EyeOpenness.ratio(landmarks.leftEye.pointsInImageCoordinates(size))
                let right = EyeOpenness.ratio(landmarks.rightEye.pointsInImageCoordinates(size))
                face.eyesOpen = EyeOpenness.openness(left: left, right: right)
            }
            face.quality = Self.match(box, in: withQuality)?.captureQuality?.score
            if let expression = expressions.max(by: { overlap($0.box, box) < overlap($1.box, box) }), overlap(expression.box, box) > 0.3 {
                face.isSmiling = expression.isSmiling
                if expression.eyesClosed {
                    // Core Image saw a blink: trust it over the landmarks, which follow the eyelids less well.
                    face.eyesOpen = min(face.eyesOpen ?? 0.1, 0.2)
                } else if face.eyesOpen == nil {
                    face.eyesOpen = 0.9
                }
            }
            return face
        }
    }

    /// The observation whose box overlaps `box` most (requests given input faces return new observations).
    static func match(_ box: CGRect, in observations: [FaceObservation]) -> FaceObservation? {
        observations.max { overlap($0.boundingBox.cgRect, box) < overlap($1.boundingBox.cgRect, box) }
            .flatMap { overlap($0.boundingBox.cgRect, box) > 0.3 ? $0 : nil }
    }

    /// Intersection over union of two rectangles.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let common = intersection.width * intersection.height
        return common / (a.width * a.height + b.width * b.height - common)
    }

    /// What Core Image's face detector says about smiles and blinks; boxes normalised like Vision's (origin bottom left).
    static func expressions(in image: CGImage) -> [(box: CGRect, isSmiling: Bool, eyesClosed: Bool)] {
        guard
            let detector = CIDetector(
                ofType: CIDetectorTypeFace, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh, CIDetectorMinFeatureSize: 0.04])
        else { return [] }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let features = detector.features(in: CIImage(cgImage: image), options: [CIDetectorSmile: true, CIDetectorEyeBlink: true])
        return features.compactMap { feature in
            guard let face = feature as? CIFaceFeature else { return nil }
            let box = CGRect(
                x: face.bounds.minX / width, y: face.bounds.minY / height, width: face.bounds.width / width,
                height: face.bounds.height / height)
            return (box, face.hasSmile, face.leftEyeClosed && face.rightEyeClosed)
        }
    }
}

/// How open a pair of eyes is, from Vision's eye landmarks: the height of each eye outline over its width (the "eye
/// aspect ratio"), about 0.3 for an open eye and under 0.15 for a closed one.
enum EyeOpenness {
    static let closedRatio: Float = 0.12
    static let openRatio: Float = 0.26

    /// Height over width of the points of one eye outline; nil without enough points.
    static func ratio(_ points: [CGPoint]) -> Float? {
        guard points.count >= 4, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX - minX > 0
        else { return nil }
        return Float((maxY - minY) / (maxX - minX))
    }

    /// 0 (closed) … 1 (open) from both eyes; the more open eye counts (a wink or a half-hidden eye is not a blink).
    static func openness(left: Float?, right: Float?) -> Float? {
        guard let ratio = [left, right].compactMap({ $0 }).max() else { return nil }
        return max(0, min(1, (ratio - closedRatio) / (openRatio - closedRatio)))
    }
}

/// A picture in grey, scaled to measure detail and exposure (`BestShotAnalysis`).
struct GreyPicture {
    let width: Int
    let height: Int
    /// Row 0 is the top of the picture.
    let pixels: [UInt8]
    /// The same as floats (0 … 255), for the vector maths.
    let tones: [Float]

    /// The picture scaled so its long edge is at most `longEdge`; nil when it cannot be drawn.
    init?(_ image: CGImage, longEdge: Int) {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        pixels = buffer
        tones = vDSP.integerToFloatingPoint(buffer, floatingPointType: Float.self)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
        tones = vDSP.integerToFloatingPoint(pixels, floatingPointType: Float.self)
    }

    /// The Laplacian (4-neighbour) of the picture, 0 at the border.
    func laplacian() -> [Float] {
        var floats = tones
        var output = [Float](repeating: 0, count: pixels.count)
        guard width >= 3, height >= 3 else { return output }
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        floats.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                var input = vImage_Buffer(
                    data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size)
                var result = vImage_Buffer(
                    data: target.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.size)
                _ = vImageConvolve_PlanarF(&input, &result, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageTruncateKernel))
            }
        }
        // The border has half a kernel: left out.
        for x in 0..<width {
            output[x] = 0
            output[(height - 1) * width + x] = 0
        }
        for y in 0..<height {
            output[y * width] = 0
            output[y * width + width - 1] = 0
        }
        return output
    }

    /// log2(1 + 1024 × variance of `laplacian` / variance of the tones) inside `rect` (normalised, origin bottom left, as
    /// Vision gives boxes). Higher is sharper.
    func sharpness(of laplacian: [Float], in rect: CGRect) -> Float {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull else { return 0 }
        let x0 = max(1, Int(clipped.minX * CGFloat(width)))
        let x1 = min(width - 1, Int((clipped.maxX * CGFloat(width)).rounded(.up)))
        // Rows count from the top.
        let y0 = max(1, Int((1 - clipped.maxY) * CGFloat(height)))
        let y1 = min(height - 1, Int(((1 - clipped.minY) * CGFloat(height)).rounded(.up)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return 0 }
        var sum: Float = 0
        var squares: Float = 0
        let count = x1 - x0
        laplacian.withUnsafeBufferPointer { values in
            for y in y0..<y1 {
                let row = values.baseAddress! + y * width + x0
                var rowSum: Float = 0
                var rowSquares: Float = 0
                vDSP_sve(row, 1, &rowSum, vDSP_Length(count))
                vDSP_svesq(row, 1, &rowSquares, vDSP_Length(count))
                sum += rowSum
                squares += rowSquares
            }
        }
        let n = Float(count * (y1 - y0))
        let mean = sum / n
        let variance = max(0, squares / n - mean * mean)
        // The tones' own spread in the region: dividing by it makes the measure independent of brightness and contrast
        // (a frame that came out darker is not less sharp, a brighter one not sharper).
        var toneSum: Float = 0
        var toneSquares: Float = 0
        tones.withUnsafeBufferPointer { values in
            for y in y0..<y1 {
                let row = values.baseAddress! + y * width + x0
                var rowSum: Float = 0
                var rowSquares: Float = 0
                vDSP_sve(row, 1, &rowSum, vDSP_Length(count))
                vDSP_svesq(row, 1, &rowSquares, vDSP_Length(count))
                toneSum += rowSum
                toneSquares += rowSquares
            }
        }
        let toneMean = toneSum / n
        let toneVariance = toneSquares / n - toneMean * toneMean
        guard toneVariance > 1 else { return 0 }
        return log2(1 + Self.detailScale * variance / toneVariance)
    }

    /// Scales the ratio of Laplacian to tone variance (a few hundredths in a sharp photo) into a useful log2 range.
    static let detailScale: Float = 1024

    /// Clipping and where the tones sit.
    func exposure() -> (score: Float, highlights: Float, shadows: Float) {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        return Self.exposure(histogram: histogram)
    }

    /// 1: nothing blown out or crushed and the mean tone within reach of the middle; less for every share of clipped
    /// pixels beyond a little (a sun or a black jacket is fine) and for a picture far too dark or bright.
    static func exposure(histogram: [Int]) -> (score: Float, highlights: Float, shadows: Float) {
        let total = Float(max(histogram.reduce(0, +), 1))
        let highlights = Float(histogram[250...].reduce(0, +)) / total
        let shadows = Float(histogram[...5].reduce(0, +)) / total
        var weighted: Float = 0
        for (value, count) in histogram.enumerated() { weighted += Float(value * count) }
        let mean = weighted / total / 255
        var score: Float = 1
        score -= 3 * max(0, highlights - 0.02)
        score -= 3 * max(0, shadows - 0.03)
        score -= 2.5 * max(0, abs(mean - 0.46) - 0.15)
        return (max(0, min(1, score)), highlights, shadows)
    }
}

/// Analyses photos for the best shot and keeps what it found (`BestShotStore`).
public struct BestShotAnalyzer: Sendable {
    let store: BestShotStore
    let cache: PreviewCache
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "bestshot")

    public init(database: AccountDatabase, cache: PreviewCache) {
        store = BestShotStore(database: database)
        self.cache = cache
    }

    /// The signals of `fileIds`: stored ones, and the missing ones analysed now from the cached 1024 px preview or, when
    /// it is not cached, from `load` (which may fetch it; nil: only what is cached). Photos that cannot be analysed now
    /// are left out.
    public func signals(
        of fileIds: [FileID], load: (@Sendable (FileID) async -> CGImage?)? = nil, shouldContinue: @Sendable () -> Bool = { true }
    ) async -> [FileID: BestShot.Signals] {
        let missing = (try? store.missing(fileIds)) ?? []
        if !missing.isEmpty { await analyse(missing, load: load, shouldContinue: shouldContinue) }
        return (try? store.signals(of: fileIds)) ?? [:]
    }

    /// Analyses `candidates`, storing what each gave (a failure too, so it is not tried again until the file changes).
    /// Returns how many were analysed.
    @discardableResult
    func analyse(
        _ candidates: [BestShotStore.Candidate], load: (@Sendable (FileID) async -> CGImage?)?, shouldContinue: @Sendable () -> Bool
    ) async -> Int {
        var done = 0
        for candidate in candidates {
            guard shouldContinue(), !Task.isCancelled else { break }
            var image: CGImage?
            if let url = cache.cachedPreviewURL(fileId: candidate.fileId, etag: candidate.etag, buckets: [BestShotAnalysis.bucket]) {
                image = ImageDecoding.decode(url: url, maxPixelSize: BestShotAnalysis.longEdge)
            } else if let load {
                image = await load(candidate.fileId)
            }
            // Not on this device and not loadable now: asked again next time.
            guard let image else { continue }
            do {
                let signals = try await BestShotAnalysis.analyze(image)
                try store.save([(candidate, signals)])
                done += 1
            } catch is BestShotAnalysis.SimulatorUnsupported {
                break
            } catch {
                logger.error("analysing \(candidate.fileId) failed: \(error.localizedDescription, privacy: .public)")
                try? store.save([(candidate, nil)])
            }
        }
        return done
    }

    /// In the background: analyses the photos of the series of similar shots ("Show Similar" found them on this device)
    /// that are not analysed yet, from cached previews only, newest series first, until `shouldContinue` says stop.
    /// Returns how many were analysed.
    @discardableResult
    public func run(shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws -> Int {
        let groups = try await SimilarityStore(database: store.database).similarShots()
        var analysed = 0
        for group in groups {
            guard shouldContinue(), !Task.isCancelled else { break }
            let missing = try store.missing(group.ids)
            guard !missing.isEmpty else { continue }
            analysed += await analyse(missing, load: nil, shouldContinue: shouldContinue)
            await Task.yield()
        }
        if analysed > 0 { logger.info("analysed \(analysed) photos for the best shot") }
        return analysed
    }
}
