// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The music of a film style (SPEC §16.6), composed on the device: the app ships no recordings (they would need licences),
/// so each style has a short piece written by this code, in its own mood and tempo, that loops seamlessly. Its tempo is
/// known, so the film is cut to its beat exactly. `ScoreSynth` (PhotosMedia) plays the notes.
public struct FilmScore: Hashable, Sendable {
    public enum Mood: String, CaseIterable, Hashable, Sendable, Codable {
        /// Warm pads and a gentle plucked arpeggio, major, 70 BPM.
        case cinematic
        /// Drums, bass and bright plucked chords, 120 BPM.
        case upbeat
        /// A sparse plucked melody over soft minor pads, 66 BPM.
        case nostalgic
        /// A wobbly organ-like chord and a shaker, like a tape of the seventies, 96 BPM.
        case homeMovie
        /// Slow pads only, 54 BPM.
        case ambient
    }

    public enum Instrument: String, Hashable, Sendable {
        /// Soft sustained chord tones.
        case pad
        /// A plucked string (Karplus–Strong).
        case pluck
        case bass
        /// A drawbar-organ tone with a slow wobble.
        case organ
        case kick
        case hat
        case shaker
    }

    public struct Note: Hashable, Sendable {
        /// Seconds from the start of the loop.
        public var start: Double
        public var length: Double
        /// MIDI note number (60 = middle C); ignored for drums.
        public var pitch: Int
        /// 0…1.
        public var velocity: Double
        public var instrument: Instrument
    }

    public var mood: Mood
    /// Beats per minute.
    public var tempo: Double
    /// Bars of four beats in one loop.
    public var bars: Int
    public var notes: [Note]

    public var beat: Double { 60 / tempo }
    /// The loop's length in seconds.
    public var length: Double { Double(bars * 4) * beat }
    /// The film's rhythm: the score's beat, its first beat at the start.
    public var rhythm: FilmRhythm { FilmRhythm(beat: beat, phase: 0, isMusical: true) }

    /// The tempo of a mood.
    public static func tempo(of mood: Mood) -> Double {
        switch mood {
        case .cinematic: 70
        case .upbeat: 120
        case .nostalgic: 66
        case .homeMovie: 96
        case .ambient: 54
        }
    }

    /// A chord as MIDI notes (root position, close voicing).
    struct Chord {
        var root: Int
        var minor: Bool
        var tones: [Int] { [root, root + (minor ? 3 : 4), root + 7] }
    }

    /// The chords of a mood, one per bar, repeated through the loop.
    static func progression(_ mood: Mood) -> [Chord] {
        switch mood {
        // I – V – vi – IV in D.
        case .cinematic:
            [Chord(root: 62, minor: false), Chord(root: 57, minor: false), Chord(root: 59, minor: true), Chord(root: 55, minor: false)]
        // I – vi – IV – V in A.
        case .upbeat:
            [Chord(root: 57, minor: false), Chord(root: 54, minor: true), Chord(root: 62, minor: false), Chord(root: 64, minor: false)]
        // i – VI – III – VII in A minor.
        case .nostalgic:
            [Chord(root: 57, minor: true), Chord(root: 53, minor: false), Chord(root: 60, minor: false), Chord(root: 55, minor: false)]
        // I – iii – IV – IV in F.
        case .homeMovie:
            [Chord(root: 53, minor: false), Chord(root: 57, minor: true), Chord(root: 58, minor: false), Chord(root: 58, minor: false)]
        // Imaj – IV in E, two bars each.
        case .ambient:
            [Chord(root: 52, minor: false), Chord(root: 52, minor: false), Chord(root: 57, minor: false), Chord(root: 57, minor: false)]
        }
    }

    /// The score of a mood: 16 bars (8 for the slow ambient one) that end where they begin, so the loop is seamless.
    public init(mood: Mood) {
        self.mood = mood
        tempo = Self.tempo(of: mood)
        bars = mood == .ambient ? 8 : 16
        let beat = 60 / tempo
        let chords = Self.progression(mood)
        var notes: [Note] = []
        func add(_ start: Double, _ length: Double, _ pitch: Int, _ velocity: Double, _ instrument: Instrument) {
            notes.append(Note(start: start, length: length, pitch: pitch, velocity: velocity, instrument: instrument))
        }
        for bar in 0..<bars {
            let chord = chords[bar % chords.count]
            let barStart = Double(bar * 4) * beat
            // The second half of the loop is a little fuller than the first.
            let lift = bar >= bars / 2
            switch mood {
            case .cinematic:
                for tone in chord.tones { add(barStart, 4 * beat, tone - 12, 0.32, .pad) }
                let pattern = [0, 1, 2, 1, 0, 2, 1, 2]
                for step in 0..<8 {
                    let tone = chord.tones[pattern[step]] + (step == 4 && lift ? 12 : 0)
                    add(barStart + Double(step) * beat / 2, beat, tone + 12, step % 2 == 0 ? 0.55 : 0.4, .pluck)
                }
                add(barStart, 4 * beat, chord.root - 24, 0.4, .bass)
            case .upbeat:
                for step in 0..<4 {
                    add(barStart + Double(step) * beat, beat / 2, 36, 0.9, .kick)
                    add(barStart + (Double(step) + 0.5) * beat, beat / 4, 0, step % 2 == 1 ? 0.55 : 0.4, .hat)
                    if lift { add(barStart + (Double(step) + 0.25) * beat, beat / 8, 0, 0.18, .hat) }
                    add(barStart + Double(step) * beat, beat * 0.9, chord.root - 24 + (step == 3 ? 7 : 0), 0.6, .bass)
                }
                for (step, offset) in [0.0, 1.5, 2.5, 3.0].enumerated() {
                    for tone in chord.tones { add(barStart + offset * beat, beat / 2, tone + 12, step == 0 ? 0.42 : 0.32, .pluck) }
                }
            case .nostalgic:
                for tone in chord.tones { add(barStart, 4 * beat, tone - 12, 0.26, .pad) }
                // A slow melody: chord tones on beats one and three, a passing note on four.
                let melody = [chord.tones[2] + 12, chord.tones[1] + 12, chord.tones[0] + 14]
                add(barStart, 2 * beat, melody[0], 0.55, .pluck)
                add(barStart + 2 * beat, 1.5 * beat, melody[1], 0.45, .pluck)
                if lift || bar % 2 == 1 { add(barStart + 3.5 * beat, beat / 2, melody[2], 0.35, .pluck) }
                add(barStart, 4 * beat, chord.root - 24, 0.3, .bass)
            case .homeMovie:
                for beatIndex in [0, 2] {
                    for tone in chord.tones { add(barStart + Double(beatIndex) * beat, 1.8 * beat, tone, 0.3, .organ) }
                }
                for step in 0..<8 {
                    add(barStart + Double(step) * beat / 2, beat / 4, 0, step % 2 == 0 ? 0.32 : 0.2, .shaker)
                }
                add(barStart, beat * 1.5, chord.root - 24, 0.5, .bass)
                add(barStart + 2 * beat, beat * 1.5, chord.root - 17, 0.45, .bass)
                if lift { add(barStart + 3 * beat, beat, chord.tones[2] + 12, 0.3, .pluck) }
            case .ambient:
                if bar % 2 == 0 {
                    for tone in chord.tones + [chord.root + 11] { add(barStart, 8 * beat, tone - 12, 0.28, .pad) }
                    add(barStart, 8 * beat, chord.root - 24, 0.25, .bass)
                }
                if lift && bar % 2 == 1 { add(barStart + beat, 2 * beat, chord.tones[2] + 12, 0.22, .pluck) }
            }
        }
        self.notes = notes
    }

    /// MIDI note number to frequency (A4 = 440 Hz).
    public static func frequency(_ pitch: Int) -> Double { 440 * pow(2, Double(pitch - 69) / 12) }
}
