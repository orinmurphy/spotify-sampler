import CoreAudio
import Foundation
import os

/// Rolling stereo history of everything Spotify has played (interleaved L/R floats).
/// Single writer (the Core Audio IO thread), readers on the main thread.
final class RingBuffer: @unchecked Sendable {
    let sampleRate: Double
    let capacity: Int // frames

    private var data: [Float]
    private var written: Int64 = 0
    private var peak: Float = 0
    private let lock = OSAllocatedUnfairLock()

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(seconds * sampleRate)
        data = [Float](repeating: 0, count: capacity * 2)
    }

    var totalFrames: Int64 { lock.withLock { written } }

    /// Audio thread: append a Float32 buffer list (interleaved or planar).
    func write(_ abl: UnsafeMutableAudioBufferListPointer) {
        guard abl.count > 0, let p0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let stride: Int
        let frames: Int
        if abl.count >= 2, let p1 = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            left = UnsafePointer(p0)
            right = UnsafePointer(p1)
            stride = 1
            frames = Int(min(abl[0].mDataByteSize, abl[1].mDataByteSize)) / MemoryLayout<Float>.size
        } else {
            stride = max(Int(abl[0].mNumberChannels), 1)
            frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size / stride
            left = UnsafePointer(p0)
            right = stride > 1 ? UnsafePointer(p0 + 1) : UnsafePointer(p0)
        }
        guard frames > 0 else { return }

        lock.withLock {
            var w = Int(written % Int64(capacity))
            var pk: Float = 0
            let cap = capacity
            data.withUnsafeMutableBufferPointer { d in
                for i in 0..<frames {
                    let l = left[i * stride], r = right[i * stride]
                    d[w &* 2] = l
                    d[w &* 2 &+ 1] = r
                    pk = max(pk, abs(l), abs(r))
                    w &+= 1
                    if w == cap { w = 0 }
                }
            }
            written += Int64(frames)
            peak = max(peak, pk)
        }
    }

    /// Peak since the last call (for the level meter).
    func takePeak() -> Float {
        lock.withLock {
            let p = peak
            peak = 0
            return p
        }
    }

    /// Copy absolute frame range [start, end) out as interleaved stereo.
    func copy(from startFrame: Int64, to endFrame: Int64) -> [Float] {
        lock.withLock {
            let end = min(endFrame, written)
            let start = max(startFrame, written - Int64(capacity), 0)
            guard end > start else { return [] }
            let n = Int(end - start)
            var out = [Float](repeating: 0, count: n * 2)
            var r = Int(start % Int64(capacity))
            data.withUnsafeBufferPointer { d in
                out.withUnsafeMutableBufferPointer { o in
                    for i in 0..<n {
                        o[i * 2] = d[r * 2]
                        o[i * 2 + 1] = d[r * 2 + 1]
                        r += 1
                        if r == capacity { r = 0 }
                    }
                }
            }
            return out
        }
    }

    func latest(frames: Int) -> [Float] {
        let w = totalFrames
        return copy(from: w - Int64(frames), to: w)
    }

    /// Cheap overview of the last `frames` frames for the live view.
    func peaks(lastFrames frames: Int, buckets: Int) -> [Float] {
        lock.withLock {
            var out = [Float](repeating: 0, count: buckets)
            guard frames > 0, buckets > 0 else { return out }
            let perBucket = max(frames / buckets, 1)
            let step = max(perBucket / 96, 1)
            let startAbs = written - Int64(frames)
            let oldest = max(written - Int64(capacity), 0)
            data.withUnsafeBufferPointer { d in
                for b in 0..<buckets {
                    let bStart = startAbs + Int64(b * perBucket)
                    var m: Float = 0
                    var f = 0
                    while f < perBucket {
                        let abs64 = bStart + Int64(f)
                        if abs64 >= oldest && abs64 < written {
                            let idx = Int(abs64 % Int64(capacity)) * 2
                            m = max(m, abs(d[idx]), abs(d[idx + 1]))
                        }
                        f += step
                    }
                    out[b] = m
                }
            }
            return out
        }
    }
}
