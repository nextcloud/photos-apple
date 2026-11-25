// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import PhotosDomain

/// Plays a film style's score (`FilmScore`, SPEC §16.6) into sound on the device: a few simple instruments (soft pads, a
/// plucked string, bass, an organ with a tape wobble, drums made of noise and a falling sine) and a little room reverb.
/// The loop's end rings over into its start, so it repeats without a seam. Deterministic: every device makes the same
/// music for the same style, which is what lets people watching together over SharePlay hear the same thing without
/// anything being sent.
public enum ScoreSynth {
    public static let sampleRate = 32_000.0
    /// The format version of the files below: change it when the music changes, so old files are made again.
    static let version = 1

    /// The score as stereo samples (left, right), one loop long.
    public static func render(_ score: FilmScore) -> (left: [Float], right: [Float]) {
        let rate = sampleRate
        let loop = Int((score.length * rate).rounded())
        let tail = Int(4 * rate)
        var dry = [Float](repeating: 0, count: loop + tail)
        var random = Noise(seed: UInt64(score.mood.rawValue.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt32($1.value) }))
        dry.withUnsafeMutableBufferPointer { out in
            for note in score.notes {
                let start = Int(note.start * rate)
                switch note.instrument {
                case .pad: pad(note, start: start, into: out)
                case .pluck: pluck(note, start: start, into: out, random: &random)
                case .bass: bass(note, start: start, into: out)
                case .organ: organ(note, start: start, into: out)
                case .kick: kick(note, start: start, into: out)
                case .hat, .shaker: noiseHit(note, start: start, into: out, random: &random)
                }
            }
        }
        if score.mood == .homeMovie { lowPass(&dry, cutoff: 4200) }
        var (left, right) = reverb(dry, wet: wetness(score.mood))
        // The loop's end rings over into its start.
        for index in 0..<tail {
            left[index] += left[loop + index]
            right[index] += right[loop + index]
        }
        left.removeLast(tail)
        right.removeLast(tail)
        master(&left, &right)
        return (left, right)
    }

    static func wetness(_ mood: FilmScore.Mood) -> Float {
        switch mood {
        case .ambient: 0.5
        case .nostalgic: 0.38
        case .cinematic: 0.32
        case .homeMovie: 0.2
        case .upbeat: 0.14
        }
    }

    // MARK: Instruments

    /// An envelope: attack, then sustain until `length`, then release; 0 outside.
    @inline(__always) static func envelope(_ t: Double, length: Double, attack: Double, release: Double) -> Double {
        if t < 0 { return 0 }
        if t < attack { return t / attack }
        if t < length { return 1 }
        let after = t - length
        return after < release ? 1 - after / release : 0
    }

    /// A band-limited sawtooth-like wave (first harmonics, softly falling): warm, never harsh.
    static let warmTable: [Float] = {
        let size = 2048
        return (0..<size).map { index in
            let phase = Double(index) / Double(size) * 2 * .pi
            var value = 0.0
            for harmonic in 1...7 { value += sin(phase * Double(harmonic)) / Double(harmonic * harmonic) * (harmonic == 1 ? 1 : 1.6) }
            return Float(value * 0.7)
        }
    }()

    static func pad(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let rate = sampleRate
        let attack = min(1.2, note.length * 0.35)
        let release = 1.6
        let count = Int((note.length + release) * rate)
        let base = FilmScore.frequency(note.pitch)
        let table = warmTable
        let size = Double(table.count)
        // Three slightly detuned voices: a slow chorus.
        for detune in [-0.004, 0.0, 0.0045] {
            let step = base * (1 + detune) / rate * size
            var phase = Double(abs(detune) * 997).truncatingRemainder(dividingBy: size)
            var filtered = 0.0
            let gain = note.velocity * 0.07
            for index in 0..<count {
                let target = start + index
                if target >= out.count { break }
                let sample = Double(table[Int(phase) & 2047])
                phase += step
                if phase >= size { phase -= size }
                // One-pole low-pass: a soft, dark pad.
                filtered += (sample - filtered) * 0.18
                let t = Double(index) / rate
                out[target] += Float(filtered * gain * envelope(t, length: note.length, attack: attack, release: release))
            }
        }
    }

    /// A plucked string (Karplus–Strong): a burst of noise in a delay line as long as one period, softened on every pass.
    static func pluck(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>, random: inout Noise) {
        let rate = sampleRate
        let period = max(2, Int((rate / FilmScore.frequency(note.pitch)).rounded()))
        var line = (0..<period).map { _ in Float(random.next() * 2 - 1) }
        // Softer attack: the burst is smoothed first.
        for index in 1..<period { line[index] = (line[index] + line[index - 1]) * 0.5 }
        let ring = min(note.length + 1.6, 3.5)
        let count = Int(ring * rate)
        let gain = Float(note.velocity * 0.32)
        var position = 0
        for index in 0..<count {
            let target = start + index
            if target >= out.count { break }
            let next = (position + 1) % period
            let value = line[position]
            line[position] = (value + line[next]) * 0.4985
            position = next
            // Fades out over the last 0.3 s.
            let left = Double(count - index) / rate
            out[target] += value * gain * Float(min(1, left / 0.3))
        }
    }

    static func bass(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let rate = sampleRate
        let frequency = FilmScore.frequency(note.pitch)
        let count = Int((note.length + 0.25) * rate)
        let gain = note.velocity * 0.3
        for index in 0..<count {
            let target = start + index
            if target >= out.count { break }
            let t = Double(index) / rate
            let phase = 2 * .pi * frequency * t
            let tone = sin(phase) + 0.25 * sin(2 * phase)
            let decay = 0.75 + 0.25 * exp(-t * 6)
            out[target] += Float(tone * gain * decay * envelope(t, length: note.length, attack: 0.012, release: 0.2))
        }
    }

    /// Drawbar organ with vibrato and a slow tape wobble.
    static func organ(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let rate = sampleRate
        let frequency = FilmScore.frequency(note.pitch)
        let count = Int((note.length + 0.15) * rate)
        let gain = note.velocity * 0.1
        var phase = 0.0
        for index in 0..<count {
            let target = start + index
            if target >= out.count { break }
            // Film time, so the wobble runs on across notes.
            let time = Double(target) / rate
            let wobble = 1 + 0.003 * sin(2 * .pi * 5.2 * time) + 0.005 * sin(2 * .pi * 0.45 * time)
            phase += 2 * .pi * frequency * wobble / rate
            let tone = 0.6 * sin(phase) + 0.3 * sin(2 * phase) + 0.15 * sin(3 * phase) + 0.08 * sin(4 * phase)
            let t = Double(index) / rate
            out[target] += Float(tone * gain * envelope(t, length: note.length, attack: 0.03, release: 0.12))
        }
    }

    static func kick(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let rate = sampleRate
        let count = Int(0.45 * rate)
        var phase = 0.0
        for index in 0..<count {
            let target = start + index
            if target >= out.count { break }
            let t = Double(index) / rate
            phase += 2 * .pi * (48 + 95 * exp(-t / 0.035)) / rate
            out[target] += Float(sin(phase) * exp(-t / 0.16) * note.velocity * 0.55)
        }
    }

    /// Hi-hat and shaker: high-passed noise with a short decay (the shaker swells in a little).
    static func noiseHit(_ note: FilmScore.Note, start: Int, into out: UnsafeMutableBufferPointer<Float>, random: inout Noise) {
        let rate = sampleRate
        let shaker = note.instrument == .shaker
        let decay = shaker ? 0.05 : 0.028
        let count = Int(decay * 6 * rate)
        var previous = 0.0
        for index in 0..<count {
            let target = start + index
            if target >= out.count { break }
            let t = Double(index) / rate
            let white = random.next() * 2 - 1
            let high = white - previous
            previous = white
            let swell = shaker ? min(1, t / 0.008) : 1
            out[target] += Float(high * exp(-t / decay) * swell * note.velocity * (shaker ? 0.09 : 0.12))
        }
    }

    // MARK: Mixing

    static func lowPass(_ samples: inout [Float], cutoff: Double) {
        let alpha = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
        var state: Float = 0
        for index in samples.indices {
            state += (samples[index] - state) * alpha
            samples[index] = state
        }
    }

    /// A small room (Freeverb-like: parallel combs, then all-passes), slightly different left and right.
    static func reverb(_ dry: [Float], wet: Float) -> ([Float], [Float]) {
        func channel(spread: Int) -> [Float] {
            let scale = sampleRate / 44_100
            let combs = [1116, 1188, 1277, 1356].map { max(1, Int(Double($0 + spread) * scale)) }
            let allpasses = [556, 441].map { max(1, Int(Double($0 + spread) * scale)) }
            var output = [Float](repeating: 0, count: dry.count)
            dry.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    for length in combs {
                        var buffer = [Float](repeating: 0, count: length)
                        buffer.withUnsafeMutableBufferPointer { line in
                            var position = 0
                            var damped: Float = 0
                            for index in 0..<input.count {
                                let delayed = line[position]
                                damped = delayed * 0.7 + damped * 0.3
                                line[position] = input[index] * 0.015 + damped * 0.84
                                out[index] += delayed
                                position += 1
                                if position == length { position = 0 }
                            }
                        }
                    }
                    for length in allpasses {
                        var buffer = [Float](repeating: 0, count: length)
                        buffer.withUnsafeMutableBufferPointer { line in
                            var position = 0
                            for index in 0..<out.count {
                                let delayed = line[position]
                                let value = out[index]
                                line[position] = value + delayed * 0.5
                                out[index] = delayed - value
                                position += 1
                                if position == length { position = 0 }
                            }
                        }
                    }
                }
            }
            return output
        }
        let left = channel(spread: 0)
        let right = channel(spread: 23)
        let dryGain = 1 - wet * 0.5
        var mixedLeft = [Float](repeating: 0, count: dry.count)
        var mixedRight = [Float](repeating: 0, count: dry.count)
        for index in dry.indices {
            mixedLeft[index] = dry[index] * dryGain + left[index] * wet * 4
            mixedRight[index] = dry[index] * dryGain + right[index] * wet * 4
        }
        return (mixedLeft, mixedRight)
    }

    /// Soft saturation, then the loudest moment at −2 dB.
    static func master(_ left: inout [Float], _ right: inout [Float]) {
        for index in left.indices {
            left[index] = tanhf(left[index] * 1.2)
            right[index] = tanhf(right[index] * 1.2)
        }
        let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        guard peak > 0 else { return }
        let gain = 0.79 / peak
        for index in left.indices {
            left[index] *= gain
            right[index] *= gain
        }
    }

    /// A small deterministic noise source (SplitMix64).
    struct Noise {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    // MARK: Files

    /// Where the scores are kept once made (the caches: they are made again when the system clears them).
    public static var folder: URL { URL.cachesDirectory.appending(path: "FilmScores", directoryHint: .isDirectory) }

    /// The score's file when it has been made already.
    public static func existingFile(for mood: FilmScore.Mood, folder: URL = folder) -> URL? {
        let url = folder.appending(path: "\(mood.rawValue)-v\(version).caf")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// The score of a mood as an audio file, made on first use (about a second of work), nil when it cannot be written.
    public static func file(for mood: FilmScore.Mood, folder: URL = folder) async -> URL? {
        if let made = existingFile(for: mood, folder: folder) { return made }
        let url = folder.appending(path: "\(mood.rawValue)-v\(version).caf")
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let (left, right) = render(FilmScore(mood: mood))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Written next to it first: a half-written file is never taken for a finished one.
                let partial = folder.appending(path: "\(UUID().uuidString).partial.caf")
                try write(left: left, right: right, to: partial)
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: partial, to: url)
                return url
            } catch {
                return nil
            }
        }.value
    }

    static func write(left: [Float], right: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
            let channels = buffer.floatChannelData
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
