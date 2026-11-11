import SwiftUI
import XCTest
@testable import SpotifySampler

final class RenderEditorTests: XCTestCase {
    /// Writes a snapshot of the editor when RENDER_EDITOR_TO is set (layout check, not an assertion).
    @MainActor
    func testRenderEditorSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["RENDER_EDITOR_TO"] else { throw XCTSkip("set RENDER_EDITOR_TO") }
        let wav = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_SOURCE"]!)
        let source = try KitStore.readSource(wav)
        // Never touch the user's real kits.
        setenv("SPOTIFY_SAMPLER_DATA_DIR", NSTemporaryDirectory() + "sampler-test-\(UUID().uuidString)", 1)
        let model = AppModel()
        let sample = Sample(source: source, params: SampleParams(name: "Selftest capture"))
        model.pads[0] = sample
        let w = Double(ProcessInfo.processInfo.environment["RENDER_W"] ?? "") ?? 1120
        let h = Double(ProcessInfo.processInfo.environment["RENDER_H"] ?? "") ?? 860
        let view = ContentView().environment(model).frame(width: w, height: h)
            .preferredColorScheme(.dark).tint(.amber)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
