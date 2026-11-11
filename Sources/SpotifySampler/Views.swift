import SwiftUI

extension Color {
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.18)
    static let panel = Color(white: 0.11)
    static let padIdle = Color(white: 0.16)
}

@main
struct SpotifySamplerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spotify Sampler") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 680)
                .preferredColorScheme(.dark)
                .tint(.amber)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Capture") {
                Button("Grab Last Seconds") { model.grab() }.keyboardShortcut("g")
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .keyboardShortcut("r")
                Divider()
                Button("Open Export Folder") {
                    try? FileManager.default.createDirectory(at: AppModel.exportFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppModel.exportFolder)
                }
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            CaptureStrip()
            Divider()
            Group {
                if let sample = model.selected {
                    SampleEditor(sample: sample).id(sample.id)
                } else {
                    EmptyEditor()
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            PadGrid().padding(16)
        }
        .background(Color(white: 0.07))
    }
}

// MARK: Header

struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.headline)
                Text(model.nowPlaying.isEmpty ? "Nothing playing" : model.nowPlaying)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            LevelMeter(level: model.level).frame(width: 160, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if let hint = model.hint {
                Text(hint)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.2))
                    .offset(y: 30)
            }
        }
        .zIndex(1)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .amber, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(sqrt(level), 1)))
            }
        }
    }
}

// MARK: Live capture

struct CaptureStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.panel)
                Waveform(peaks: model.livePeaks, color: model.isRecording ? .red : .amber)
                    .padding(.vertical, 8)
                    .animation(nil, value: model.livePeaks)
                if model.isRecording {
                    Text(String(format: "● REC  %.1fs", model.recordSeconds))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
            .frame(height: 90)

            HStack(spacing: 14) {
                Text("Buffer").foregroundStyle(.secondary)
                Slider(value: $model.grabSeconds, in: 1...30, step: 0.5).frame(maxWidth: 260)
                Text(String(format: "%.1fs", model.grabSeconds))
                    .font(.system(.body, design: .monospaced)).frame(width: 52, alignment: .leading)
                Spacer()
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                }
                .disabled(!model.connected)
                .help("Record until you press Stop (⌘R)")
                Button {
                    model.grab()
                } label: {
                    Label(String(format: "Grab last %.1fs", model.grabSeconds), systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected)
                .help("Capture what Spotify just played (Return)")
            }
        }
        .padding(16)
    }
}

// MARK: Editor

struct EmptyEditor: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Play something in Spotify, then hit Return to grab it.")
                .foregroundStyle(.secondary)
            Text("Pads: 1-4 · Q-R · A-F · Z-V    Space: play/stop    ⌫: clear pad")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SampleEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var sample: Sample

    var body: some View {
        let isPlaying = model.playing.contains(sample.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: $sample.name)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                Spacer()
                Text(String(format: "%.2fs of %.2fs", sample.regionDuration, sample.duration))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            RegionEditor(sample: sample)
                .frame(minHeight: 120)

            HStack(spacing: 16) {
                Button {
                    model.togglePlay(sample)
                } label: {
                    Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 60)
                }
                Toggle("Loop", isOn: $sample.loop).toggleStyle(.button)
                Toggle("Reverse", isOn: $sample.reverse).toggleStyle(.button)
                Button("Full") {
                    sample.start = 0
                    sample.end = 1
                }
                .help("Reset the region to the whole capture")

                Divider().frame(height: 20)

                Text("Pitch").foregroundStyle(.secondary)
                Slider(value: $sample.semitones, in: -12...12, step: 1).frame(width: 140)
                Text(String(format: "%+.0f st", sample.semitones))
                    .font(.system(.body, design: .monospaced)).frame(width: 52, alignment: .leading)

                Text("Gain").foregroundStyle(.secondary)
                Slider(value: $sample.gain, in: 0...2).frame(width: 100)

                Spacer()
                Button {
                    model.export(sample)
                } label: {
                    Label("Export WAV", systemImage: "square.and.arrow.down")
                }
                .help("Saves to ~/Music/Spotify Sampler (pitch, reverse and gain baked in). You can also drag a pad into your DAW.")
                Button(role: .destructive) {
                    model.delete(model.selectedPad)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(16)
        .onChange(of: sample.semitones) { model.sampler.update(sample) }
        .onChange(of: sample.gain) { model.sampler.update(sample) }
        .onChange(of: sample.loop) { if isPlaying { model.play(sample) } }
        .onChange(of: sample.reverse) { if isPlaying { model.play(sample) } }
    }
}

/// Waveform with a draggable start/end region. Drag on empty space to select a new region,
/// drag near a handle to move it.
struct RegionEditor: View {
    @Bindable var sample: Sample
    @State private var mode: DragMode?

    enum DragMode { case start, end, fresh(Double) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = sample.start * w, x1 = sample.end * w
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.panel)
                Waveform(peaks: sample.peaks, color: .white.opacity(0.25)).padding(.vertical, 10)
                Waveform(peaks: sample.peaks, color: .amber)
                    .padding(.vertical, 10)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(x1 - x0, 1)).offset(x: x0)
                    }
                Rectangle().fill(Color.amber.opacity(0.08))
                    .frame(width: max(x1 - x0, 1))
                    .offset(x: x0)
                handle.offset(x: x0 - 1)
                handle.offset(x: x1 - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let pos = min(max(value.location.x / w, 0), 1)
                        if mode == nil {
                            let sx = value.startLocation.x
                            if abs(sx - x0) < 10 { mode = .start }
                            else if abs(sx - x1) < 10 { mode = .end }
                            else { mode = .fresh(min(max(sx / w, 0), 1)) }
                        }
                        let minLen = 0.002
                        switch mode {
                        case .start: sample.start = min(pos, sample.end - minLen)
                        case .end: sample.end = max(pos, sample.start + minLen)
                        case let .fresh(anchor):
                            sample.start = min(anchor, pos)
                            sample.end = max(max(anchor, pos), sample.start + minLen)
                        case nil: break
                        }
                    }
                    .onEnded { _ in mode = nil }
            )
        }
    }

    private var handle: some View {
        Rectangle().fill(Color.amber).frame(width: 2)
    }
}

struct Waveform: View {
    let peaks: [Float]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let mid = size.height / 2
            let step = size.width / CGFloat(peaks.count)
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let h = max(1, CGFloat(min(p, 1)) * size.height)
                path.addRect(CGRect(x: CGFloat(i) * step, y: mid - h / 2, width: max(step * 0.8, 0.6), height: h))
            }
            ctx.fill(path, with: .color(color))
        }
    }
}

// MARK: Pads

struct PadGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { col in
                        PadView(index: row * 4 + col)
                    }
                }
            }
        }
        .frame(height: 300)
    }
}

struct PadView: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        let sample = model.pads[index]
        let selected = model.selectedPad == index
        let playing = sample.map { model.playing.contains($0.id) } ?? false

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(AppModel.padKeys[index]).uppercased())
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if sample?.loop == true { Image(systemName: "repeat").font(.caption2) }
                if sample?.reverse == true { Image(systemName: "arrow.uturn.backward").font(.caption2) }
            }
            Spacer(minLength: 0)
            if let sample {
                Waveform(peaks: regionPeaks(sample), color: playing ? .black.opacity(0.6) : .amber.opacity(0.8))
                    .frame(height: 22)
                Text(sample.name)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(playing ? Color.amber : Color.padIdle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.amber : Color.white.opacity(0.06), lineWidth: selected ? 2 : 1)
        )
        .foregroundStyle(playing ? Color.black : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { model.trigger(index) }
        .onDrag { model.dragProvider(for: index) }
        .contextMenu {
            if let sample {
                Button("Export WAV") { model.export(sample) }
                Button("Clear Pad", role: .destructive) { model.delete(index) }
            }
        }
        .animation(.easeOut(duration: 0.08), value: playing)
    }

    private func regionPeaks(_ s: Sample) -> [Float] {
        let n = s.peaks.count
        guard n > 0 else { return [] }
        let a = min(Int(s.start * Double(n)), n - 1)
        let b = max(min(Int(s.end * Double(n)), n), a + 1)
        let slice = Array(s.peaks[a..<b])
        return s.reverse ? slice.reversed() : slice
    }
}
