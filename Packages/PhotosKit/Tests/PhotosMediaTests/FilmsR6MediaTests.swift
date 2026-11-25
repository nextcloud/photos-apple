// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel

/// Round 6 films on the device (SPEC §16.6): the styles' scores, faces lined up through the years, the looks.
@Suite struct FilmScoreSynthTests {
    @Test func aScoreBecomesALoopOfCleanSound() {
        let (left, right) = ScoreSynth.render(FilmScore(mood: .ambient))
        let score = FilmScore(mood: .ambient)
        #expect(left.count == Int((score.length * ScoreSynth.sampleRate).rounded()))
        #expect(left.count == right.count)
        #expect(left.allSatisfy { $0.isFinite } && right.allSatisfy { $0.isFinite })
        let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        #expect(peak > 0.5 && peak <= 0.8)
        // Not silent anywhere for long, and the loop's end runs into its start without a click.
        let rms = sqrt(left.map { $0 * $0 }.reduce(0, +) / Float(left.count))
        #expect(rms > 0.02)
        #expect(abs(left[left.count - 1] - left[0]) < 0.1)
    }

    @Test func everyDeviceMakesTheSameMusic() {
        let first = ScoreSynth.render(FilmScore(mood: .upbeat))
        let second = ScoreSynth.render(FilmScore(mood: .upbeat))
        #expect(first.left == second.left)
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) func theScoreIsWrittenOnceAsAFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scores-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(await ScoreSynth.file(for: .nostalgic, folder: folder))
        let made = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
        let again = await ScoreSynth.file(for: .nostalgic, folder: folder)
        #expect(again == url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date == made)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 2)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - FilmScore(mood: .nostalgic).length) < 0.01)
        // Its beat is what the film is cut to.
        let rhythm = await AudioRhythm.rhythm(of: url)
        if let rhythm {
            #expect(abs(rhythm.tempo - FilmScore.tempo(of: .nostalgic)) < 3 || abs(rhythm.tempo - 2 * FilmScore.tempo(of: .nostalgic)) < 6)
        }
    }
}

@Suite struct FaceTimeLapseTests {
    @Test func recognizesFaceIsChosenAmongSeveral() {
        let boxes = [
            FilmCrop(x: 0.1, y: 0.1, width: 0.3, height: 0.3), FilmCrop(x: 0.6, y: 0.2, width: 0.15, height: 0.15),
        ]
        #expect(FaceTimeLapse.bestFace(boxes, hint: FilmCrop(x: 0.62, y: 0.21, width: 0.14, height: 0.15)) == 1)
        // Without a hint, the largest.
        #expect(FaceTimeLapse.bestFace(boxes, hint: nil) == 0)
        // Recognize's face is not among Vision's: none of the others.
        #expect(FaceTimeLapse.bestFace(boxes, hint: FilmCrop(x: 0.8, y: 0.8, width: 0.1, height: 0.1)) == nil)
        #expect(abs(FaceTimeLapse.overlap(boxes[0], boxes[0]) - 1) < 1e-9)
    }

    @Test func theCoreImageTransformPutsTheEyesWhereTheAlignmentSays() {
        let eyes = ThroughTheYears.Eyes(left: ThroughTheYears.Point(x: 200, y: 300), right: ThroughTheYears.Point(x: 320, y: 260))
        let transform = ThroughTheYears.alignment(eyes, width: 800, height: 600)
        let ci = FaceTimeLapse.coreImageTransform(transform, imageHeight: 1000, frameHeight: 600)
        for eye in [eyes.left, eyes.right] {
            // Bottom-left coordinates on both sides.
            let mapped = CGPoint(x: eye.x, y: 1000 - eye.y).applying(ci)
            let expected = transform.apply(eye)
            #expect(abs(mapped.x - expected.x) < 1e-6)
            #expect(abs((600 - mapped.y) - expected.y) < 1e-6)
        }
    }

    /// A picture with two red "eyes" at known places.
    func eyesPicture(width: Int, height: Int, left: CGPoint, right: CGPoint) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        for eye in [left, right] {
            // CG counts from the bottom.
            context.fillEllipse(in: CGRect(x: eye.x - 12, y: CGFloat(height) - eye.y - 12, width: 24, height: 24))
        }
        return context.makeImage()!
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (data[0], data[1], data[2])
    }

    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) func aFaceIsDrawnWithItsEyesOnTheEyeLine() throws {
        let left = CGPoint(x: 300, y: 420)
        let right = CGPoint(x: 420, y: 470)
        let picture = eyesPicture(width: 900, height: 700, left: left, right: right)
        let eyes = ThroughTheYears.Eyes(
            left: ThroughTheYears.Point(x: left.x, y: left.y), right: ThroughTheYears.Point(x: right.x, y: right.y))
        let size = CGSize(width: 640, height: 360)
        let frame = try #require(FaceTimeLapse.frame(picture, eyes: eyes, size: size))
        #expect(frame.width == 640 && frame.height == 360)
        let y = Int(ThroughTheYears.eyeLine.y * 360)
        let half = ThroughTheYears.eyeDistance * 360 / 2
        for x in [Int(320 - half), Int(320 + half)] {
            let colour = pixel(frame, x: x, y: y)
            #expect(colour.r > 200 && colour.g < 60, "eye at \(x),\(y): \(colour)")
        }
        // Between the eyes: the background.
        #expect(pixel(frame, x: 320, y: y).g > 100)
    }

    /// Real faces, when a folder of portraits is given (`TEST_RUNNER_PHOTOS_FACE_SAMPLES`): their eyes are found with
    /// Vision and lined up; the frames go to `TEST_RUNNER_PHOTOS_FACE_OUTPUT` for a look.
    @Test(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noVision)) func realFacesAreLinedUp() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PHOTOS_FACE_SAMPLES"] else { return }
        let output = ProcessInfo.processInfo.environment["PHOTOS_FACE_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        var found = 0
        for (index, file) in files.enumerated() {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
            else { continue }
            guard let eyes = await FaceTimeLapse.eyes(in: image, near: nil) else { continue }
            found += 1
            #expect(eyes.distance > 4)
            #expect(abs(eyes.angle) < 0.6)
            if let output, let frame = FaceTimeLapse.frame(image, eyes: eyes, size: CGSize(width: 720, height: 720)) {
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let url = output.appending(path: String(format: "face-%03d.png", index))
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, frame, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
        }
        #expect(found > 0)
    }
}

@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU)) struct FilmLookFilterTests {
    func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    func colour(_ image: CGImage) -> (Double, Double, Double) {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    @Test func coreImageGradesAsTheLookSays() throws {
        for style in [FilmStyle.blackAndWhite, .superEight, .upbeat, .calm] {
            let picture = solid(0.7, 0.4, 0.2)
            // The colour as stored (CGColor's components are not sRGB's).
            let input = colour(picture)
            let graded = try #require(FilmLookFilter.graded(picture, look: style.look))
            let got = colour(graded)
            let want = style.look.graded(input)
            #expect(abs(got.0 - want.0) < 0.03 && abs(got.1 - want.1) < 0.03 && abs(got.2 - want.2) < 0.03, "\(style): \(got) vs \(want)")
        }
        #expect(FilmLookFilter.graded(solid(0.5, 0.5, 0.5), look: .none) == nil)
    }

    @Test func theHomeMovieFrameKeepsItsSizeWithGrainAndVignette() throws {
        let size = CGSize(width: 320, height: 180)
        let frame = FilmLookFilter.frame(
            CIImage(cgImage: solid(0.6, 0.6, 0.6)).transformed(by: .init(scaleX: 40, y: 22.5)), look: FilmStyle.superEight.look, time: 1.2,
            size: size)
        #expect(frame.extent == CGRect(origin: .zero, size: size))
        let rendered = try #require(CIContext().createCGImage(frame, from: frame.extent))
        // Corners darker than the middle.
        let corner = try #require(rendered.cropping(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let middle = try #require(rendered.cropping(to: CGRect(x: 156, y: 86, width: 8, height: 8)))
        #expect(colour(corner).0 < colour(middle).0)
        #expect(FilmLookFilter.grainTile(FilmStyle.superEight.look) != nil)
        #expect(FilmLookFilter.grainTile(FilmStyle.upbeat.look) == nil)
    }

    @Test(.timeLimit(.minutes(2))) func aFilmIsExportedInItsStyle() async throws {
        let shots = (0..<2).map { FilmShot(fileId: FileID($0 + 1), date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 60)) }
        let plan = FilmPlan(shots: shots, rhythm: FilmStyle.blackAndWhite.steadyRhythm, style: .blackAndWhite)
        var material = FilmMaterial()
        material.stills = [0: solid(0.9, 0.1, 0.1), 1: solid(0.1, 0.1, 0.9)]
        let exporter = FilmExporter(
            plan: plan, material: material, size: CGSize(width: 160, height: 90), codec: .h264, music: nil, fileName: "Style test")
        let url = try await exporter.export { _ in }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: plan.segments[1].start + 1, preferredTimescale: 600))
        let middle = try #require(image.cropping(to: CGRect(x: image.width / 2 - 4, y: image.height / 2 - 4, width: 8, height: 8)))
        let got = colour(middle)
        // A red picture in black and white: grey.
        #expect(abs(got.0 - got.1) < 0.06 && abs(got.1 - got.2) < 0.06, "\(got)")
    }
}
