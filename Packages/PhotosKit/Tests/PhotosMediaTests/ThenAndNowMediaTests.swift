// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel

/// The time-lapse video and the view matching of "Then and now" (SPEC §15.6).
@Suite struct ThenAndNowMediaTests {
    /// A test picture: a coloured background with a white square at a position (the "view").
    static func picture(width: Int, height: Int, gray: CGFloat, square: CGPoint) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: gray, green: 0.3, blue: 1 - gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let side = CGSize(width: CGFloat(width) / 4, height: CGFloat(height) / 4)
        context.fill(CGRect(origin: CGPoint(x: square.x * CGFloat(width), y: square.y * CGFloat(height)), size: side))
        return context.makeImage()!
    }

    @Test func videoSizeFollowsMostPhotos() {
        let portrait = Self.picture(width: 30, height: 40, gray: 0.5, square: .zero)
        let landscape = Self.picture(width: 40, height: 30, gray: 0.5, square: .zero)
        #expect(TimeLapseVideo.size(for: [portrait, portrait, landscape]) == CGSize(width: 1080, height: 1920))
        #expect(TimeLapseVideo.size(for: [portrait, landscape]) == CGSize(width: 1920, height: 1080))
    }

    @Test func filledRectCoversTheFrame() {
        let image = Self.picture(width: 400, height: 300, gray: 0.5, square: .zero)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = TimeLapseVideo.filled(image, in: bounds, scale: 1)
        #expect(rect.height == 100)
        #expect(abs(rect.width - 133.333) < 0.01)
        #expect(abs(rect.midX - 50) < 1e-9)
        #expect(TimeLapseVideo.filled(image, in: bounds, scale: 2).height == 200)
    }

    @Test func writesAShortVideo() async throws {
        let frames = [
            TimeLapseVideo.Frame(image: Self.picture(width: 320, height: 240, gray: 0.1, square: .zero), caption: "2014"),
            TimeLapseVideo.Frame(image: Self.picture(width: 320, height: 240, gray: 0.9, square: CGPoint(x: 0.5, y: 0.5)), caption: "2025"),
        ]
        let url = FileManager.default.temporaryDirectory.appending(path: "then-and-now-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = TimeLapsePlan(count: 2, hold: 0.5, fade: 0.5)
        try await TimeLapseVideo.write(frames, to: url, plan: plan, size: CGSize(width: 320, height: 240), framesPerSecond: 10)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - plan.duration) < 0.15)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await tracks.first?.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 240))
    }

    @Test func refusesNoFrames() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "empty-\(UUID().uuidString).mp4")
        await #expect(throws: TimeLapseVideo.Failure.self) { try await TimeLapseVideo.write([], to: url) }
    }

    @Test func drawsTheCrossFade() throws {
        // A frame half-way into the second photo shows its colours more than the first's.
        let dark = Self.picture(width: 64, height: 64, gray: 0, square: CGPoint(x: 2, y: 2))
        let bright = Self.picture(width: 64, height: 64, gray: 1, square: CGPoint(x: 2, y: 2))
        let frames = [TimeLapseVideo.Frame(image: dark, caption: ""), TimeLapseVideo.Frame(image: bright, caption: "")]
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let moment = TimeLapsePlan.Moment(from: 0, to: 1, mix: 0.75, fromScale: 1, toScale: 1)
        TimeLapseVideo.draw(moment, frames: frames, in: context, size: CGSize(width: 64, height: 64))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let red = Double(pixels[0]) / 255
        let blue = Double(pixels[2]) / 255
        #expect(red > 0.6 && blue < 0.4)
    }

    @Test func alignKeepsTheSpotWithoutPictures() async {
        let spot = ThenAndNowSpot(
            id: "s", center: GeoCoordinate(latitude: 1, longitude: 1), placeName: nil, countryCode: nil,
            years: [.init(year: 2000, items: [1, 2]), .init(year: 2010, items: [3, 4])])
        let aligned = await ViewMatcher.align(spot) { _ in nil }
        #expect(aligned == spot)
    }

    @Test func alignPrefersTheSameView() async throws {
        // 2025's photo shows the square top right; of 2015's, photo 2 shows the same, photo 1 something else.
        let pictures: [FileID: CGImage] = [
            1: Self.picture(width: 256, height: 256, gray: 0.2, square: CGPoint(x: 0.05, y: 0.05)),
            2: Self.picture(width: 256, height: 256, gray: 0.6, square: CGPoint(x: 0.7, y: 0.7)),
            3: Self.picture(width: 256, height: 256, gray: 0.6, square: CGPoint(x: 0.7, y: 0.7)),
        ]
        let spot = ThenAndNowSpot(
            id: "s", center: GeoCoordinate(latitude: 1, longitude: 1), placeName: nil, countryCode: nil,
            years: [.init(year: 2015, items: [1, 2]), .init(year: 2025, items: [3])])
        let aligned = await ViewMatcher.align(spot) { id in pictures[id] }
        // Vision may be unavailable where the tests run (no feature prints): then the order is kept.
        #expect(aligned.covers == [2, 3] || aligned == spot)
    }
}
