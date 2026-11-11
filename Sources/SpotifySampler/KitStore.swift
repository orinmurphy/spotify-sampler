import AVFoundation
import Foundation

/// Kits live in ~/Library/Application Support/SpotifySampler/Kits/<id>/
///   kit.json          – name, tempo, pad settings
///   sources/<id>.caf  – 32-bit float audio, shared by slices that came from the same capture
struct KitFile: Codable {
    struct Pad: Codable {
        var sourceID: UUID
        var params: SampleParams
    }

    var name: String
    var bpm: Double
    var pads: [Pad?]
}

struct KitInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let modified: Date
}

enum KitStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpotifySampler/Kits", isDirectory: true)
    }()

    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    static func list() -> [KitInfo] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return ids.compactMap { id -> KitInfo? in
            let json = dir(id).appendingPathComponent("kit.json")
            guard let data = try? Data(contentsOf: json),
                  let kit = try? JSONDecoder().decode(KitFile.self, from: data) else { return nil }
            let modified = (try? fm.attributesOfItem(atPath: json.path)[.modificationDate] as? Date) ?? .distantPast
            return KitInfo(id: id, name: kit.name, modified: modified)
        }.sorted { $0.modified > $1.modified }
    }

    static func encode(name: String, bpm: Double, pads: [Sample?]) -> KitFile {
        KitFile(name: name, bpm: bpm, pads: pads.map { s in s.map { .init(sourceID: $0.source.id, params: $0.p) } })
    }

    static func save(_ kit: KitFile, sources: [AudioSource], id: String) throws {
        let fm = FileManager.default
        let srcDir = dir(id).appendingPathComponent("sources", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var keep = Set<String>()
        for source in sources {
            let name = "\(source.id.uuidString).caf"
            keep.insert(name)
            let url = srcDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try writeSource(source, to: url) }
        }
        for file in (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? [] where !keep.contains(file) {
            try? fm.removeItem(at: srcDir.appendingPathComponent(file))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(kit).write(to: dir(id).appendingPathComponent("kit.json"), options: .atomic)
    }

    static func load(_ id: String) throws -> (name: String, bpm: Double, pads: [Sample?]) {
        let data = try Data(contentsOf: dir(id).appendingPathComponent("kit.json"))
        let kit = try JSONDecoder().decode(KitFile.self, from: data)
        var cache: [UUID: AudioSource] = [:]
        var pads: [Sample?] = []
        for entry in kit.pads.prefix(16) {
            guard let entry else { pads.append(nil); continue }
            if cache[entry.sourceID] == nil {
                let url = dir(id).appendingPathComponent("sources/\(entry.sourceID.uuidString).caf")
                cache[entry.sourceID] = try? readSource(url, id: entry.sourceID)
            }
            pads.append(cache[entry.sourceID].map { Sample(source: $0, params: entry.params) })
        }
        while pads.count < 16 { pads.append(nil) }
        return (kit.name, kit.bpm, pads)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
    }

    private static func writeSource(_ source: AudioSource, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 2)!
        guard let buffer = source.buffer(from: 0, to: source.frameCount, reverse: false, format: format) else { return }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func readSource(_ url: URL, id: UUID = UUID()) throws -> AudioSource {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        let channels = Int(file.processingFormat.channelCount)
        let len = Int(buffer.frameLength)
        var frames = [Float](repeating: 0, count: len * 2)
        let l = buffer.floatChannelData![0]
        let r = buffer.floatChannelData![channels > 1 ? 1 : 0]
        for i in 0..<len {
            frames[i * 2] = l[i]
            frames[i * 2 + 1] = r[i]
        }
        return AudioSource(id: id, sampleRate: file.processingFormat.sampleRate, frames: frames)
    }
}
