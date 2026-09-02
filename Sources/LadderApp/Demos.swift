import Foundation

struct DemoEvent {
    var time: Int      // sample offset within the loop
    var isOn: Bool
    var note: UInt8
    var vel: Float
}

struct DemoSequence {
    var name: String
    var events: [DemoEvent]   // sorted by time, offs before ons at equal times
    var length: Int           // loop length in samples
}

/// Built-in demo loops, generated as event lists at engine start (before the
/// audio thread runs) so playback needs no allocation.
enum Demos {
    static let names = ["PRELUDE IN C", "MINUET IN G", "ALLA TURCA"]

    static func all(sampleRate: Double) -> [DemoSequence] {
        [preludeInC(sampleRate), minuetInG(sampleRate), allaTurca(sampleRate)]
    }

    // (start beat, MIDI note, duration in beats, velocity)
    private typealias N = (t: Double, note: Int, dur: Double, vel: Float)

    private static func build(_ name: String, bpm: Double, beats: Double,
                              _ notes: [N], _ sampleRate: Double) -> DemoSequence {
        let spb = 60.0 / bpm * sampleRate
        var events: [DemoEvent] = []
        let length = Int(beats * spb)
        for n in notes {
            let on = Int(n.t * spb)
            // Clamp note-offs inside the loop so nothing sticks across the wrap.
            let off = min(Int((n.t + n.dur) * spb), length - 1)
            events.append(DemoEvent(time: on, isOn: true, note: UInt8(n.note), vel: n.vel))
            events.append(DemoEvent(time: off, isOn: false, note: UInt8(n.note), vel: 0))
        }
        events.sort { ($0.time, $0.isOn ? 1 : 0) < ($1.time, $1.isOn ? 1 : 0) }
        return DemoSequence(name: name, events: events, length: length)
    }

    /// Bach, Prelude in C major BWV 846, first 8 bars of the arpeggio pattern.
    private static func preludeInC(_ sr: Double) -> DemoSequence {
        let chords: [[Int]] = [
            [60, 64, 67, 72, 76],   // C
            [60, 62, 69, 74, 77],   // Dm7/C
            [59, 62, 67, 74, 77],   // G7/B
            [60, 64, 67, 72, 76],   // C
            [60, 64, 69, 76, 81],   // Am/C
            [60, 62, 66, 69, 74],   // D7/C
            [59, 62, 67, 74, 79],   // G/B
            [59, 60, 64, 67, 72],   // C7/B... Cmaj7/B
        ]
        var notes: [N] = []
        for (bar, chord) in chords.enumerated() {
            let barStart = Double(bar) * 4
            for half in 0..<2 {
                let start = barStart + Double(half) * 2
                let order = [0, 1, 2, 3, 4, 2, 3, 4]
                for (i, idx) in order.enumerated() {
                    let vel: Float = i == 0 ? 0.6 : 0.5
                    notes.append((start + Double(i) * 0.25, chord[idx], 0.24, vel))
                }
            }
        }
        return build("PRELUDE IN C", bpm: 69, beats: 32, notes, sr)
    }

    /// Bach (attr. Petzold), Minuet in G major BWV Anh. 114, first 8 bars.
    private static func minuetInG(_ sr: Double) -> DemoSequence {
        var notes: [N] = []
        let melody: [[N]] = [
            [(0, 74, 0.9, 0.75), (1, 67, 0.45, 0.6), (1.5, 69, 0.45, 0.6),
             (2, 71, 0.45, 0.62), (2.5, 72, 0.45, 0.62)],
            [(0, 74, 0.9, 0.75), (1, 67, 0.9, 0.6), (2, 67, 0.9, 0.6)],
            [(0, 76, 0.9, 0.75), (1, 72, 0.45, 0.6), (1.5, 74, 0.45, 0.6),
             (2, 76, 0.45, 0.62), (2.5, 78, 0.45, 0.62)],
            [(0, 79, 0.9, 0.78), (1, 67, 0.9, 0.6), (2, 67, 0.9, 0.6)],
            [(0, 72, 0.9, 0.72), (1, 74, 0.45, 0.6), (1.5, 72, 0.45, 0.6),
             (2, 71, 0.45, 0.6), (2.5, 69, 0.45, 0.6)],
            [(0, 71, 0.9, 0.72), (1, 72, 0.45, 0.6), (1.5, 71, 0.45, 0.6),
             (2, 69, 0.45, 0.6), (2.5, 67, 0.45, 0.6)],
            [(0, 66, 0.9, 0.7), (1, 67, 0.45, 0.6), (1.5, 69, 0.45, 0.6),
             (2, 71, 0.45, 0.62), (2.5, 67, 0.45, 0.6)],
            [(0, 69, 2.7, 0.72)],
        ]
        let bass = [55, 59, 60, 55, 57, 55, 50, 50]
        for (bar, barNotes) in melody.enumerated() {
            let start = Double(bar) * 3
            for n in barNotes {
                notes.append((start + n.t, n.note, n.dur, n.vel))
            }
            notes.append((start, bass[bar], 2.7, 0.5))
        }
        return build("MINUET IN G", bpm: 116, beats: 24, notes, sr)
    }

    /// Mozart, Rondo alla Turca K. 331, opening phrase.
    private static func allaTurca(_ sr: Double) -> DemoSequence {
        var notes: [N] = []
        // Four 2-beat bars; each bar's pickup 16ths lead into the next bar
        // (bar 4's pickups loop back into bar 1).
        // (landing note, pickup 16ths)
        let bars: [(Int, [Int])] = [
            (72, [74, 72, 71, 72]),   // C5 | d c b c
            (76, [77, 76, 75, 76]),   // E5 | f e d# e
            (-1, [83, 81, 80, 81]),   // (all-16ths bar, first half)
            (84, [71, 69, 68, 69]),   // C6 | b a g# a -> loops to C5
        ]
        for (bar, (landing, pickups)) in bars.enumerated() {
            let start = Double(bar) * 2
            if landing >= 0 {
                notes.append((start, landing, bar == 3 ? 0.9 : 0.45, 0.8))
            } else {
                // Bar 3: b a g# a in the first half too.
                for (i, p) in [83, 81, 80, 81].enumerated() {
                    notes.append((start + Double(i) * 0.25, p, 0.22, 0.68))
                }
            }
            for (i, p) in pickups.enumerated() {
                notes.append((start + 1 + Double(i) * 0.25, p, 0.22, 0.68))
            }
        }
        // Left hand: alternating bass note and Am/E triad stabs.
        let lh: [(Double, [Int])] = [
            (0, [45]), (1, [57, 60, 64]),
            (2, [40]), (3, [56, 59, 64]),
            (4, [45]), (5, [57, 60, 64]),
            (6, [45]), (7, [52]),
        ]
        for (t, chord) in lh {
            for n in chord {
                notes.append((t, n, 0.4, chord.count > 1 ? 0.42 : 0.55))
            }
        }
        return build("ALLA TURCA", bpm: 130, beats: 8, notes, sr)
    }
}
