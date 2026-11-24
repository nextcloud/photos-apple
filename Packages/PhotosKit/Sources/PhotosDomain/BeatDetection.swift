// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Finds the tempo and the beat of music on the device (SPEC §15.1), so a memory film can cut on the beat.
///
/// The classic way, small enough to read: the music's loudness in short windows, how sharply it rises from one window to
/// the next (onsets: drums, plucked notes), the period at which these onsets repeat best (autocorrelation, with a mild
/// preference for moderate tempos so a song is not taken at half or double speed), and the offset at which a grid of
/// that period hits the most onsets. Music without a clear beat (ambient pads, speech) gives nil: the film then keeps
/// its steady rhythm instead of cutting at random moments.
public enum BeatDetection {
    /// Samples per analysis window. At the 11 025 Hz the media layer decodes to, about 23 ms.
    public static let window = 256
    /// Tempos considered, beats per minute.
    public static let tempoRange = 60.0...190.0
    /// The onsets must repeat at the beat this clearly (correlation coefficient) to count: noise stays far below,
    /// music with a beat well above.
    public static let minimumCorrelation = 0.2

    /// The rhythm of mono samples, or nil without a clear beat.
    public static func rhythm(samples: [Float], sampleRate: Double) -> FilmRhythm? {
        let envelope = onsetEnvelope(samples: samples)
        let rate = sampleRate / Double(window)
        guard envelope.count > Int(rate * 4), let coarse = period(envelope, rate: rate) else { return nil }
        // A beat grid that is a little too slow or fast drifts off the music within a minute: the period is refined
        // together with the offset, by how many onsets the whole grid hits.
        var best = (period: coarse, offset: 0.0, score: -1.0)
        for step in -30...30 {
            let candidate = coarse * (1 + Double(step) * 0.001)
            let fit = phase(envelope, period: candidate)
            if fit.score > best.score { best = (candidate, fit.offset, fit.score) }
        }
        return FilmRhythm(beat: best.period / rate, phase: best.offset / rate, isMusical: true)
    }

    /// How sharply the loudness rises at each window: the positive change of log energy, minus its local average.
    public static func onsetEnvelope(samples: [Float]) -> [Double] {
        let count = samples.count / window
        guard count > 2 else { return [] }
        var energies = [Double](repeating: 0, count: count)
        var previous: Float = 0
        for index in 0..<count {
            var sum: Double = 0
            let base = index * window
            for offset in 0..<window {
                let sample = samples[base + offset]
                // A first difference (pre-emphasis) brings out attacks over sustained low notes.
                let emphasised = Double(sample - 0.97 * previous)
                previous = sample
                sum += emphasised * emphasised
            }
            energies[index] = log(1e-9 + sum / Double(window))
        }
        var flux = [Double](repeating: 0, count: count)
        for index in 1..<count { flux[index] = max(0, energies[index] - energies[index - 1]) }
        // Subtract the average of the surrounding half second, so only sudden rises remain.
        let half = 10
        var result = [Double](repeating: 0, count: count)
        var running = flux.prefix(min(count, half + 1)).reduce(0, +)
        var lower = 0
        var upper = min(count - 1, half)
        for index in 0..<count {
            let wantedUpper = min(count - 1, index + half)
            while upper < wantedUpper {
                upper += 1
                running += flux[upper]
            }
            let wantedLower = max(0, index - half)
            while lower < wantedLower {
                running -= flux[lower]
                lower += 1
            }
            result[index] = max(0, flux[index] - running / Double(upper - lower + 1))
        }
        return result
    }

    /// The beat period in windows (fractional), or nil when no period stands out.
    static func period(_ envelope: [Double], rate: Double) -> Double? {
        let shortest = Int((60 / tempoRange.upperBound * rate).rounded(.down))
        let longest = Int((60 / tempoRange.lowerBound * rate).rounded(.up))
        guard longest * 2 < envelope.count, shortest > 1 else { return nil }
        // Correlation coefficients of the envelope with itself shifted (0: unrelated, 1: the same).
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        let centred = envelope.map { $0 - mean }
        let variance = centred.reduce(0) { $0 + $1 * $1 } / Double(centred.count)
        guard variance > 0 else { return nil }
        func correlation(_ lag: Int) -> Double {
            var sum = 0.0
            for index in 0..<(centred.count - lag) { sum += centred[index] * centred[index + lag] }
            return sum / Double(centred.count - lag) / variance
        }
        let raw = (shortest...(longest * 2)).map { (lag: $0, value: correlation($0)) }
        let byLag = Dictionary(uniqueKeysWithValues: raw.map { ($0.lag, $0.value) })
        var scores: [(lag: Int, score: Double)] = []
        for lag in shortest...longest {
            let tempo = 60 * rate / Double(lag)
            // A log-normal preference around 120 BPM, and the double period must agree (a real beat repeats).
            let preference = exp(-0.5 * pow(log2(tempo / 120) / 1.0, 2))
            scores.append((lag, (byLag[lag]! + 0.5 * (byLag[lag * 2] ?? 0)) * preference))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), byLag[best.lag]! >= minimumCorrelation else { return nil }
        // Parabolic interpolation between the neighbouring lags for a period finer than one window.
        guard let left = byLag[best.lag - 1], let right = byLag[best.lag + 1], let centre = byLag[best.lag] else {
            return Double(best.lag)
        }
        let denominator = left - 2 * centre + right
        let shift = denominator == 0 ? 0 : 0.5 * (left - right) / denominator
        return Double(best.lag) + min(0.5, max(-0.5, shift))
    }

    /// The offset (windows, 0 ≤ offset < period) of the beat grid that hits the strongest onsets, and how strongly (the
    /// mean onset strength on the grid).
    static func phase(_ envelope: [Double], period: Double) -> (offset: Double, score: Double) {
        let steps = 4
        var best = (offset: 0.0, score: -1.0)
        for candidate in 0..<Int(period * Double(steps)) {
            let offset = Double(candidate) / Double(steps)
            var score = 0.0
            var hits = 0
            var position = offset
            while position < Double(envelope.count - 1) {
                // The strongest onset within half a window of the grid line.
                let nearest = Int(position.rounded())
                score += max(envelope[nearest], envelope[max(0, nearest - 1)] * 0.5, envelope[min(envelope.count - 1, nearest + 1)] * 0.5)
                hits += 1
                position += period
            }
            let mean = hits > 0 ? score / Double(hits) : 0
            if mean > best.score { best = (offset, mean) }
        }
        return best
    }
}
