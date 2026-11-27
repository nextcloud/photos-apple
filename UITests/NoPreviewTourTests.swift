// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import XCTest

#if os(iOS)
    import UIKit

    /// Files the server has no preview of get one made on the device (SPEC §20.1): a HEIC photo and a QuickTime video
    /// (a server with the default preview providers has neither the HEIC nor the Movie provider), uploaded by the test
    /// into a folder of its own and dated now, so they are the first tiles of the Library. The test library's two
    /// damaged files (24 bytes of a JPEG header) stay "No preview": nothing can draw them.
    @MainActor
    final class NoPreviewTourTests: XCTestCase {
        static let wait: TimeInterval = 90

        var app: XCUIApplication!
        private var shotsDirectory: URL?

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            if let path = environment["PHOTOS_UITEST_SHOTS"], !path.isEmpty {
                shotsDirectory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            }
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        private func shot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let shotsDirectory else { return }
            try? screenshot.pngRepresentation.write(to: shotsDirectory.appending(path: "\(name).png"))
            try? Data(app.debugDescription.utf8).write(to: shotsDirectory.appending(path: "\(name).txt"))
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        func testPicturesMadeOnTheDevice() async throws {
            let login = ProcessInfo.processInfo.environment["PHOTOS_UITEST_LOGIN"] ?? ""
            let folder = "Photos/UI test no preview \(UUID().uuidString.prefix(8))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder), "PHOTOS_UITEST_LOGIN is not a login link")
            addTeardownBlock { try? await server.removeFolder() }
            try await server.upload(Self.heic(), name: "no-preview-photo.heic", contentType: "image/heic")
            try await server.upload(try await Self.movie(), name: "no-preview-clip.mov", contentType: "video/quicktime", age: 1)
            app.launch()
            let tiles = app.collectionViews.cells
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded files did not arrive")
            // Both made on the device: no tile of "Today" says "No preview".
            let first = tiles.element(boundBy: 0)
            let second = tiles.element(boundBy: 1)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, first.label.contains("No preview") || second.label.contains("No preview") { pause(1) }
            pause(3)
            shot("nopreview-01-library")
            XCTAssertFalse(first.label.contains("No preview"), "The newest file has no picture: \(first.label)")
            XCTAssertFalse(second.label.contains("No preview"), "The second file has no picture: \(second.label)")
            // The viewer shows the photo made on the device.
            second.tap()
            pause(3)
            shot("nopreview-02-viewer")
        }

        /// A HEIC photo without EXIF data: the server dates it by its modification time.
        static func heic() -> Data {
            let size = CGSize(width: 1200, height: 900)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                for band in 0..<6 {
                    UIColor(hue: CGFloat(band) / 6, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: CGFloat(band) * size.width / 6, y: 0, width: size.width / 6, height: size.height))
                }
            }
            return image.heicData() ?? Data()
        }

        /// A three-second QuickTime movie of colour fields.
        static func movie() async throws -> Data {
            let url = FileManager.default.temporaryDirectory.appending(path: "no-preview-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
            // The receiver API of OS 27 (the adaptor, `add`, `startWriting` and `isReadyForMoreMediaData` are deprecated
            // there, and warnings fail the UI test build on CI).
            let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<90 {
                guard let buffer = colourField(frame: frame) else { throw CancellationError() }
                try await receiver.append(buffer, with: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            receiver.finish()
            await writer.finishWriting()
            return try Data(contentsOf: url)
        }

        /// One frame: blue to green over the three seconds, opaque (BGRA in memory); a buffer of its own, so it can be
        /// sent to the receiver.
        static func colourField(frame: Int) -> CVReadOnlyPixelBuffer? {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
            let count = CVPixelBufferGetBytesPerRow(buffer) / 4 * 360
            let green = UInt32(min(255, frame * 3))
            for index in 0..<count { pixels[index] = 0xFF00_0000 | (green << 8) | 0xC0 }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
        }
    }
#endif
