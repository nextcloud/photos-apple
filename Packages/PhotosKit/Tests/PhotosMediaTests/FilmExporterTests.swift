// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel

/// Memory film export and the music's beat on the device (SPEC §15.1), with generated pictures and sound.
@Suite(.serialized) struct FilmExporterTests {
    let size = CGSize(width: 320, height: 180)

    func picture(width: Int, height: Int, red: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 4, height: height / 4))
        return context.makeImage()!
    }

    /// A WAV file of clicks at `tempo` (44.1 kHz mono).
    func clickTrack(tempo: Double, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "clicks-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var random = SplitMix(state: 3)
        for index in 0..<Int(frames) { samples[index] = 0.02 * Float(sin(Double(index) * 2 * .pi * 220 / 44_100)) }
        var beat = 0.2
        while beat < seconds {
            let start = Int(beat * 44_100)
            for step in 0..<1_300 where start + step < Int(frames) {
                samples[start + step] += 0.7 * Float(exp(-Double(step) / 350)) * (Float(random.next() % 2000) / 1000 - 1)
            }
            beat += 60 / tempo
        }
        try file.write(from: buffer)
        return url
    }

    func plan(_ count: Int, kinds: [FilmShot.Kind] = []) -> FilmPlan {
        let shots = (0..<count).map { index in
            FilmShot(
                fileId: FileID(index + 1), kind: kinds.count > index ? kinds[index] : .photo, aspectRatio: index == 1 ? 3 / 4 : 4 / 3,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60))
        }
        return FilmPlan(shots: shots)
    }

    func material(_ count: Int) -> FilmMaterial {
        var material = FilmMaterial()
        for index in 0..<count {
            material.stills[index] = index == 1 ? picture(width: 90, height: 120, red: 0.9) : picture(width: 160, height: 120, red: 0.2)
        }
        material.focus[0] = FilmCrop(x: 0.6, y: 0.2, width: 0.2, height: 0.2)
        material.overlays[0] = picture(width: Int(size.width), height: Int(size.height), red: 0.5)
        return material
    }

    func tracks(_ url: URL) async throws -> (duration: Double, video: [AVAssetTrack], audio: [AVAssetTrack]) {
        let asset = AVURLAsset(url: url)
        return (
            try await asset.load(.duration).seconds, try await asset.loadTracks(withMediaType: .video),
            try await asset.loadTracks(withMediaType: .audio)
        )
    }

    @Test func aFilmIsWrittenAsA1080pShapedVideoWithoutSoundWhenThereIsNone() async throws {
        let plan = plan(3)
        let exporter = FilmExporter(plan: plan, material: material(3), size: size, codec: .h264, music: nil, fileName: "Lisbon / Porto")
        let progress = ProgressLog()
        let url = try await exporter.export { progress.add($0) }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "Lisbon - Porto.mp4")
        let (duration, video, audio) = try await tracks(url)
        #expect(abs(duration - plan.duration) < 0.2)
        #expect(video.count == 1 && audio.isEmpty)
        #expect(try await video[0].load(.naturalSize) == size)
        #expect(progress.values.last == 1)
        #expect(progress.values == progress.values.sorted())
        // Only the finished file is left in its folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test func theMusicGoesIntoTheVideoLoopedOverTheFilm() async throws {
        let music = try clickTrack(tempo: 120, seconds: 6)
        defer { try? FileManager.default.removeItem(at: music) }
        let plan = plan(3)
        let exporter = FilmExporter(plan: plan, material: material(3), size: size, codec: .hevc, music: music, fileName: "With music")
        let url = try await exporter.export { _ in }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (duration, video, audio) = try await tracks(url)
        #expect(video.count == 1 && audio.count == 1)
        #expect(abs(duration - plan.duration) < 0.3)
        #expect(try await audio[0].load(.timeRange).duration.seconds > plan.duration - 0.5)
    }

    @Test func clipsAndMapFlightsAreRendered() async throws {
        // A clip made by the exporter itself.
        let clipFilm = FilmExporter(plan: plan(2), material: material(2), size: size, codec: .h264, music: nil, fileName: "clip")
        let clip = try await clipFilm.export { _ in }
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        var plan = plan(3, kinds: [.photo, .video(duration: 3), .photo])
        plan.segments.insert(
            FilmSegment(
                content: .flight(
                    from: GeoPoint(latitude: 38, longitude: -9), to: GeoPoint(latitude: 41, longitude: -8), fromName: nil, toName: nil),
                start: plan.segments[2].start, duration: 3, transition: 0.8, seed: 0), at: 2)
        for index in 3..<plan.segments.count { plan.segments[index].start += 3 }
        var material = material(3)
        material.clips[1] = clip
        material.maps[2] = FilmMapPicture(
            image: picture(width: 320, height: 180, red: 0.1), from: CGPoint(x: 0.3, y: 0.6), to: CGPoint(x: 0.7, y: 0.3))
        let url = try await FilmExporter(plan: plan, material: material, size: size, codec: .h264, music: nil, fileName: "trip").export {
            _ in
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (duration, video, _) = try await tracks(url)
        #expect(video.count == 1)
        #expect(abs(duration - plan.duration) < 0.2)
    }

    @Test func cancellingRemovesEverything() async throws {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FilmExporter.workFolder.path)) ?? [])
        let exporter = FilmExporter(plan: plan(12), material: material(12), size: size, codec: .h264, music: nil, fileName: "cancelled")
        let task = Task { try await exporter.export { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FilmExporter.workFolder.path)) ?? [])
        #expect(after.subtracting(before).isEmpty)
    }

    @Test func theBeatOfAMusicFileIsFoundOnTheDevice() async throws {
        let music = try clickTrack(tempo: 96, seconds: 20)
        defer { try? FileManager.default.removeItem(at: music) }
        let rhythm = try #require(await AudioRhythm.rhythm(of: music))
        #expect(abs(rhythm.tempo - 96) < 2)
        #expect(abs(try #require(await AudioRhythm.duration(of: music)) - 20) < 0.1)
        #expect(await AudioRhythm.rhythm(of: URL(filePath: "/nonexistent.m4a")) == nil)
    }

    @Test func visionRectanglesAreTurnedUpsideDown() {
        let crop = FrameFocus.crop(x: 0.1, y: 0.7, width: 0.2, height: 0.2)
        #expect(abs(crop.y - 0.1) < 1e-9 && crop.x == 0.1 && crop.height == 0.2)
        #expect(FilmExporter.safeName("  ") == "Memory")
        #expect(FilmExporter.safeName("a:b?c") == "a-b-c")
    }
}

/// Collects progress reports from the exporter.
final class ProgressLog: @unchecked Sendable {
    // Guarded by `lock`; the exporter reports from its own task.
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
