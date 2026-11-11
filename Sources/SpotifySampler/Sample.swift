import AVFoundation
import Foundation
import Observation

@Observable
final class Sample: Identifiable {
    let id = UUID()
    var name: String
    let sampleRate: Double
    /// Interleaved stereo float frames.
    let frames: [Float]
    let peaks: [Float]

    // Region (0...1 of the full sample) and playback params.
    var start: Double = 0
    var end: Double = 1
    var loop = false
    var reverse = false
    var semitones: Double = 0
    var gain: Double = 1

    var frameCount: Int { frames.count / 2 }
    var duration: Double { Double(frameCount) / sampleRate }
    var regionDuration: Double { duration * (end - start) / pow(2, semitones / 12) }

    init(name: String, sampleRate: Double, frames: [Float]) {
        self.name = name
        self.sampleRate = sampleRate
        self.frames = frames
        self.peaks = Sample.computePeaks(frames, buckets: 1200)
    }

    var isSilent: Bool { peaks.allSatisfy { $0 < 0.0001 } }

    static func computePeaks(_ frames: [Float], buckets: Int) -> [Float] {
        let n = frames.count / 2
        guard n > 0 else { return [] }
        let count = min(buckets, n)
        let per = Double(n) / Double(count)
        var out = [Float](repeating: 0, count: count)
        frames.withUnsafeBufferPointer { f in
            for b in 0..<count {
                let a = Int(Double(b) * per), z = min(Int(Double(b + 1) * per), n)
                var m: Float = 0
                var i = a
                while i < z {
                    m = max(m, abs(f[i * 2]), abs(f[i * 2 + 1]))
                    i += 1
                }
                out[b] = m
            }
        }
        return out
    }

    private var regionRange: (Int, Int) {
        let a = Int(start * Double(frameCount))
        let b = max(Int(end * Double(frameCount)), a + 1)
        return (a, min(b, frameCount))
    }

    /// Region rendered as deinterleaved stereo, reversed if needed, with short fades to avoid clicks.
    func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let (a, b) = regionRange
        let n = b - a
        guard n > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(n)
        let left = ch[0], right = ch[1]
        let fade = min(Int(sampleRate * 0.003), n / 2)
        let reverse = self.reverse
        frames.withUnsafeBufferPointer { f in
            for i in 0..<n {
                let src = reverse ? (b - 1 - i) : (a + i)
                var g: Float = 1
                if fade > 0 {
                    if i < fade { g = Float(i) / Float(fade) } else if i >= n - fade { g = Float(n - 1 - i) / Float(fade) }
                }
                left[i] = f[src * 2] * g
                right[i] = f[src * 2 + 1] * g
            }
        }
        return buffer
    }

    /// Writes the region as a 24-bit WAV with pitch (varispeed), reverse and gain baked in.
    func writeWAV(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        guard let region = makeBuffer(format: format) else { throw CocoaError(.fileWriteUnknown) }
        let rate = pow(2, semitones / 12)
        let inN = Int(region.frameLength)
        let outN = max(Int(Double(inN) / rate), 1)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outN))!
        out.frameLength = AVAudioFrameCount(outN)
        let g = Float(gain)
        for c in 0..<2 {
            let src = region.floatChannelData![c], dst = out.floatChannelData![c]
            for j in 0..<outN {
                let pos = Double(j) * rate
                let i0 = min(Int(pos), inN - 1), i1 = min(i0 + 1, inN - 1)
                let t = Float(pos - Double(i0))
                dst[j] = max(-1, min(1, (src[i0] * (1 - t) + src[i1] * t) * g))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: out)
    }

    var safeFileName: String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sample" : cleaned
    }
}
