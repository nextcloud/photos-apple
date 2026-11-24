// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import PhotosDomain

/// The beat of a music file for a memory film (SPEC §15.1), found on the device (`BeatDetection`). Only audio the app can
/// read is analysed: a file the user chose, or a song of the Music library that is not protected. Apple Music songs
/// (DRM) cannot be read by any app; their films keep the steady rhythm.
public enum AudioRhythm {
    /// The rate the audio is decoded at for the analysis: plenty for drums and attacks, cheap to go through.
    static let sampleRate = 11_025.0
    /// The first minutes are enough to find the tempo.
    static let analysedSeconds = 150.0

    /// The music's rhythm, or nil when it cannot be read or has no clear beat.
    public static func rhythm(of url: URL) async -> FilmRhythm? {
        guard let samples = try? await samples(of: url) else { return nil }
        return BeatDetection.rhythm(samples: samples, sampleRate: sampleRate)
    }

    /// The music's length in seconds, or nil when it cannot be read.
    public static func duration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    /// Mono samples at `sampleRate`, from the start of the music.
    static func samples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: analysedSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        var samples: [Float] = []
        samples.reserveCapacity(Int(sampleRate * analysedSeconds))
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return samples
    }
}
