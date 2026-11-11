import Foundation
import Observation

/// On-device stem separation with Demucs (htdemucs) running in a private Python environment
/// under ~/Library/Application Support/SpotifySampler/stems. Installed on first use.
@Observable
@MainActor
final class StemSeparator {
    enum State: Equatable {
        case notInstalled
        case installing(String)
        case ready
        case running(String)
        case failed(String)
    }

    var state: State = .notInstalled

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SpotifySampler/stems", isDirectory: true)
    }()
    static var envDir: URL { root.appendingPathComponent("env", isDirectory: true) }
    static var python: URL { envDir.appendingPathComponent("bin/python") }
    static var script: URL { root.appendingPathComponent("separate.py") }
    static var marker: URL { root.appendingPathComponent("installed.ok") }

    var isBusy: Bool {
        switch state {
        case .installing, .running: return true
        default: return false
        }
    }

    init() {
        state = FileManager.default.fileExists(atPath: Self.marker.path) ? .ready : .notInstalled
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func findUV() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func install() async {
        state = .installing("Creating Python environment…")
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            let packages = ["torch>=2.5,<2.9", "torchaudio>=2.5,<2.9", "demucs==4.0.1", "soundfile", "numpy"]
            if let uv = Self.findUV() {
                // Explicit native arm64 interpreter: an Intel Python (e.g. /usr/local Homebrew) would pull
                // an ancient x86 PyTorch without Apple-GPU support.
                let arch = Self.isAppleSilicon ? "aarch64" : "x86_64"
                try? FileManager.default.removeItem(at: Self.envDir)
                try await run(uv, ["venv", "--python", "cpython-3.12-macos-\(arch)-none",
                                   "--python-preference", "only-managed", Self.envDir.path])
                state = .installing("Downloading PyTorch + Demucs (~1–2 GB)…")
                try await run(uv, ["pip", "install", "--python", Self.python.path] + packages)
            } else {
                let py = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
                    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
                try await run(py, ["-m", "venv", Self.envDir.path])
                state = .installing("Downloading PyTorch + Demucs (~1–2 GB)…")
                try await run(Self.python.path, ["-m", "pip", "install", "--upgrade", "pip"] )
                try await run(Self.python.path, ["-m", "pip", "install"] + packages)
            }
            try Self.pythonSource.write(to: Self.script, atomically: true, encoding: .utf8)
            state = .installing("Downloading separation model…")
            try await run(Self.python.path, [Self.script.path, "--warmup"])
            try Data().write(to: Self.marker)
            state = .ready
        } catch {
            state = .failed("Install failed: \(error.localizedDescription)")
        }
    }

    /// Splits a WAV into vocals / drums / bass / other. Returns stem name → file URL.
    func separate(_ input: URL) async throws -> [(String, URL)] {
        try Self.pythonSource.write(to: Self.script, atomically: true, encoding: .utf8)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        state = .running("Separating stems…")
        defer { if case .running = state { state = .ready } }
        try await run(Self.python.path, [Self.script.path, input.path, out.path])
        return ["vocals", "drums", "bass", "other"].compactMap { name in
            let url = out.appendingPathComponent("\(name).wav")
            return FileManager.default.fileExists(atPath: url.path) ? (name, url) : nil
        }
    }

    private func run(_ exe: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let log = LockedData()
            pipe.fileHandleForReading.readabilityHandler = { h in log.append(h.availableData) }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let tail = String(decoding: log.value.suffix(600), as: UTF8.self)
                    cont.resume(throwing: NSError(domain: "Stems", code: Int(p.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: tail]))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    private final class LockedData: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static let pythonSource = #"""
    import sys
    import numpy as np
    import soundfile as sf
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model

    model = get_model("htdemucs")
    model.eval()
    if sys.argv[1] == "--warmup":
        print("model ready")
        sys.exit(0)

    inp, outdir = sys.argv[1], sys.argv[2]
    wav, sr = sf.read(inp, dtype="float32", always_2d=True)
    x = torch.from_numpy(np.ascontiguousarray(wav.T))
    if x.shape[0] == 1:
        x = x.repeat(2, 1)
    if sr != model.samplerate:
        import julius
        x = julius.resample_frac(x, sr, model.samplerate)
    ref = x.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    x = (x - mean) / std

    def run(device):
        with torch.no_grad():
            return apply_model(model, x[None], device=device, split=True, overlap=0.25, progress=False)[0]

    try:
        out = run("mps" if torch.backends.mps.is_available() else "cpu")
    except Exception as e:
        print("MPS failed, using CPU:", e)
        out = run("cpu")
    out = out.cpu() * std + mean
    if sr != model.samplerate:
        import julius
        out = julius.resample_frac(out, model.samplerate, sr)
    for name, stem in zip(model.sources, out):
        sf.write(f"{outdir}/{name}.wav", stem.numpy().T, sr, subtype="FLOAT")
    print("done")
    """#
}
