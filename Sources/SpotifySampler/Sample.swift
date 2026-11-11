import AVFoundation
import Foundation
import Observation

/// Immutable captured audio. Several pads (e.g. chopped slices) can share one source.
final class AudioSource: Identifiable {
    let id: UUID
    let sampleRate: Double
    /// Interleaved stereo float frames.
    let frames: [Float]
    let mono: [Float]
    let peaks: [Float]
    let bpm: Double?
    let firstBeat: Double

    var frameCount: Int { frames.count / 2 }
    var duration: Double { Double(frameCount) / sampleRate }
    var isSilent: Bool { peaks.allSatisfy { $0 < 0.0001 } }

    init(id: UUID = UUID(), sampleRate: Double, frames: [Float]) {
        self.id = id
        self.sampleRate = sampleRate
        self.frames = frames
        mono = Analysis.mono(frames)
        peaks = Analysis.peaks(frames, from: 0, to: frames.count / 2, buckets: 1200)
        let tempo = Analysis.tempo(mono, sampleRate: sampleRate)
        bpm = tempo?.bpm
        firstBeat = tempo?.firstBeat ?? 0
    }

    /// Deinterleaved copy of frames [a, b), optionally reversed.
    func buffer(from a: Int, to b: Int, reverse: Bool, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = b - a
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let l = ch[0], r = ch[1]
        frames.withUnsafeBufferPointer { f in
            for i in 0..<n {
                let s = reverse ? (b - 1 - i) : (a + i)
                l[i] = f[s * 2]
                r[i] = f[s * 2 + 1]
            }
        }
        return buf
    }
}

enum PlayMode: String, Codable, CaseIterable, Identifiable {
    case oneShot = "One-shot", gate = "Gate"
    var id: String { rawValue }
}

enum PitchMode: String, Codable, CaseIterable, Identifiable {
    case varispeed = "Varispeed", stretch = "Time-stretch"
    var id: String { rawValue }
}

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case off = "Off", lowPass = "Low-pass", highPass = "High-pass"
    var id: String { rawValue }
}

/// Everything about a pad that is saved in a kit.
struct SampleParams: Codable, Equatable {
    var name: String
    var start = 0.0
    var end = 1.0
    var loop = false
    var reverse = false
    var semitones = 0.0
    var gain = 1.0
    var playMode = PlayMode.oneShot
    var choke = 0
    var pitchMode = PitchMode.varispeed
    var syncTempo = false
    var attack = 0.0 // ms
    var decay = 0.0 // ms
    var sustain = 1.0 // 0...1
    var release = 15.0 // ms
    var filter = FilterType.off
    var cutoff = 2000.0 // Hz
    var resonance = 0.3 // 0...1
}

@Observable
final class Sample: Identifiable {
    let id = UUID()
    let source: AudioSource
    var p: SampleParams

    init(source: AudioSource, params: SampleParams) {
        self.source = source
        p = params
    }

    var sampleRate: Double { source.sampleRate }
    var frameCount: Int { source.frameCount }
    var duration: Double { source.duration }

    var frameRange: (Int, Int) {
        let a = Int(p.start * Double(frameCount))
        let b = max(Int(p.end * Double(frameCount)), a + 1)
        return (min(a, frameCount - 1), min(b, frameCount))
    }

    /// Tempo-sync ratio to the project tempo (1 when not syncing or tempo unknown).
    func syncRatio(projectBPM: Double) -> Double {
        guard p.syncTempo, let bpm = source.bpm, bpm > 0 else { return 1 }
        return projectBPM / bpm
    }

    /// Overall playback speed (affects length).
    func speed(projectBPM: Double) -> Double {
        let sync = syncRatio(projectBPM: projectBPM)
        return p.pitchMode == .varispeed ? sync * pow(2, p.semitones / 12) : sync
    }

    func regionDuration(projectBPM: Double) -> Double {
        let (a, b) = frameRange
        return Double(b - a) / sampleRate / speed(projectBPM: projectBPM)
    }

    /// Region with envelope baked in (attack/decay/sustain + click-free edges).
    /// For loops, the envelope only shapes the first pass; `loopBody` is the sustained repeat.
    func makeBuffers(format: AVAudioFormat) -> (first: AVAudioPCMBuffer, loopBody: AVAudioPCMBuffer?)? {
        let (a, b) = frameRange
        guard let first = source.buffer(from: a, to: b, reverse: p.reverse, format: format) else { return nil }
        let n = Int(first.frameLength)
        let sr = sampleRate
        let edge = min(Int(sr * 0.003), n / 2)
        let atk = max(Int(p.attack / 1000 * sr), edge)
        let dec = Int(p.decay / 1000 * sr)
        let sus = Float(p.sustain)

        func env(_ i: Int) -> Float {
            if i < atk { return Float(i) / Float(max(atk, 1)) }
            if i < atk + dec { return 1 - (1 - sus) * Float(i - atk) / Float(max(dec, 1)) }
            return sus
        }
        for c in 0..<2 {
            let d = first.floatChannelData![c]
            for i in 0..<n {
                var g = env(i)
                if !p.loop, edge > 0, i >= n - edge { g *= Float(n - 1 - i) / Float(edge) }
                d[i] *= g
            }
        }
        guard p.loop else { return (first, nil) }

        // Loop body: sustain level, tiny crossfade-free edges to avoid a click at the seam.
        guard let body = source.buffer(from: a, to: b, reverse: p.reverse, format: format) else { return (first, nil) }
        for c in 0..<2 {
            let d = body.floatChannelData![c]
            for i in 0..<n {
                var g = sus
                if edge > 0 {
                    if i < edge { g *= Float(i) / Float(edge) } else if i >= n - edge { g *= Float(n - 1 - i) / Float(edge) }
                }
                d[i] *= g
            }
        }
        // First pass must also end cleanly into the loop.
        for c in 0..<2 {
            let d = first.floatChannelData![c]
            for i in max(n - edge, 0)..<n { d[i] *= Float(n - 1 - i) / Float(max(edge, 1)) }
        }
        return (first, body)
    }

    /// Snap a 0...1 position to the nearest zero crossing (~5 ms radius).
    func snapToZero(_ pos: Double) -> Double {
        let f = Int(pos * Double(frameCount))
        let z = Analysis.nearestZeroCrossing(source.mono, around: f, within: Int(sampleRate * 0.005))
        return Double(z) / Double(frameCount)
    }

    /// Snap a 0...1 position to the source's detected beat grid (1/4 beat resolution).
    func snapToBeat(_ pos: Double) -> Double {
        guard let bpm = source.bpm else { return pos }
        let grid = 60 / bpm / 4
        let t = pos * duration
        let snapped = source.firstBeat + ((t - source.firstBeat) / grid).rounded() * grid
        return min(max(snapped / duration, 0), 1)
    }

    var safeFileName: String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = p.name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sample" : cleaned
    }
}
