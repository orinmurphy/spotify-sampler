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
                .frame(minWidth: 1120, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(.amber)
        }
        .defaultSize(width: 1180, height: 820)
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
            CommandMenu("Kit") {
                Button("New Kit") { model.newKit() }.keyboardShortcut("n")
                Button("Duplicate Kit") { model.duplicateKit() }.keyboardShortcut("d")
                Button("Save Now") { model.autosave() }.keyboardShortcut("s")
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            if let hint = model.hint {
                HStack {
                    Text(hint).font(.caption)
                    Spacer()
                    Button { model.hint = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.2))
            }
            CaptureStrip()
            Divider()
            // Editor takes whatever the pads leave; the waveform grows/shrinks with it and the
            // controls scroll if the window is very short.
            GeometryReader { g in
                if let sample = model.selected {
                    ScrollView {
                        SampleEditor(sample: sample, waveHeight: max(60, g.size.height - 225)).id(sample.id)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    EmptyEditor().frame(width: g.size.width, height: g.size.height)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            Divider()
            PadGrid()
                .frame(minHeight: 150, idealHeight: 260, maxHeight: 300)
                .padding(16)
                .layoutPriority(1)
        }
        .background(Color(white: 0.07).onTapGesture { model.endEditing() })
        .onAppear {
            // SwiftUI focuses the first text field in a new window, which would swallow pad keys.
            for delay in [0.05, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.endEditing() }
            }
        }
    }
}

// MARK: Header

struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @State private var deleteConfirm = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 14) {
            Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.headline)
                Text(model.nowPlaying.isEmpty ? "Nothing playing" : model.nowPlaying)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 220, alignment: .leading)

            Spacer()

            Menu {
                ForEach(model.kits) { kit in
                    Button(kit.name) { model.openKit(kit.id) }.disabled(kit.id == model.kitID)
                }
                Divider()
                Button("New Kit") { model.newKit() }
                Button("Duplicate Kit") { model.duplicateKit() }
                Button("Delete Kit…", role: .destructive) { deleteConfirm = true }
            } label: {
                Label("Kits", systemImage: "square.grid.4x3.fill")
            }
            .fixedSize()
            TextField("Kit name", text: $model.kitName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.endEditing() }
                .frame(width: 150)

            Toggle(isOn: $model.monoPads) { Label("Mono", systemImage: "1.circle") }
                .toggleStyle(.button)
                .help(model.monoPads ? "Mono: a new pad stops the one that's playing. Turn off to layer pads."
                                     : "Poly: pads overlap. Turn on so a new pad stops the one that's playing.")

            HStack(spacing: 4) {
                Text("BPM").foregroundStyle(.secondary)
                TextField("BPM", value: $model.projectBPM, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                    .onSubmit { model.endEditing() }
                Stepper("", value: $model.projectBPM, in: 40...240, step: 1).labelsHidden()
            }
            .help("Project tempo. Pads with Sync on are stretched to this tempo.")

            Label(model.midiSources.isEmpty ? "No MIDI" : "\(model.midiSources.count) MIDI",
                  systemImage: "pianokeys")
                .foregroundStyle(model.midiSources.isEmpty ? .secondary : .primary)
                .help(model.midiSources.isEmpty ? "Plug in a MIDI controller to play pads (C1 = bottom-left pad)"
                                               : model.midiSources.joined(separator: ", "))

            LevelMeter(level: model.level).frame(width: 120, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("Delete “\(model.kitName)”? Its samples are removed from disk.", isPresented: $deleteConfirm) {
            Button("Delete Kit", role: .destructive) { model.deleteKit() }
        }
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
                if model.isRecording {
                    Text(String(format: "● REC  %.1fs", model.recordSeconds))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
            .frame(minHeight: 40, idealHeight: 72, maxHeight: 72)

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

struct EmptyEditor: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Play something in Spotify, then hit Return to grab it.")
                .foregroundStyle(.secondary)
            Text("Pads: 1-4 · Q-R · A-F · Z-V or MIDI notes from C1    Space: play/stop    ⌫: clear pad")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
