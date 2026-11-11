import AVFoundation
import Foundation

/// Plays pads. Each sample gets a voice: player → varispeed → time-pitch → filter → mixer.
@MainActor
final class SamplerEngine {
    private struct Voice {
        let player: AVAudioPlayerNode
        let varispeed: AVAudioUnitVarispeed
        let timePitch: AVAudioUnitTimePitch
        let eq: AVAudioUnitEQ
        var generation = 0
        var baseVolume: Float = 1
        var releasing = false
    }

    private let engine = AVAudioEngine()
    private var voices: [UUID: Voice] = [:]
    private var releaseTimers: [UUID: Timer] = [:]
    var projectBPM: Double = 120
    var onFinished: ((UUID) -> Void)?

    init() {
        _ = engine.mainMixerNode
        engine.prepare()
    }

    func play(_ sample: Sample, velocity: Float = 1) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sample.sampleRate, channels: 2)!
        guard let buffers = sample.makeBuffers(format: format) else { return }
        var voice = voice(for: sample, format: format)
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Engine start failed: \(error)"); return }
        }
        releaseTimers.removeValue(forKey: sample.id)?.invalidate()
        voice.player.stop()
        voice.generation += 1
        voice.baseVolume = Float(sample.p.gain) * velocity
        voice.releasing = false
        voices[sample.id] = voice
        Self.configure(sample, player: voice.player, varispeed: voice.varispeed, timePitch: voice.timePitch,
                       eq: voice.eq, projectBPM: projectBPM)
        voice.player.volume = voice.baseVolume

        let id = sample.id, generation = voice.generation
        let done: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.voices[id]?.generation == generation else { return }
                self.onFinished?(id)
            }
        }
        if let body = buffers.loopBody {
            voice.player.scheduleBuffer(buffers.first, completionHandler: nil)
            voice.player.scheduleBuffer(body, at: nil, options: [.loops], completionCallbackType: .dataPlayedBack, completionHandler: done)
        } else {
            voice.player.scheduleBuffer(buffers.first, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: done)
        }
        voice.player.play()
    }

    /// Fade out over the sample's release time, then stop.
    func release(_ sample: Sample) {
        guard var voice = voices[sample.id], !voice.releasing, voice.player.isPlaying else {
            stopNow(sample)
            return
        }
        voice.releasing = true
        voices[sample.id] = voice
        let generation = voice.generation
        let total = max(sample.p.release / 1000, 0.005)
        let start = Date()
        let from = voice.player.volume
        let player = voice.player
        let timer = Timer(timeInterval: 1.0 / 200, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.voices[sample.id]?.generation == generation else { t.invalidate(); return }
                let k = Date().timeIntervalSince(start) / total
                if k >= 1 {
                    t.invalidate()
                    self.stopNow(sample)
                } else {
                    player.volume = from * Float(1 - k)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimers[sample.id] = timer
    }

    func stopNow(_ sample: Sample) {
        releaseTimers.removeValue(forKey: sample.id)?.invalidate()
        guard var voice = voices[sample.id] else { return }
        voice.generation += 1
        voice.releasing = false
        voices[sample.id] = voice
        voice.player.stop()
        onFinished?(sample.id)
    }

    /// Live-update parameters while a pad is playing.
    func update(_ sample: Sample) {
        guard var voice = voices[sample.id] else { return }
        Self.configure(sample, player: voice.player, varispeed: voice.varispeed, timePitch: voice.timePitch,
                       eq: voice.eq, projectBPM: projectBPM)
        if !voice.releasing {
            voice.baseVolume = Float(sample.p.gain)
            voice.player.volume = voice.baseVolume
            voices[sample.id] = voice
        }
    }

    func remove(_ sample: Sample) {
        releaseTimers.removeValue(forKey: sample.id)?.invalidate()
        guard let voice = voices.removeValue(forKey: sample.id) else { return }
        voice.player.stop()
        [voice.player, voice.varispeed, voice.timePitch, voice.eq].forEach { engine.detach($0) }
    }

    private func voice(for sample: Sample, format: AVAudioFormat) -> Voice {
        if let v = voices[sample.id] { return v }
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        Self.chain(engine, player, varispeed, timePitch, eq, format: format)
        let v = Voice(player: player, varispeed: varispeed, timePitch: timePitch, eq: eq)
        voices[sample.id] = v
        return v
    }

    private static func chain(_ engine: AVAudioEngine, _ player: AVAudioPlayerNode, _ vs: AVAudioUnitVarispeed,
                              _ tp: AVAudioUnitTimePitch, _ eq: AVAudioUnitEQ, format: AVAudioFormat) {
        [player, vs, tp, eq].forEach { engine.attach($0) }
        engine.connect(player, to: vs, format: format)
        engine.connect(vs, to: tp, format: format)
        engine.connect(tp, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
    }

    static func configure(_ s: Sample, player: AVAudioPlayerNode, varispeed: AVAudioUnitVarispeed,
                          timePitch: AVAudioUnitTimePitch, eq: AVAudioUnitEQ, projectBPM: Double) {
        let sync = s.syncRatio(projectBPM: projectBPM)
        switch s.p.pitchMode {
        case .varispeed:
            varispeed.rate = Float(sync * pow(2, s.p.semitones / 12))
            timePitch.rate = 1
            timePitch.pitch = 0
            timePitch.bypass = true
        case .stretch:
            varispeed.rate = 1
            timePitch.bypass = false
            timePitch.rate = Float(min(max(sync, 1.0 / 32), 32))
            timePitch.pitch = Float(s.p.semitones * 100)
        }
        let band = eq.bands[0]
        band.bypass = s.p.filter == .off
        band.filterType = s.p.filter == .highPass ? .resonantHighPass : .resonantLowPass
        band.frequency = Float(min(max(s.p.cutoff, 20), 20_000))
        band.bandwidth = Float(2.0 - 1.9 * s.p.resonance) // resonance: wider → smoother
        band.gain = 0
    }

    /// Renders the pad exactly as it sounds (pitch/stretch/filter/envelope) for export.
    static func renderOffline(_ sample: Sample, projectBPM: Double) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sample.sampleRate, channels: 2)!
        var copy = sample.p
        copy.loop = false
        let oneShot = Sample(source: sample.source, params: copy)
        guard let input = oneShot.makeBuffers(format: format)?.first else { throw CocoaError(.fileWriteUnknown) }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode(), vs = AVAudioUnitVarispeed(), tp = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        chain(engine, player, vs, tp, eq, format: format)
        configure(oneShot, player: player, varispeed: vs, timePitch: tp, eq: eq, projectBPM: projectBPM)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.volume = Float(sample.p.gain)
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        // Exact output length (so loops stay loop-length), skipping the processing latency up front.
        let speed = oneShot.speed(projectBPM: projectBPM)
        let wanted = AVAudioFrameCount(max(Double(input.frameLength) / speed, 1))
        let latency = [vs.auAudioUnit, tp.auAudioUnit, eq.auAudioUnit].reduce(0) { $0 + $1.latency }
        var skip = Int(latency * sample.sampleRate)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted)!
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var guardCount = 0
        while out.frameLength < wanted, guardCount < 100_000 {
            guardCount += 1
            let status = try engine.renderOffline(4096, to: chunk)
            guard status == .success else { break }
            let got = Int(chunk.frameLength)
            let drop = min(skip, got)
            skip -= drop
            let take = min(got - drop, Int(wanted - out.frameLength))
            if take > 0 {
                for c in 0..<2 {
                    memcpy(out.floatChannelData![c] + Int(out.frameLength), chunk.floatChannelData![c] + drop,
                           take * MemoryLayout<Float>.size)
                }
                out.frameLength += AVAudioFrameCount(take)
            }
        }
        engine.stop()

        let fade = min(Int(sample.p.release / 1000 * sample.sampleRate), Int(out.frameLength))
        for c in 0..<2 {
            let d = out.floatChannelData![c]
            let len = Int(out.frameLength)
            for i in 0..<len {
                var v = d[i]
                if fade > 0, i >= len - fade { v *= Float(len - 1 - i) / Float(fade) }
                d[i] = max(-1, min(1, v))
            }
        }
        return out
    }

    static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
