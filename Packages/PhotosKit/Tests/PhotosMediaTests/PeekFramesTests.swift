// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreGraphics
import Foundation
import PhotosNetworking
import Testing

@testable import PhotosMedia

/// Scrub to peek (SPEC §16.1) makes frames of a video that is not on the device from the stream the viewer plays: the
/// image generator must work through `StreamingAssetLoader`. Writes and decodes video: not in the simulator (no GPU).
@Suite(.timeLimit(.minutes(1)), .disabled(if: TestEnvironment.isSimulator, "Writes and decodes video"))
struct PeekFramesTests {
    /// A two-second H.264 clip, written with AVAssetWriter.
    static func clip() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "peek-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.featureUnsupported) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 12), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        receiver.finish()
        await writer.finishWriting()
        return try Data(contentsOf: url)
    }

    @Test func framesOfAStreamedVideo() async throws {
        let body = try await Self.clip()
        let source = MediaByteSource(url: URL(string: "https://cloud.example/remote.php/direct/token")!, chunkSize: 64 * 1024) {
            _, headers in
            guard let range = headers["Range"], range.hasPrefix("bytes=") else { return HTTPResponse(status: 200, data: body) }
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let upper = min(bounds[1], body.count - 1)
            return HTTPResponse(
                status: 206, headers: ["content-type": "video/mp4", "content-range": "bytes \(bounds[0])-\(upper)/\(body.count)"],
                data: body.subdata(in: bounds[0]..<(upper + 1)))
        }
        let loader = StreamingAssetLoader(source: source, mimeType: "video/mp4")
        let asset = loader.makeAsset(fileName: "clip.mp4")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.2)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        var images = 0
        for await result in generator.images(for: [0.25, 1.0, 1.75].map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if (try? result.image) != nil { images += 1 }
        }
        withExtendedLifetime(loader) {}
        #expect(images == 3)
    }
}
