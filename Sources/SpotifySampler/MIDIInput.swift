import CoreMIDI
import Foundation

/// Listens to every connected MIDI source (hot-plug aware) and reports note on/off on the main thread.
final class MIDIInput {
    var onNote: ((_ note: UInt8, _ velocity: UInt8, _ on: Bool) -> Void)?
    var onSourcesChanged: (([String]) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    init() {
        MIDIClientCreateWithBlock("Spotify Sampler" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connectAll() }
        }
        MIDIInputPortCreateWithProtocol(client, "Pads In" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectAll()
    }

    func connectAll() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected = []
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0, MIDIPortConnectSource(port, src, nil) == noErr else { continue }
            connected.append(src)
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        onSourcesChanged?(names)
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        // Universal MIDI Packet words; we only care about MIDI 1.0 channel voice (type 0x2).
        let sizes = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var events: [(UInt8, UInt8, Bool)] = []
        for packet in list.unsafeSequence() {
            let count = min(Int(packet.pointee.wordCount), 64)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let type = Int(w >> 28)
                    if type == 2 {
                        let status = (w >> 16) & 0xF0
                        let note = UInt8((w >> 8) & 0x7F), vel = UInt8(w & 0x7F)
                        if status == 0x90 { events.append((note, vel, vel > 0)) }
                        else if status == 0x80 { events.append((note, 0, false)) }
                    }
                    i += sizes[type]
                }
            }
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for (n, v, on) in events { self?.onNote?(n, v, on) }
        }
    }

    /// Notes 36+ map MPC-style: bottom-left pad = C1 (36), wrapping every 16 notes so any keyboard works.
    static func padIndex(for note: UInt8) -> Int {
        let k = ((Int(note) - 36) % 16 + 16) % 16
        return (3 - k / 4) * 4 + k % 4
    }
}
