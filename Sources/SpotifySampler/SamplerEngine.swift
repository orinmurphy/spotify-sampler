import AVFoundation
import Foundation

/// Plays pads: one player + varispeed per sample, all into the main mixer.
@MainActor
final class SamplerEngine {
    private struct Voice {
        let player: AVAudioPlayerNode
        let varispeed: AVAudioUnitVarispeed
        var generation = 0
    }

    private let engine = AVAudioEngine()
    private var voices: [UUID: Voice] = [:]
    var onFinished: ((UUID) -> Void)?

    init() {
        _ = engine.mainMixerNode
        engine.prepare()
    }

    func play(_ sample: Sample) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sample.sampleRate, channels: 2)!
        guard let buffer = sample.makeBuffer(format: format) else { return }
        var voice = voice(for: sample, format: format)
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Engine start failed: \(error)"); return }
        }
        voice.player.stop()
        voice.generation += 1
        voices[sample.id] = voice
        apply(sample, to: voice)

        let id = sample.id
        let generation = voice.generation
        voice.player.scheduleBuffer(buffer, at: nil, options: sample.loop ? [.loops] : [],
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.voices[id]?.generation == generation else { return }
                self.onFinished?(id)
            }
        }
        voice.player.play()
    }

    func stop(_ sample: Sample) {
        guard var voice = voices[sample.id] else { return }
        voice.generation += 1
        voices[sample.id] = voice
        voice.player.stop()
    }

    /// Live-update pitch/gain while a pad is playing.
    func update(_ sample: Sample) {
        if let voice = voices[sample.id] { apply(sample, to: voice) }
    }

    func remove(_ sample: Sample) {
        guard let voice = voices.removeValue(forKey: sample.id) else { return }
        voice.player.stop()
        engine.detach(voice.player)
        engine.detach(voice.varispeed)
    }

    private func apply(_ sample: Sample, to voice: Voice) {
        voice.varispeed.rate = Float(pow(2, sample.semitones / 12))
        voice.player.volume = Float(sample.gain)
    }

    private func voice(for sample: Sample, format: AVAudioFormat) -> Voice {
        if let v = voices[sample.id] { return v }
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        engine.attach(player)
        engine.attach(varispeed)
        engine.connect(player, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        let v = Voice(player: player, varispeed: varispeed)
        voices[sample.id] = v
        return v
    }
}
