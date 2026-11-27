// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreImage
import Foundation
import PhotosDomain
import Testing

@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// Measuring what the best shot is chosen by (SPEC §21.4).
@Suite struct BestShotMeasureTests {
    /// A detailed scene: many small shapes on a gradient, 1024 × 768.
    static func scene(seed: Int = 3) -> CGImage {
        let width = 1024
        let height = 768
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var state = UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15
        func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(state >> 11) / CGFloat(1 << 53)
        }
        context.setFillColor(CGColor(red: 0.45, green: 0.5, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<400 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 1))
            let rect = CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: 4 + next() * 40, height: 4 + next() * 40)
            if next() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }

    /// `image` through a Core Image filter, same size.
    static func filtered(_ image: CGImage, _ name: String, _ parameters: [String: Any]) -> CGImage {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: name, parameters: [kCIInputImageKey: input].merging(parameters) { first, _ in first })!
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(filter.outputImage!.cropped(to: input.extent), from: input.extent)!
    }

    @Test func blurLowersSharpness() throws {
        let sharp = try #require(GreyPicture(Self.scene(), longEdge: BestShotAnalysis.longEdge))
        let soft = try #require(
            GreyPicture(Self.filtered(Self.scene(), "CIGaussianBlur", [kCIInputRadiusKey: 3.0]), longEdge: BestShotAnalysis.longEdge))
        #expect(sharp.width == 768 && sharp.height == 576)
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let sharpness = sharp.sharpness(of: sharp.laplacian(), in: whole)
        let softness = soft.sharpness(of: soft.laplacian(), in: whole)
        #expect(sharpness > softness + 1, "\(sharpness) vs \(softness)")
        // A flat picture has no detail at all.
        let flat = GreyPicture(width: 64, height: 64, pixels: [UInt8](repeating: 128, count: 64 * 64))
        #expect(flat.sharpness(of: flat.laplacian(), in: whole) == 0)
    }

    @Test func regionsAreMeasuredWhereVisionPutsThem() {
        // Detail only in the top half (rows 0…31 of the buffer are the top); Vision's boxes start at the bottom.
        var pixels = [UInt8](repeating: 100, count: 64 * 64)
        for y in 0..<32 { for x in 0..<64 where (x + y) % 2 == 0 { pixels[y * 64 + x] = 200 } }
        let picture = GreyPicture(width: 64, height: 64, pixels: pixels)
        let laplacian = picture.laplacian()
        let top = picture.sharpness(of: laplacian, in: CGRect(x: 0, y: 0.55, width: 1, height: 0.45))
        let bottom = picture.sharpness(of: laplacian, in: CGRect(x: 0, y: 0, width: 1, height: 0.45))
        #expect(top > 10)
        #expect(bottom == 0)
    }

    @Test func exposureCountsClippingAndTone() {
        var good = [Int](repeating: 0, count: 256)
        for value in 20...230 { good[value] = 10 }
        #expect(GreyPicture.exposure(histogram: good).score == 1)
        var blown = good
        blown[255] = 1500
        let overexposed = GreyPicture.exposure(histogram: blown)
        #expect(overexposed.highlights > 0.3)
        #expect(overexposed.score < 0.3)
        var dark = [Int](repeating: 0, count: 256)
        for value in 0...40 { dark[value] = 10 }
        #expect(GreyPicture.exposure(histogram: dark).score < 0.7)
    }

    @Test func eyeOpennessFromTheOutline() {
        func eye(height: CGFloat) -> [CGPoint] {
            [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: height / 2), CGPoint(x: 20, y: 0), CGPoint(x: 10, y: -height / 2)]
        }
        let open = EyeOpenness.openness(left: EyeOpenness.ratio(eye(height: 6)), right: EyeOpenness.ratio(eye(height: 6)))
        let closed = EyeOpenness.openness(left: EyeOpenness.ratio(eye(height: 1.5)), right: EyeOpenness.ratio(eye(height: 1.5)))
        #expect(open == 1)
        #expect((closed ?? 1) < BestShot.Face.closedEyes)
        // A wink is not a blink.
        #expect(EyeOpenness.openness(left: EyeOpenness.ratio(eye(height: 1)), right: EyeOpenness.ratio(eye(height: 6))) == 1)
        #expect(EyeOpenness.openness(left: nil, right: nil) == nil)
        #expect(EyeOpenness.ratio([CGPoint(x: 0, y: 0)]) == nil)
    }
}

/// The analysis with real Vision, end to end: a burst whose frames are shaken or blown out (SPEC §21.4).
@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noVision)) struct BestShotAnalysisTests {
    @Test func theSteadyFrameOfAShakenBurstIsChosen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photos-bestshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AccountDatabase.temporary()
        let items = (1...5).map { MediaItem(fileId: FileID($0), path: "/Photos/\($0).jpg", mimeType: "image/jpeg", etag: "e\($0)") }
        try LibraryStore(database: database).upsert(items)
        let cache = PreviewCache(directory: directory)
        let scene = BestShotMeasureTests.scene()
        // 1, 2, 4: camera shake; 3: steady; 5: steady but blown out. Only 1–4 are cached; 5 is loaded on demand.
        cache.store(BestShotMeasureTests.filtered(scene, "CIMotionBlur", [kCIInputRadiusKey: 8.0]), fileId: 1, etag: "e1", bucket: 1024)
        cache.store(BestShotMeasureTests.filtered(scene, "CIMotionBlur", [kCIInputRadiusKey: 5.0]), fileId: 2, etag: "e2", bucket: 1024)
        cache.store(scene, fileId: 3, etag: "e3", bucket: 1024)
        cache.store(BestShotMeasureTests.filtered(scene, "CIMotionBlur", [kCIInputRadiusKey: 12.0]), fileId: 4, etag: "e4", bucket: 1024)
        let blownOut = BestShotMeasureTests.filtered(scene, "CIExposureAdjust", [kCIInputEVKey: 2.5])

        let analyzer = BestShotAnalyzer(database: database, cache: cache)
        // Only what is cached, as in the background.
        let cached = await analyzer.signals(of: [1, 2, 3, 4, 5])
        #expect(cached.keys.sorted() == [1, 2, 3, 4])
        let all = await analyzer.signals(of: [1, 2, 3, 4, 5]) { id in id == 5 ? blownOut : nil }
        #expect(all.count == 5)
        let five = try #require(all[5])
        #expect(five.highlights > 0.1)
        #expect(five.exposure < (all[3]?.exposure ?? 0))
        let choice = try #require(BestShot.choose((1...5).map { BestShot.Candidate(id: FileID($0), signals: all[FileID($0)]) }))
        #expect(choice.best == 3)
        // Frame 5 is as sharp (clipping even adds edges) but blown out: that is what sets the steady frame apart.
        #expect(choice.reasons.contains(.wellExposed))
        // The more shaken, the further down; brightness does not make a frame sharper or softer.
        #expect((all[2]?.sharpness ?? 0) > (all[4]?.sharpness ?? 0))
        #expect(abs((all[5]?.sharpness ?? 0) - (all[3]?.sharpness ?? 0)) < 0.5)
        let ranking = choice.ranking(of: [1, 2, 3, 4, 5])
        #expect(ranking.first == 3)
        #expect(ranking.firstIndex(of: 2)! < ranking.firstIndex(of: 4)!)
        // Stored: asked again, nothing is analysed.
        #expect(try BestShotStore(database: database).missing([1, 2, 3, 4, 5]).isEmpty)
    }
}

/// The evaluation of SPEC §21.4, repeatable: `BESTSHOT_EVAL_DIR=<dir>` (through xcodebuild: `TEST_RUNNER_BESTSHOT_EVAL_DIR`)
/// names a folder with one subfolder of JPEGs per group (a burst, a series); each picture is decoded as the 1024 px
/// preview would be, analysed and timed, and `report.json` with every frame's signals, score and the choice is written
/// into the folder. Off without the variable.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BESTSHOT_EVAL_DIR"] != nil)) struct BestShotEvaluation {
    struct Frame: Codable {
        var name: String
        var signals: BestShot.Signals?
        var score: Float?
        var milliseconds: Double
    }

    struct Group: Codable {
        var name: String
        var frames: [Frame]
        var best: String?
        var reasons: [BestShot.Reason]
    }

    @Test func evaluate() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BESTSHOT_EVAL_DIR"]))
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var groups: [Group] = []
        for folder in folders {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var frames: [Frame] = []
            for file in files {
                guard let image = ImageDecoding.decode(url: file, maxPixelSize: BestShotAnalysis.bucket) else { continue }
                let clock = ContinuousClock.now
                let signals = try? await BestShotAnalysis.analyze(image)
                let elapsed = ContinuousClock.now - clock
                frames.append(
                    Frame(
                        name: file.deletingPathExtension().lastPathComponent, signals: signals, score: nil,
                        milliseconds: Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000))
            }
            let candidates = frames.enumerated().map { BestShot.Candidate(id: FileID($0.offset), signals: $0.element.signals) }
            let choice = BestShot.choose(candidates)
            for index in frames.indices { frames[index].score = choice?.scores[FileID(index)] }
            groups.append(
                Group(
                    name: folder.lastPathComponent, frames: frames, best: choice.map { frames[Int($0.best)].name },
                    reasons: choice?.reasons ?? []))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(groups).write(to: root.appending(path: "report.json"))
    }
}
