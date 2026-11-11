import AppKit
import Foundation
import Observation

enum SnapMode: String, CaseIterable, Identifiable {
    case off = "Off", zero = "Zero-cross", beat = "Beat"
    var id: String { rawValue }
}

@Observable
@MainActor
final class AppModel {
    static let padKeys: [Character] = Array("1234qwerasdfzxcv")
    static let historySeconds: Double = 120

    // Pads / kit
    var pads: [Sample?] = Array(repeating: nil, count: 16)
    var selectedPad = 0
    var selected: Sample? { pads[selectedPad] }
    var playing: Set<UUID> = []
    var kitID = ""
    var kitName = "Kit 1"
    var kits: [KitInfo] = []
    var projectBPM: Double = 120 { didSet { sampler.projectBPM = projectBPM; pads.compactMap { $0 }.forEach(sampler.update) } }

    /// Mono: hitting a pad stops whatever else is playing (best for chopped songs).
    /// Off = pads overlap (drum-kit style); choke groups still apply.
    var monoPads = UserDefaults.standard.object(forKey: "monoPads") as? Bool ?? true {
        didSet { UserDefaults.standard.set(monoPads, forKey: "monoPads") }
    }

    // Editing
    var snap: SnapMode = .zero
    var chopSensitivity = 0.5

    // Capture
    var connected = false
    var status = "Looking for Spotify…"
    var hint: String?
    var level: Float = 0
    var livePeaks: [Float] = []
    var nowPlaying = ""
    var grabSeconds: Double = 8
    var isRecording = false
    var recordSeconds: Double = 0

    // MIDI
    var midiSources: [String] = []
    var lastMIDINote: UInt8?

    let stems = StemSeparator()
    @ObservationIgnored let sampler = SamplerEngine()
    @ObservationIgnored private let tap = SpotifyTap()
    @ObservationIgnored private let midi = MIDIInput()
    @ObservationIgnored private var ring: RingBuffer?
    @ObservationIgnored private var recordStart: Int64 = 0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var silentTicks = 0
    @ObservationIgnored private var sampleCounter = 0
    @ObservationIgnored private var lastSaved: Data?
    @ObservationIgnored private var heldKeys: [UInt16: Int] = [:]
    @ObservationIgnored private var keyEventsSeen = 0

    static let exportFolder: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("Spotify Sampler", isDirectory: true)
    }()

    init() {
        sampler.onFinished = { [weak self] id in self?.playing.remove(id) }
        restoreLastKit()
        refreshConnection()
        refreshNowPlaying()

        midi.onSourcesChanged = { [weak self] names in self?.midiSources = names }
        midi.onNote = { [weak self] note, vel, on in
            guard let self else { return }
            let index = MIDIInput.padIndex(for: note)
            if on {
                self.lastMIDINote = note
                self.trigger(index, velocity: Float(vel) / 127)
            } else {
                self.releasePad(index)
            }
        }
        midi.connectAll()

        timers = [
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshConnection()
                    self?.autosave()
                }
            },
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNowPlaying() }
            },
        ]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        } as Any)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            runSelfTest(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }

    // MARK: Capture

    func refreshConnection() {
        let processes = CoreAudioUtils.spotifyProcessObjects()
        let outputUID = (try? CoreAudioUtils.defaultOutputDeviceUID()) ?? ""

        guard !processes.isEmpty else {
            if tap.isRunning { tap.stop() }
            connected = false
            status = spotifyRunning ? "Spotify is open — press play" : "Open Spotify to start sampling"
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

    private var spotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
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
        if connected, !nowPlaying.isEmpty, level < 0.0001 {
            silentTicks += 1
            if silentTicks > 120 {
                hint = "Spotify is playing but no audio is reaching the app. Allow it under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only), then relaunch."
            }
        } else if silentTicks > 0 {
            silentTicks = 0
            hint = nil
        }
    }

    private func refreshNowPlaying() {
        guard spotifyRunning else {
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
        addSource(ring.latest(frames: Int(grabSeconds * ring.sampleRate)), rate: ring.sampleRate)
    }

    func toggleRecording() {
        guard let ring else { return }
        if isRecording {
            isRecording = false
            addSource(ring.copy(from: recordStart, to: ring.totalFrames), rate: ring.sampleRate)
        } else {
            recordStart = ring.totalFrames
            recordSeconds = 0
            isRecording = true
        }
    }

    @discardableResult
    private func addSource(_ frames: [Float], rate: Double, name: String? = nil) -> Sample? {
        guard frames.count > 64 else {
            hint = "Nothing captured yet — play something in Spotify first."
            return nil
        }
        sampleCounter += 1
        let source = AudioSource(sampleRate: rate, frames: frames)
        let label = name ?? (nowPlaying.isEmpty ? "Sample \(sampleCounter)" : nowPlaying)
        let sample = Sample(source: source, params: SampleParams(name: label))
        place(sample, preferEmpty: true)
        if source.isSilent {
            hint = "That capture was silent. If Spotify was playing, check the System Audio Recording permission."
        }
        return sample
    }

    private func place(_ sample: Sample, preferEmpty: Bool) {
        let slot = pads.firstIndex(where: { $0 == nil }) ?? selectedPad
        if let old = pads[slot] { sampler.remove(old) }
        pads[slot] = sample
        selectedPad = slot
    }

    // MARK: Pads

    func trigger(_ index: Int, velocity: Float = 1) {
        selectedPad = index
        guard let sample = pads[index] else { return }
        if sample.p.loop, sample.p.playMode == .oneShot, playing.contains(sample.id) {
            sampler.release(sample)
            return
        }
        play(sample, velocity: velocity)
    }

    func releasePad(_ index: Int) {
        guard let sample = pads[index], sample.p.playMode == .gate else { return }
        sampler.release(sample)
    }

    func play(_ sample: Sample, velocity: Float = 1) {
        for other in pads.compactMap({ $0 }) where other.id != sample.id && playing.contains(other.id) {
            if monoPads || (sample.p.choke > 0 && other.p.choke == sample.p.choke) {
                sampler.release(other)
            }
        }
        sampler.play(sample, velocity: velocity)
        playing.insert(sample.id)
    }

    func stop(_ sample: Sample) { sampler.release(sample) }

    func togglePlay(_ sample: Sample) {
        playing.contains(sample.id) ? stop(sample) : play(sample)
    }

    func delete(_ index: Int) {
        guard let sample = pads[index] else { return }
        sampler.remove(sample)
        playing.remove(sample.id)
        pads[index] = nil
    }

    func setRegion(_ sample: Sample, start: Double? = nil, end: Double? = nil) {
        func snapped(_ v: Double) -> Double {
            switch snap {
            case .off: return v
            case .zero: return sample.snapToZero(v)
            case .beat: return sample.snapToBeat(v)
            }
        }
        let minLen = 64.0 / Double(sample.frameCount)
        if let start { sample.p.start = min(max(snapped(start), 0), sample.p.end - minLen) }
        if let end { sample.p.end = max(min(snapped(end), 1), sample.p.start + minLen) }
    }

    // MARK: Chop

    enum ChopMode { case transients, equal(Int), beats }

    /// Splits the selected pad's region into slices that share its audio and fills empty pads.
    func chop(_ mode: ChopMode) {
        guard let sample = selected else { return }
        let (a, b) = sample.frameRange
        let n = sample.frameCount
        var cuts: [Int]
        switch mode {
        case .transients:
            cuts = Analysis.onsets(sample.source.mono, sampleRate: sample.sampleRate,
                                   sensitivity: chopSensitivity, range: a..<b)
            if cuts.first.map({ $0 - a > Int(sample.sampleRate * 0.03) }) ?? true { cuts.insert(a, at: 0) }
        case let .equal(count):
            cuts = (0..<count).map { i in
                Analysis.nearestZeroCrossing(sample.source.mono, around: a + (b - a) * i / count, within: 256)
            }
        case .beats:
            guard let bpm = sample.source.bpm else {
                hint = "Couldn't detect a tempo in this sample — try Transients or Equal."
                return
            }
            let beat = 60 / bpm * sample.sampleRate
            var t = sample.source.firstBeat * sample.sampleRate
            while t > Double(a) { t -= beat }
            cuts = []
            while t < Double(b) {
                if t >= Double(a) { cuts.append(Analysis.nearestZeroCrossing(sample.source.mono, around: Int(t), within: 256)) }
                t += beat
            }
            if cuts.first.map({ $0 > a + 256 }) ?? true { cuts.insert(a, at: 0) }
        }

        let empty = pads.indices.filter { pads[$0] == nil }
        let maxSlices = empty.count + 1
        cuts = Array(cuts.prefix(maxSlices))
        guard cuts.count > 1 else {
            hint = "Only found one slice — raise sensitivity or pick a longer region."
            return
        }
        if cuts.count == maxSlices, maxSlices < 16 {
            hint = "Chopped into \(cuts.count) slices (filled every empty pad)."
        }
        let bounds = cuts + [b]
        let base = sample.p.name
        let original = sample.p
        var targets = [selectedPad] + empty
        for (i, cut) in cuts.enumerated() {
            var params = original
            params.start = Double(cut) / Double(n)
            params.end = Double(bounds[i + 1]) / Double(n)
            params.name = "\(base) · \(i + 1)"
            params.loop = false
            let slot = targets.removeFirst()
            if i == 0 {
                sample.p = params
            } else {
                pads[slot] = Sample(source: sample.source, params: params)
            }
        }
    }

    // MARK: Stems

    func splitStems() {
        guard let sample = selected, !stems.isBusy else { return }
        Task {
            if stems.state != .ready {
                await stems.install()
                guard stems.state == .ready else { return }
            }
            do {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stem-in-\(UUID().uuidString).wav")
                var raw = sample.p
                raw.semitones = 0; raw.syncTempo = false; raw.filter = .off; raw.reverse = false
                raw.attack = 0; raw.decay = 0; raw.sustain = 1; raw.gain = 1
                let dry = Sample(source: sample.source, params: raw)
                try SamplerEngine.writeWAV(try SamplerEngine.renderOffline(dry, projectBPM: projectBPM), to: tmp)
                let results = try await stems.separate(tmp)
                var placed = 0
                for (name, url) in results {
                    guard pads.contains(where: { $0 == nil }) else { break }
                    let source = try KitStore.readSource(url)
                    if source.isSilent { continue }
                    let s = Sample(source: source, params: SampleParams(name: "\(sample.p.name) · \(name)"))
                    place(s, preferEmpty: true)
                    placed += 1
                }
                hint = placed == 0 ? "No empty pads for stems — clear some pads first." : "Added \(placed) stems to empty pads."
            } catch {
                stems.state = .failed("Separation failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Kits

    private func restoreLastKit() {
        kits = KitStore.list()
        let last = UserDefaults.standard.string(forKey: "currentKit")
        if let id = last.flatMap({ l in kits.first { $0.id == l } })?.id ?? kits.first?.id {
            openKit(id)
        } else {
            kitID = UUID().uuidString
            kitName = "Kit 1"
        }
    }

    func autosave() {
        guard !kitID.isEmpty else { return }
        let kit = KitStore.encode(name: kitName, bpm: projectBPM, pads: pads)
        guard let data = try? JSONEncoder().encode(kit), data != lastSaved else { return }
        let isEmpty = pads.allSatisfy { $0 == nil }
        if isEmpty, !FileManager.default.fileExists(atPath: KitStore.dir(kitID).path) { return }
        var seen = Set<UUID>()
        let sources = pads.compactMap { $0?.source }.filter { seen.insert($0.id).inserted }
        do {
            try KitStore.save(kit, sources: sources, id: kitID)
            lastSaved = data
            UserDefaults.standard.set(kitID, forKey: "currentKit")
            kits = KitStore.list()
        } catch {
            hint = "Couldn't save kit: \(error.localizedDescription)"
        }
    }

    func openKit(_ id: String) {
        autosave()
        pads.compactMap { $0 }.forEach(sampler.remove)
        playing = []
        do {
            let kit = try KitStore.load(id)
            kitID = id
            kitName = kit.name
            projectBPM = kit.bpm
            pads = kit.pads
            selectedPad = pads.firstIndex(where: { $0 != nil }) ?? 0
            lastSaved = try? JSONEncoder().encode(KitStore.encode(name: kitName, bpm: projectBPM, pads: pads))
            UserDefaults.standard.set(id, forKey: "currentKit")
        } catch {
            hint = "Couldn't open kit: \(error.localizedDescription)"
            if kitID.isEmpty { kitID = UUID().uuidString }
        }
        kits = KitStore.list()
    }

    func newKit() {
        autosave()
        pads.compactMap { $0 }.forEach(sampler.remove)
        playing = []
        pads = Array(repeating: nil, count: 16)
        selectedPad = 0
        kitID = UUID().uuidString
        kitName = "Kit \(kits.count + 1)"
        lastSaved = nil
    }

    func duplicateKit() {
        autosave()
        kitID = UUID().uuidString
        kitName += " copy"
        lastSaved = nil
        autosave()
    }

    func deleteKit() {
        let id = kitID
        KitStore.delete(id)
        kits = KitStore.list()
        if let next = kits.first { lastSaved = nil; openKitWithoutSaving(next.id) } else { newKit() }
    }

    private func openKitWithoutSaving(_ id: String) {
        lastSaved = try? JSONEncoder().encode(KitStore.encode(name: kitName, bpm: projectBPM, pads: pads))
        openKit(id)
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
            try SamplerEngine.writeWAV(try SamplerEngine.renderOffline(sample, projectBPM: projectBPM), to: url)
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
        let provider = (try? SamplerEngine.renderOffline(sample, projectBPM: projectBPM))
            .flatMap { (try? SamplerEngine.writeWAV($0, to: url)) != nil ? NSItemProvider(contentsOf: url) : nil }
            ?? NSItemProvider()
        // Private type so pads can be rearranged inside the app; other apps only see the WAV.
        provider.registerDataRepresentation(forTypeIdentifier: Self.padDragType, visibility: .ownProcess) { done in
            done(Data(String(index).utf8), nil)
            return nil
        }
        return provider
    }

    static let padDragType = "local.spotifysampler.pad"

    /// Drop pad `from` onto pad `to`: moves into an empty slot, swaps with a filled one,
    /// or (copy) duplicates it, sharing the same audio.
    func movePad(from: Int, to: Int, copy: Bool) {
        guard from != to, pads.indices.contains(from), pads.indices.contains(to), let source = pads[from] else { return }
        if copy {
            if let old = pads[to] { sampler.remove(old); playing.remove(old.id) }
            pads[to] = Sample(source: source.source, params: source.p)
        } else {
            pads.swapAt(from, to)
        }
        selectedPad = to
    }

    // MARK: Keyboard

    /// Give the keyboard back to the pads (ends any text editing).
    func endEditing() {
        for window in NSApp.windows { window.makeFirstResponder(nil) }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        keyEventsSeen += 1
        if NSApp.keyWindow?.firstResponder is NSTextView {
            if event.type == .keyDown, event.keyCode == 53 { endEditing(); return nil } // Esc
            return event
        }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
        if event.type == .keyUp {
            if let index = heldKeys.removeValue(forKey: event.keyCode) { releasePad(index); return nil }
            return event
        }
        switch event.keyCode {
        case 36: grab(); return nil // Return
        case 49: if let s = selected { togglePlay(s) }; return nil // Space
        case 51: delete(selectedPad); return nil // Delete
        default: break
        }
        if let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let index = Self.padKeys.firstIndex(of: ch) {
            if !event.isARepeat {
                heldKeys[event.keyCode] = index
                trigger(index)
            }
            return nil
        }
        return event
    }

    // MARK: Self-test

    /// `SpotifySampler --selftest out.json`: waits for Spotify audio, grabs 3 s, exports it and writes a report.
    private func runSelfTest(output: URL) {
        Task { @MainActor in
            var report: [String: Any] = [:]
            let deadline = Date().addingTimeInterval(25)
            var maxLevel: Float = 0
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                maxLevel = max(maxLevel, level)
                if level > 0.001, let ring, ring.totalFrames > Int64(ring.sampleRate * 3) { break }
            }
            report["connected"] = connected
            report["status"] = status
            report["maxLevel"] = maxLevel
            report["sampleRate"] = ring?.sampleRate ?? 0
            report["spotifyProcessObjects"] = CoreAudioUtils.spotifyProcessObjects().count
            if let ring {
                let frames = ring.latest(frames: Int(ring.sampleRate * 3))
                let rms = sqrt(frames.reduce(0) { $0 + Double($1 * $1) } / Double(max(frames.count, 1)))
                report["capturedFrames"] = frames.count / 2
                report["rms"] = rms
                let source = AudioSource(sampleRate: ring.sampleRate, frames: frames)
                report["detectedBPM"] = source.bpm ?? 0
                report["onsets"] = Analysis.onsets(source.mono, sampleRate: source.sampleRate, sensitivity: 0.5).count
                let s = Sample(source: source, params: SampleParams(name: "selftest"))
                let wav = output.deletingPathExtension().appendingPathExtension("wav")
                if let buf = try? SamplerEngine.renderOffline(s, projectBPM: 120) {
                    try? SamplerEngine.writeWAV(buf, to: wav)
                    report["exported"] = wav.path
                }
            }
            report["firstResponderAtLaunch"] = NSApp.windows.first(where: { $0.isVisible })?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            kitID = ""
            pads = Array(repeating: nil, count: 16)
            var silent = SampleParams(name: "keytest")
            silent.gain = 0
            let pad = Sample(source: AudioSource(sampleRate: 48_000, frames: [Float](repeating: 0, count: 96_000)), params: silent)
            pads[4] = pad // "Q"
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first { $0.isVisible }
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window?.windowNumber ?? 0, context: nil, characters: "q",
                                            charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(300))
            report["keyQTriggeredPad"] = playing.contains(pad.id) && selectedPad == 4
            report["keyEventsSeen"] = keyEventsSeen
            report["selectedPadAfterKey"] = selectedPad
            report["appActive"] = NSApp.isActive
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output)
            }
            NSApp.terminate(nil)
        }
    }
}
