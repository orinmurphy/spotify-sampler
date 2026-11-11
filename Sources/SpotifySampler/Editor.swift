import SwiftUI

struct SampleEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var sample: Sample
    @State private var zoom: Double = 1
    @State private var center: Double = 0.5
    @State private var confirmStemInstall = false

    private var visible: (Double, Double) {
        let span = 1 / zoom
        let c = min(max(center, span / 2), 1 - span / 2)
        return (c - span / 2, c + span / 2)
    }

    var body: some View {
        @Bindable var model = model
        let isPlaying = model.playing.contains(sample.id)
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 12) {
                TextField("Name", text: $sample.p.name).textFieldStyle(.plain).font(.title3.bold())
                Spacer()
                if let bpm = sample.source.bpm {
                    Label(String(format: "%.1f bpm", bpm), systemImage: "metronome")
                        .foregroundStyle(.secondary)
                        .help("Detected tempo of this capture")
                }
                Text(String(format: "%.2fs", sample.regionDuration(projectBPM: model.projectBPM)))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Picker("Snap", selection: $model.snap) {
                    ForEach(SnapMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 230)
                .help("Snap region edges to zero crossings (click-free) or the detected beat grid")
                zoomControls
            }

            RegionEditor(sample: sample, visibleStart: visible.0, visibleEnd: visible.1)
                .frame(minHeight: 110)
            if zoom > 1 {
                Slider(value: $center, in: (0.5 / zoom)...(1 - 0.5 / zoom)).controlSize(.mini)
            }

            // Transport + pad behaviour
            HStack(spacing: 12) {
                Button { model.togglePlay(sample) } label: {
                    Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill").frame(width: 56)
                }
                Toggle("Loop", isOn: $sample.p.loop).toggleStyle(.button)
                Toggle("Reverse", isOn: $sample.p.reverse).toggleStyle(.button)
                Button("Full") { sample.p.start = 0; sample.p.end = 1 }
                Divider().frame(height: 18)
                Picker("Mode", selection: $sample.p.playMode) {
                    ForEach(PlayMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                .help("One-shot plays to the end. Gate plays only while the key/pad is held.")
                Picker("Choke", selection: $sample.p.choke) {
                    Text("Off").tag(0)
                    ForEach(1...4, id: \.self) { Text("Group \($0)").tag($0) }
                }
                .frame(width: 150)
                .help("Pads in the same choke group cut each other off (e.g. open/closed hi-hat)")
                Spacer()
                chopMenu
                stemsButton
                Button { model.export(sample) } label: { Label("Export", systemImage: "square.and.arrow.down") }
                    .help("Render to ~/Music/Spotify Sampler with all settings baked in. Or drag a pad into your DAW.")
                Button(role: .destructive) { model.delete(model.selectedPad) } label: { Image(systemName: "trash") }
            }

            // Sound shaping
            HStack(alignment: .top, spacing: 18) {
                section("Pitch & Time") {
                    HStack {
                        Slider(value: $sample.p.semitones, in: -24...24, step: 1).frame(width: 130)
                        Text(String(format: "%+.0f st", sample.p.semitones)).monospacedDigit().frame(width: 46, alignment: .leading)
                    }
                    HStack {
                        Picker("", selection: $sample.p.pitchMode) {
                            ForEach(PitchMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                        .help("Varispeed: pitch and speed change together (classic). Time-stretch: pitch and tempo independent.")
                        Toggle("Sync", isOn: $sample.p.syncTempo)
                            .disabled(sample.source.bpm == nil)
                            .help(sample.source.bpm == nil ? "No tempo detected" : "Stretch to the project BPM")
                    }
                }
                section("Gain") {
                    Slider(value: $sample.p.gain, in: 0...2).frame(width: 90)
                    Text(String(format: "%.0f%%", sample.p.gain * 100)).monospacedDigit().foregroundStyle(.secondary)
                }
                section("Envelope") {
                    HStack(spacing: 10) {
                        knob("A", value: $sample.p.attack, range: 0...2000, unit: "ms")
                        knob("D", value: $sample.p.decay, range: 0...2000, unit: "ms")
                        knob("S", value: $sample.p.sustain, range: 0...1, unit: "%")
                        knob("R", value: $sample.p.release, range: 5...3000, unit: "ms")
                    }
                }
                section("Filter") {
                    Picker("", selection: $sample.p.filter) {
                        ForEach(FilterType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    HStack {
                        Slider(value: Binding(get: { log10(sample.p.cutoff) }, set: { sample.p.cutoff = pow(10, $0) }),
                               in: log10(20)...log10(20000)).frame(width: 110)
                        Text(sample.p.cutoff >= 1000 ? String(format: "%.1fk", sample.p.cutoff / 1000) : String(format: "%.0f", sample.p.cutoff))
                            .monospacedDigit().frame(width: 40, alignment: .leading)
                    }
                    .disabled(sample.p.filter == .off)
                    HStack {
                        Text("Res").foregroundStyle(.secondary)
                        Slider(value: $sample.p.resonance, in: 0...1).frame(width: 80)
                    }
                    .disabled(sample.p.filter == .off)
                }
            }
            .controlSize(.small)

            stemStatus
        }
        .padding(16)
        .onChange(of: sample.p) { old, new in
            // Pitch/gain/filter update live; region/loop/reverse/envelope need a retrigger.
            var a = old, b = new
            for p in [\SampleParams.semitones, \.gain, \.cutoff, \.resonance] as [WritableKeyPath<SampleParams, Double>] {
                a[keyPath: p] = 0; b[keyPath: p] = 0
            }
            a.filter = .off; b.filter = .off; a.pitchMode = .varispeed; b.pitchMode = .varispeed
            a.syncTempo = false; b.syncTempo = false; a.name = ""; b.name = ""; a.choke = 0; b.choke = 0; a.playMode = .oneShot; b.playMode = .oneShot
            if a != b, isPlaying, new.loop || old.loop { model.play(sample) } else { model.sampler.update(sample) }
        }
        .onChange(of: model.projectBPM) { model.sampler.update(sample) }
        .alert("Install stem separator?", isPresented: $confirmStemInstall) {
            Button("Download & Install") { model.splitStems() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stem splitting runs the open-source Demucs model on your Mac. The first run downloads PyTorch and the model (about 1–2 GB) into Application Support. Nothing is uploaded.")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom = max(1, zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(zoom <= 1)
            Button { zoom = min(256, zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
            Button {
                let span = max(sample.p.end - sample.p.start, 0.002)
                zoom = min(max(1 / (span * 1.1), 1), 256)
                center = (sample.p.start + sample.p.end) / 2
            } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Zoom to region")
        }
        .buttonStyle(.borderless)
    }

    private var chopMenu: some View {
        @Bindable var model = model
        return Menu {
            Button("Transients") { model.chop(.transients) }
            Menu("Sensitivity: \(Int(model.chopSensitivity * 100))%") {
                ForEach([0.2, 0.35, 0.5, 0.65, 0.8, 0.95], id: \.self) { v in
                    Button("\(Int(v * 100))%") { model.chopSensitivity = v }
                }
            }
            Divider()
            Button("Every Beat") { model.chop(.beats) }.disabled(sample.source.bpm == nil)
            ForEach([4, 8, 16], id: \.self) { n in
                Button("\(n) Equal Slices") { model.chop(.equal(n)) }
            }
        } label: {
            Label("Chop", systemImage: "square.split.2x2")
        }
        .fixedSize()
        .help("Slice this region across the empty pads")
    }

    private var stemsButton: some View {
        Button {
            if model.stems.state == .ready { model.splitStems() } else { confirmStemInstall = true }
        } label: {
            Label("Stems", systemImage: "square.3.layers.3d.down.right")
        }
        .disabled(model.stems.isBusy)
        .help("Split into vocals, drums, bass and other on new pads")
    }

    @ViewBuilder private var stemStatus: some View {
        switch model.stems.state {
        case let .installing(msg), let .running(msg):
            HStack { ProgressView().controlSize(.small); Text(msg).font(.caption).foregroundStyle(.secondary) }
        case let .failed(msg):
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func knob(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 2) {
            Slider(value: value, in: range).frame(width: 64)
            Text(unit == "%" ? "\(label) \(Int(value.wrappedValue * 100))%" : "\(label) \(Int(value.wrappedValue))\(unit)")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Zoomable waveform with draggable region handles and a beat grid.
struct RegionEditor: View {
    @Environment(AppModel.self) private var model
    let sample: Sample
    let visibleStart: Double
    let visibleEnd: Double
    @State private var mode: DragMode?

    enum DragMode { case start, end, fresh(Double) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = visibleEnd - visibleStart
            let toX = { (pos: Double) -> CGFloat in CGFloat((pos - visibleStart) / span) * w }
            let n = sample.frameCount
            let peaks = Analysis.peaks(sample.source.frames, from: Int(visibleStart * Double(n)),
                                       to: Int(visibleEnd * Double(n)), buckets: max(Int(w / 2), 1))
            let x0 = toX(sample.p.start), x1 = toX(sample.p.end)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.panel)
                beatGrid(width: w, height: geo.size.height, toX: toX)
                Waveform(peaks: peaks, color: .white.opacity(0.25)).padding(.vertical, 10)
                Waveform(peaks: peaks, color: .amber)
                    .padding(.vertical, 10)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(min(x1, w) - max(x0, 0), 0)).offset(x: max(x0, 0))
                    }
                Rectangle().fill(Color.amber.opacity(0.08))
                    .frame(width: max(min(x1, w) - max(x0, 0), 0))
                    .offset(x: max(x0, 0))
                Rectangle().fill(Color.amber).frame(width: 2).offset(x: x0 - 1)
                Rectangle().fill(Color.amber).frame(width: 2).offset(x: x1 - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let pos = min(max(visibleStart + Double(value.location.x / w) * span, 0), 1)
                        if mode == nil {
                            let sx = value.startLocation.x
                            if abs(sx - x0) < 10 { mode = .start }
                            else if abs(sx - x1) < 10 { mode = .end }
                            else { mode = .fresh(min(max(visibleStart + Double(sx / w) * span, 0), 1)) }
                        }
                        switch mode {
                        case .start: model.setRegion(sample, start: pos)
                        case .end: model.setRegion(sample, end: pos)
                        case let .fresh(anchor):
                            let lo = min(anchor, pos), hi = max(anchor, pos)
                            sample.p.start = 0; sample.p.end = 1
                            model.setRegion(sample, end: hi)
                            model.setRegion(sample, start: lo)
                        case nil: break
                        }
                    }
                    .onEnded { _ in mode = nil }
            )
        }
    }

    @ViewBuilder
    private func beatGrid(width: CGFloat, height: CGFloat, toX: @escaping (Double) -> CGFloat) -> some View {
        if let bpm = sample.source.bpm {
            Canvas { ctx, size in
                let dur = sample.duration
                let beat = 60 / bpm
                var t = sample.source.firstBeat
                while t > 0 { t -= beat }
                var i = Int((sample.source.firstBeat - t) / beat + 0.5) * -1
                while t < dur {
                    let x = toX(t / dur)
                    if x >= 0 && x <= size.width {
                        let bar = ((i % 4) + 4) % 4 == 0
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                 with: .color(.white.opacity(bar ? 0.14 : 0.05)))
                    }
                    t += beat
                    i += 1
                }
            }
        }
    }
}
