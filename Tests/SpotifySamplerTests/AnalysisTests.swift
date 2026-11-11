import AVFoundation
import XCTest
@testable import SpotifySampler

/// Synthetic drum-ish loop: decaying noise bursts on every beat, accent on the bar.
private func clickTrack(bpm: Double, seconds: Double, rate: Double = 48_000) -> [Float] {
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n * 2)
    let beat = Int(60 / bpm * rate)
    var seed: UInt32 = 1
    var b = 0
    for start in stride(from: 0, to: n, by: beat) {
        let amp: Float = b % 4 == 0 ? 0.9 : 0.6
        for i in 0..<min(Int(0.08 * rate), n - start) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(1 << 24) * 2 - 1
            let v = noise * amp * exp(-Float(i) / Float(0.015 * rate))
            out[(start + i) * 2] = v
            out[(start + i) * 2 + 1] = v
        }
        b += 1
    }
    return out
}

final class AnalysisTests: XCTestCase {
    override class func setUp() {
        setenv("SPOTIFY_SAMPLER_DATA_DIR", NSTemporaryDirectory() + "sampler-test-\(UUID().uuidString)", 1)
    }

    func testTempoDetection() throws {
        for bpm in [92.0, 128.0, 140.0] {
            let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: bpm, seconds: 8))
            let detected = try XCTUnwrap(source.bpm, "no tempo for \(bpm)")
            XCTAssertEqual(detected, bpm, accuracy: 1.5, "expected \(bpm), got \(detected)")
        }
    }

    func testTransientsFindEachHit() {
        let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: 120, seconds: 4))
        let onsets = Analysis.onsets(source.mono, sampleRate: 48_000, sensitivity: 0.5)
        XCTAssertEqual(onsets.count, 8, accuracy: 1, "onsets: \(onsets)")
    }

    @MainActor
    func testOfflineRenderRespectsPitch() throws {
        let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: 120, seconds: 2))
        var params = SampleParams(name: "t")
        params.semitones = 12 // varispeed up an octave = half length
        let up = try SamplerEngine.renderOffline(Sample(source: source, params: params), projectBPM: 120)
        params.semitones = 0
        let flat = try SamplerEngine.renderOffline(Sample(source: source, params: params), projectBPM: 120)
        XCTAssertEqual(Double(up.frameLength) / Double(flat.frameLength), 0.5, accuracy: 0.05)
    }

    @MainActor
    func testTimeStretchSync() throws {
        let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: 100, seconds: 6))
        var params = SampleParams(name: "t")
        params.pitchMode = .stretch
        params.syncTempo = true
        let s = Sample(source: source, params: params)
        XCTAssertEqual(s.syncRatio(projectBPM: 125), 1.25, accuracy: 0.03)
        let out = try SamplerEngine.renderOffline(s, projectBPM: 125)
        XCTAssertEqual(Double(out.frameLength) / 48_000, 6 / 1.25, accuracy: 0.3)
    }

    func testKitRoundTrip() throws {
        let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: 120, seconds: 1))
        var p = SampleParams(name: "Kick")
        p.start = 0.25; p.choke = 2; p.playMode = .gate
        let a = Sample(source: source, params: p)
        let b = Sample(source: source, params: SampleParams(name: "Slice 2"))
        let id = "test-\(UUID().uuidString)"
        defer { KitStore.delete(id) }
        var pads: [Sample?] = Array(repeating: nil, count: 16)
        pads[0] = a; pads[5] = b
        try KitStore.save(KitStore.encode(name: "Test", bpm: 97, pads: pads), sources: [source], id: id)
        let loaded = try KitStore.load(id)
        XCTAssertEqual(loaded.name, "Test")
        XCTAssertEqual(loaded.bpm, 97)
        XCTAssertEqual(loaded.pads[0]?.p, p)
        XCTAssertEqual(loaded.pads[5]?.p.name, "Slice 2")
        XCTAssert(loaded.pads[0]?.source === loaded.pads[5]?.source, "slices should share one source")
        XCTAssertEqual(loaded.pads[0]?.source.frames.count, source.frames.count)
    }

    func testMIDIMapping() {
        XCTAssertEqual(MIDIInput.padIndex(for: 36), 12) // C1 → bottom-left
        XCTAssertEqual(MIDIInput.padIndex(for: 39), 15)
        XCTAssertEqual(MIDIInput.padIndex(for: 48), 0)  // top-left
        XCTAssertEqual(MIDIInput.padIndex(for: 52), 12) // wraps
    }

    func testZeroCrossingSnap() {
        let source = AudioSource(sampleRate: 48_000, frames: clickTrack(bpm: 120, seconds: 1))
        let s = Sample(source: source, params: SampleParams(name: "z"))
        let snapped = Int(s.snapToZero(0.01) * Double(s.frameCount))
        let m = source.mono
        XCTAssert(snapped == 0 || m[snapped - 1].sign != m[snapped].sign || m[snapped] == 0)
    }
}

final class PadModeTests: XCTestCase {
    override class func setUp() {
        setenv("SPOTIFY_SAMPLER_DATA_DIR", NSTemporaryDirectory() + "sampler-test-\(UUID().uuidString)", 1)
    }

    @MainActor
    func testMonoStopsOtherPadsPolyLayers() async throws {
        let model = AppModel()
        let previous = model.monoPads
        defer { model.monoPads = previous }
        var quiet = SampleParams(name: "a")
        quiet.gain = 0
        let source = AudioSource(sampleRate: 48_000, frames: [Float](repeating: 0, count: 96_000 * 2))
        let a = Sample(source: source, params: quiet), b = Sample(source: source, params: quiet)
        model.pads[0] = a
        model.pads[1] = b

        model.monoPads = true
        model.trigger(0)
        model.trigger(1)
        try await Task.sleep(for: .milliseconds(150)) // > release fade
        XCTAssertFalse(model.playing.contains(a.id), "mono: pad 1 should stop pad 0")
        XCTAssertTrue(model.playing.contains(b.id))

        model.monoPads = false
        model.trigger(0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.playing.contains(a.id) && model.playing.contains(b.id), "poly: both should play")
    }
}

final class PadMoveTests: XCTestCase {
    override class func setUp() {
        setenv("SPOTIFY_SAMPLER_DATA_DIR", NSTemporaryDirectory() + "sampler-test-\(UUID().uuidString)", 1)
    }

    @MainActor
    func testMoveSwapCopy() {
        let model = AppModel()
        let source = AudioSource(sampleRate: 48_000, frames: [Float](repeating: 0, count: 4_800))
        let a = Sample(source: source, params: SampleParams(name: "A"))
        let b = Sample(source: source, params: SampleParams(name: "B"))
        model.pads = Array(repeating: nil, count: 16)
        model.pads[0] = a
        model.pads[1] = b

        model.movePad(from: 0, to: 5, copy: false) // into empty slot
        XCTAssertNil(model.pads[0]); XCTAssert(model.pads[5] === a); XCTAssertEqual(model.selectedPad, 5)

        model.movePad(from: 5, to: 1, copy: false) // onto filled slot = swap
        XCTAssert(model.pads[1] === a); XCTAssert(model.pads[5] === b)

        model.movePad(from: 1, to: 9, copy: true) // option-drop = duplicate
        XCTAssert(model.pads[1] === a)
        XCTAssertEqual(model.pads[9]?.p.name, "A")
        XCTAssert(model.pads[9] !== a && model.pads[9]?.source === a.source)

        let provider = model.dragProvider(for: 1)
        XCTAssert(provider.hasItemConformingToTypeIdentifier(AppModel.padDragType))
        XCTAssert(provider.hasItemConformingToTypeIdentifier("public.file-url"), "still drags a WAV to other apps")
    }
}
