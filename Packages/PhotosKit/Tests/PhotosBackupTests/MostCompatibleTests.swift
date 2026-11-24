// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel

/// "Most compatible" videos (SPEC §7.18.2): HEVC becomes H.264, with the real encoder.
@Suite(.timeLimit(.minutes(1))) struct MostCompatibleTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MostCompatibleTests-\(UUID().uuidString)")

    /// Writes a short video with the codec, and a creation date in its metadata.
    func makeVideo(_ codec: AVVideoCodecType, name: String = "IMG_0001.MOV") async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let date = AVMutableMetadataItem()
        date.keySpace = .quickTimeMetadata
        date.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        date.value = "2024-05-01T12:30:45+0200" as NSString
        writer.metadata = [date]
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    func codec(of url: URL) async throws -> FourCharCode? {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        return try await track?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func anHEVCVideoBecomesH264AndOnlyTheConvertedFileIsLeft() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(.hevc)
        #expect(try await codec(of: source) == kCMVideoCodecType_HEVC)
        let converted = try await MostCompatible.convertToH264(source)
        #expect(converted != source)
        #expect(converted.pathExtension == "mov")
        #expect(try await codec(of: converted) == kCMVideoCodecType_H264)
        #expect(files() == [converted.lastPathComponent])
        // The capture date stays (the server reads it, and the matcher compares capture seconds).
        let metadata = try await AVURLAsset(url: converted).load(.metadata)
        let dates = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        #expect(try await dates.first?.load(.stringValue)?.hasPrefix("2024-05-01T12:30:45") == true)
        // The uploaded name keeps the original's name with the extension of what is uploaded.
        let name = BackupNaming.fileName(
            originalName: "IMG_0001.MOV", fileExtension: converted.pathExtension, isVideo: true, date: Date(), naming: .original)
        #expect(name == "IMG_0001.mov")
    }

    @Test func anH264VideoIsUploadedAsItIs() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(.h264)
        #expect(try await MostCompatible.convertToH264(source) == source)
        #expect(files() == ["IMG_0001.MOV"])
    }

    @Test func aVideoThatCannotBeReadIsUploadedAsItIsAndNothingIsLeftBehind() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let broken = directory.appending(path: "IMG_0002.MOV")
        try Data(repeating: 3, count: 100).write(to: broken)
        let resource = BackupResource(
            localIdentifier: "x", kind: .video, mediaKind: .video, originalName: "IMG_0002.MOV", createdAt: Date(), pixelWidth: 0,
            pixelHeight: 0)
        #expect(try await MostCompatible.convert(broken, resource: resource) == broken)
        #expect(files() == ["IMG_0002.MOV"])
    }

    @Test func whatMayBeConvertedAndTheRoomItNeeds() {
        var settings = BackupSettings()
        let video = BackupResource(
            localIdentifier: "x", kind: .video, mediaKind: .video, originalName: "IMG_0001.MOV", createdAt: Date(), pixelWidth: 0,
            pixelHeight: 0, byteSize: 100)
        var raw = video
        raw.kind = .raw
        raw.mediaKind = .image
        #expect(!MostCompatible.mayConvert(video, settings: settings))
        #expect(MostCompatible.spaceNeeded(video, settings: settings) == 100)
        settings.format = .mostCompatible
        #expect(MostCompatible.mayConvert(video, settings: settings))
        #expect(!MostCompatible.mayConvert(raw, settings: settings))
        #expect(MostCompatible.spaceNeeded(video, settings: settings) == 200)
        #expect(MostCompatible.spaceNeeded(raw, settings: settings) == 100)
    }
}
