import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    static let padKeys: [Character] = Array("1234qwerasdfzxcv")
    static let historySeconds: Double = 120

    // Pads
    var pads: [Sample?] = Array(repeating: nil, count: 16)
    var selectedPad = 0
    var selected: Sample? { pads[selectedPad] }
    var playing: Set<UUID> = []

    // Capture state
    var connected = false
    var status = "Looking for Spotify…"
    var hint: String?
    var level: Float = 0
    var livePeaks: [Float] = []
    var nowPlaying = ""
    var grabSeconds: Double = 8
    var isRecording = false
    var recordSeconds: Double = 0

    @ObservationIgnored let sampler = SamplerEngine()
    @ObservationIgnored private let tap = SpotifyTap()
    @ObservationIgnored private var ring: RingBuffer?
    @ObservationIgnored private var recordStart: Int64 = 0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var silentTicks = 0
    @ObservationIgnored private var sampleCounter = 0

    static let exportFolder: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("Spotify Sampler", isDirectory: true)
    }()

    init() {
        sampler.onFinished = { [weak self] id in self?.playing.remove(id) }
        refreshConnection()
        refreshNowPlaying()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshConnection() }
            },
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNowPlaying() }
            },
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
    }

    // MARK: Capture

    func refreshConnection() {
        let processes = CoreAudioUtils.spotifyProcessObjects()
        let outputUID = (try? CoreAudioUtils.defaultOutputDeviceUID()) ?? ""

        guard !processes.isEmpty else {
            if tap.isRunning { tap.stop() }
            connected = false
            let open = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
            status = open ? "Spotify is open — press play" : "Open Spotify to start sampling"
            return
        }
        if tap.isRunning, processes == tap.processes, outputUID == tap.outputUID { return }

        do {
            let existing = ring
            let newRing = try tap.start(processes: processes, outputUID: outputUID) { rate in
                if let existing, existing.sampleRate == rate { return existing }
                return RingBuffer(seconds: Self.historySeconds, sampleRate: rate)
            }
            if newRing !== ring, isRecording { isRecording = false }
            ring = newRing
            connected = true
            status = "Listening to Spotify"
        } catch {
            connected = false
            status = error.localizedDescription
        }
    }

    private func tick() {
        guard let ring else {
            level = 0
            livePeaks = []
            return
        }
        level = max(ring.takePeak(), level * 0.85)
        livePeaks = ring.peaks(lastFrames: Int(grabSeconds * ring.sampleRate), buckets: 280)
        if isRecording {
            recordSeconds = Double(ring.totalFrames - recordStart) / ring.sampleRate
            if recordSeconds >= Self.historySeconds - 2 { toggleRecording() }
        }
        // Spotify says it's playing but we hear nothing → almost certainly a permission issue.
        if connected, !nowPlaying.isEmpty, level < 0.0001 {
            silentTicks += 1
            if silentTicks > 120 {
                hint = "Spotify is playing but no audio is reaching the app. Allow it under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only), then relaunch."
            }
        } else {
            silentTicks = 0
            hint = nil
        }
    }

    private func refreshNowPlaying() {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            nowPlaying = ""
            return
        }
        let source = """
        tell application "Spotify"
            if player state is playing then return (name of current track) & " — " & (artist of current track)
        end tell
        return ""
        """
        var error: NSDictionary?
        nowPlaying = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
    }

    func grab() {
        guard let ring else { return }
        addSample(ring.latest(frames: Int(grabSeconds * ring.sampleRate)), rate: ring.sampleRate)
    }

    func toggleRecording() {
        guard let ring else { return }
        if isRecording {
            isRecording = false
            addSample(ring.copy(from: recordStart, to: ring.totalFrames), rate: ring.sampleRate)
        } else {
            recordStart = ring.totalFrames
            recordSeconds = 0
            isRecording = true
        }
    }

    private func addSample(_ frames: [Float], rate: Double) {
        guard frames.count > 64 else {
            hint = "Nothing captured yet — play something in Spotify first."
            return
        }
        sampleCounter += 1
        let name = nowPlaying.isEmpty ? "Sample \(sampleCounter)" : nowPlaying
        let sample = Sample(name: name, sampleRate: rate, frames: frames)
        let slot = pads.firstIndex(where: { $0 == nil }) ?? selectedPad
        if let old = pads[slot] { sampler.remove(old) }
        pads[slot] = sample
        selectedPad = slot
        if sample.isSilent {
            hint = "That capture was silent. If Spotify was playing, check the System Audio Recording permission."
        }
    }

    // MARK: Pads

    func trigger(_ index: Int) {
        selectedPad = index
        guard let sample = pads[index] else { return }
        if sample.loop, playing.contains(sample.id) {
            stop(sample)
        } else {
            play(sample)
        }
    }

    func play(_ sample: Sample) {
        sampler.play(sample)
        playing.insert(sample.id)
    }

    func stop(_ sample: Sample) {
        sampler.stop(sample)
        playing.remove(sample.id)
    }

    func togglePlay(_ sample: Sample) {
        playing.contains(sample.id) ? stop(sample) : play(sample)
    }

    func delete(_ index: Int) {
        guard let sample = pads[index] else { return }
        sampler.remove(sample)
        playing.remove(sample.id)
        pads[index] = nil
    }

    // MARK: Export

    @discardableResult
    func export(_ sample: Sample, reveal: Bool = true) -> URL? {
        do {
            try FileManager.default.createDirectory(at: Self.exportFolder, withIntermediateDirectories: true)
            var url = Self.exportFolder.appendingPathComponent("\(sample.safeFileName).wav")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = Self.exportFolder.appendingPathComponent("\(sample.safeFileName) \(n).wav")
                n += 1
            }
            try sample.writeWAV(to: url)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return url
        } catch {
            hint = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Drag a pad straight into Finder, Ableton, Logic, etc.
    func dragProvider(for index: Int) -> NSItemProvider {
        guard let sample = pads[index] else { return NSItemProvider() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpotifySamplerDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sample.safeFileName).wav")
        try? FileManager.default.removeItem(at: url)
        guard (try? sample.writeWAV(to: url)) != nil else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if NSApp.keyWindow?.firstResponder is NSTextView { return event }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
        switch event.keyCode {
        case 36: grab(); return nil // Return
        case 49: if let s = selected { togglePlay(s) }; return nil // Space
        case 51: delete(selectedPad); return nil // Delete
        default: break
        }
        if let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let index = Self.padKeys.firstIndex(of: ch) {
            if !event.isARepeat { trigger(index) }
            return nil
        }
        return event
    }
}
