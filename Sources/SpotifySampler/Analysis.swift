import Foundation

/// Offline analysis on interleaved stereo audio: transients, tempo, zero crossings, overview peaks.
enum Analysis {
    static let hop = 512

    static func mono(_ frames: [Float]) -> [Float] {
        let n = frames.count / 2
        var out = [Float](repeating: 0, count: n)
        frames.withUnsafeBufferPointer { f in
            for i in 0..<n { out[i] = (f[i * 2] + f[i * 2 + 1]) * 0.5 }
        }
        return out
    }

    /// Onset-strength envelope (one value per hop): positive change in log energy of a
    /// pre-emphasised signal, which reacts strongly to drum hits and consonants.
    static func onsetEnvelope(_ mono: [Float]) -> [Float] {
        let hops = mono.count / hop
        guard hops > 2 else { return [] }
        var logE = [Float](repeating: 0, count: hops)
        mono.withUnsafeBufferPointer { m in
            var prev: Float = 0
            for k in 0..<hops {
                var e: Float = 0
                let base = k * hop
                for i in 0..<hop {
                    let x = m[base + i]
                    let d = x - prev // first-difference high-pass emphasises transients
                    prev = x
                    e += d * d + 0.25 * x * x
                }
                logE[k] = log10(1e-9 + e)
            }
        }
        var env = [Float](repeating: 0, count: hops)
        for k in 1..<hops { env[k] = max(0, logE[k] - logE[k - 1]) }
        return env
    }

    /// Transient positions in frames. `sensitivity` 0...1 (higher = more slices).
    static func onsets(_ mono: [Float], sampleRate: Double, sensitivity: Double,
                       range: Range<Int>? = nil) -> [Int] {
        let env = onsetEnvelope(mono)
        guard env.count > 8 else { return [] }
        let w = 10
        let minGap = Int(0.07 * sampleRate) / hop
        let mean = env.reduce(0, +) / Float(env.count)
        let globalStd = sqrt(env.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(env.count))
        let delta = Float(1.6 - 1.4 * sensitivity) * globalStd

        var picks: [Int] = []
        var last = -minGap - 1
        for k in 1..<(env.count - 1) {
            let a = max(0, k - w), b = min(env.count, k + w + 1)
            var localMax: Float = 0, localSum: Float = 0
            for j in a..<b { localMax = max(localMax, env[j]); localSum += env[j] }
            let localMean = localSum / Float(b - a)
            if env[k] == localMax, env[k] > localMean + delta, k - last > minGap {
                picks.append(k)
                last = k
            }
        }
        // Back off a touch so the slice starts just before the hit, then land on a zero crossing.
        return picks.map { k in
            let f = max(0, (k - 1) * hop)
            return nearestZeroCrossing(mono, around: f, within: hop)
        }.filter { f in range.map { $0.contains(f) } ?? true }
    }

    /// Tempo estimate via autocorrelation of the onset envelope. Returns (bpm, first beat in seconds).
    static func tempo(_ mono: [Float], sampleRate: Double) -> (bpm: Double, firstBeat: Double)? {
        guard Double(mono.count) / sampleRate >= 3 else { return nil }
        let env = onsetEnvelope(mono)
        let hopsPerSec = sampleRate / Double(hop)
        let minLag = Int(hopsPerSec * 60 / 200), maxLag = Int(hopsPerSec * 60 / 60)
        guard env.count > maxLag * 2 else { return nil }

        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var s: Double = 0
            for k in 0..<(env.count - lag) { s += Double(env[k] * env[k + lag]) }
            s /= Double(env.count - lag)
            // Prefer tempos near 120 bpm (log-gaussian prior) to avoid half/double-time picks.
            let bpm = 60 * hopsPerSec / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            scores[lag] = s * prior
        }
        guard let best = (minLag...maxLag).max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        // Parabolic interpolation for sub-hop precision.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denom = a - 2 * b + c
            if denom != 0 { lag += 0.5 * (a - c) / denom }
        }
        var bpm = 60 * hopsPerSec / lag
        while bpm < 75 { bpm *= 2 }
        while bpm > 165 { bpm /= 2 }
        bpm = (bpm * 10).rounded() / 10

        // Phase: grid offset that lines up with the most onset energy.
        let period = 60 * hopsPerSec / bpm
        var bestOffset = 0, bestSum: Float = -1
        for offset in 0..<max(Int(period), 1) {
            var sum: Float = 0
            var t = Double(offset)
            while Int(t) < env.count { sum += env[Int(t)]; t += period }
            if sum > bestSum { bestSum = sum; bestOffset = offset }
        }
        return (bpm, Double(bestOffset * hop) / sampleRate)
    }

    static func nearestZeroCrossing(_ mono: [Float], around frame: Int, within radius: Int) -> Int {
        guard mono.count > 2 else { return frame }
        let f = min(max(frame, 1), mono.count - 1)
        for d in 0...radius {
            for i in [f - d, f + d] where i > 0 && i < mono.count {
                if (mono[i - 1] <= 0 && mono[i] > 0) || (mono[i - 1] >= 0 && mono[i] < 0) { return i }
            }
        }
        return f
    }

    /// Max-abs overview of frames [a, b) into `buckets` columns.
    static func peaks(_ frames: [Float], from a: Int, to b: Int, buckets: Int) -> [Float] {
        let n = b - a
        guard n > 0, buckets > 0 else { return [] }
        let count = min(buckets, n)
        let per = Double(n) / Double(count)
        let step = max(Int(per) / 64, 1)
        var out = [Float](repeating: 0, count: count)
        frames.withUnsafeBufferPointer { f in
            for c in 0..<count {
                let s = a + Int(Double(c) * per), e = min(a + Int(Double(c + 1) * per), b)
                var m: Float = 0
                var i = s
                while i < e {
                    m = max(m, abs(f[i * 2]), abs(f[i * 2 + 1]))
                    i += step
                }
                out[c] = m
            }
        }
        return out
    }
}
