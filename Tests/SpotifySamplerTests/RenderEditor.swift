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
        let model = AppModel()
        let sample = Sample(source: source, params: SampleParams(name: "Selftest capture"))
        model.pads[0] = sample
        let view = ContentView().environment(model).frame(width: 1120, height: 860)
            .preferredColorScheme(.dark).tint(.amber)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 860)
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
