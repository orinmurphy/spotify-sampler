import SwiftUI

struct PadGrid: View {
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
        .frame(height: 260)
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
            HStack(spacing: 4) {
                Text(String(AppModel.padKeys[index]).uppercased())
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let p = sample?.p {
                    if p.choke > 0 { Text("C\(p.choke)").font(.caption2.bold()) }
                    if p.playMode == .gate { Image(systemName: "hand.point.down.fill").font(.caption2) }
                    if p.loop { Image(systemName: "repeat").font(.caption2) }
                    if p.reverse { Image(systemName: "arrow.uturn.backward").font(.caption2) }
                    if p.syncTempo { Image(systemName: "metronome").font(.caption2) }
                }
            }
            Spacer(minLength: 0)
            if let sample {
                Waveform(peaks: regionPeaks(sample), color: playing ? .black.opacity(0.6) : .amber.opacity(0.8))
                    .frame(height: 20)
                Text(sample.p.name).font(.caption).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(playing ? Color.amber : Color.padIdle))
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
        let (a, b) = s.frameRange
        let peaks = Analysis.peaks(s.source.frames, from: a, to: b, buckets: 60)
        return s.p.reverse ? peaks.reversed() : peaks
    }
}
